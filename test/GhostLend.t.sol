// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GhostLend} from "src/GhostLend.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract GhostLendTest is Test {
    GhostLend ghostLend;
    MockERC20 weth;
    MockERC20 usdc;
    MockV3Aggregator ethPriceFeed;
    MockV3Aggregator usdcPriceFeed;

    address USER = makeAddr("user");
    address LIQUIDATOR = makeAddr("liquidator");
    address DEPOSITOR = makeAddr("depositor");

    uint256 constant STARTING_WETH_BALANCE = 100 ether;
    uint256 constant STARTING_USDC_BALANCE = 200_000e6;
    int256 constant ETH_USD_PRICE = 2000e8;
    int256 constant USDC_USD_PRICE = 1e8;

    function setUp() public {
        ethPriceFeed = new MockV3Aggregator(8, ETH_USD_PRICE);
        usdcPriceFeed = new MockV3Aggregator(8, USDC_USD_PRICE);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);
        address[] memory feeds = new address[](2);
        feeds[0] = address(ethPriceFeed);
        feeds[1] = address(usdcPriceFeed);
        ghostLend = new GhostLend(tokens, feeds);

        _fundAndApprove(USER);
        _fundAndApprove(LIQUIDATOR);
        _fundAndApprove(DEPOSITOR);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ArrayLengthsMismatch() external {
        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](1);
        vm.expectRevert(GhostLend.GhostLend__ArrayLengthMismatch.selector);
        new GhostLend(tokens, feeds);
    }

    function test_ConstructorSetsTokenConfigs() external view {
        GhostLend.TokenConfig memory ethConfig = ghostLend.getTokenConfig(address(weth));
        assertEq(ethConfig.priceFeed, address(ethPriceFeed));
        assertEq(ethConfig.tokenDecimals, 18);
        assertEq(ethConfig.feedDecimals, 8);

        GhostLend.TokenConfig memory usdcConfig = ghostLend.getTokenConfig(address(usdc));
        assertEq(usdcConfig.priceFeed, address(usdcPriceFeed));
        assertEq(usdcConfig.tokenDecimals, 6);
        assertEq(usdcConfig.feedDecimals, 8);
    }

    function test_ConstructorSetsSupportedTokens() external view {
        address[] memory tokens = ghostLend.getSupportedTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(weth));
        assertEq(tokens[1], address(usdc));
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_DepositZeroAmount() external {
        vm.prank(USER);
        vm.expectRevert(GhostLend.GhostLend__AmountMustBeGreaterThanZero.selector);
        ghostLend.depositCollateral(address(weth), 0);
    }

    function test_RevertWhen_DepositUnsupportedToken() external {
        address fakeToken = makeAddr("fakeToken");
        vm.prank(USER);
        vm.expectRevert(GhostLend.GhostLend__TokenNotSupported.selector);
        ghostLend.depositCollateral(fakeToken, 1 ether);
    }

    function testFuzz_DepositCollateral(uint256 amount) external {
        amount = bound(amount, 1, STARTING_WETH_BALANCE);
        vm.prank(USER);
        ghostLend.depositCollateral(address(weth), amount);

        assertEq(ghostLend.getCollateral(USER, address(weth)), amount);
        assertEq(weth.balanceOf(address(ghostLend)), amount);
    }

    function test_DepositEmitsEvent() external {
        vm.prank(USER);
        vm.expectEmit(true, true, false, true);
        emit GhostLend.CollateralDeposited(USER, address(weth), 5 ether);
        ghostLend.depositCollateral(address(weth), 5 ether);
    }

    function testFuzz_DepositUsdc(uint256 amount) external {
        amount = bound(amount, 1, STARTING_USDC_BALANCE);
        vm.prank(USER);
        ghostLend.depositCollateral(address(usdc), amount);

        assertEq(ghostLend.getCollateral(USER, address(usdc)), amount);
        assertEq(usdc.balanceOf(address(ghostLend)), amount);
    }

    /*//////////////////////////////////////////////////////////////
                         WITHDRAW COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_WithdrawMoreThanDeposited() external {
        vm.startPrank(USER);
        ghostLend.depositCollateral(address(weth), 5 ether);
        vm.expectRevert(GhostLend.GhostLend__InsufficientCollateral.selector);
        ghostLend.withdrawCollateral(address(weth), 6 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawBreaksCollateralization() external {
        _seedProtocolLiquidity();
        _depositAndBorrow(USER, 10 ether, 5000e6);

        vm.prank(USER);
        vm.expectRevert(GhostLend.GhostLend__Undercollateralized.selector);
        ghostLend.withdrawCollateral(address(weth), 6 ether);
    }

    function testFuzz_WithdrawCollateralNoBorrows(uint256 depositAmount, uint256 withdrawAmount) external {
        depositAmount = bound(depositAmount, 1, STARTING_WETH_BALANCE);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        vm.startPrank(USER);
        ghostLend.depositCollateral(address(weth), depositAmount);
        ghostLend.withdrawCollateral(address(weth), withdrawAmount);
        vm.stopPrank();

        assertEq(ghostLend.getCollateral(USER, address(weth)), depositAmount - withdrawAmount);
    }

    function test_WithdrawPartialWithActiveBorrow() external {
        _seedProtocolLiquidity();
        // 10 WETH ($20k) collateral, borrow 5000 USDC ($5k) → 400% ratio
        _depositAndBorrow(USER, 10 ether, 5000e6);

        // Withdraw 4 WETH → 6 WETH ($12k) remaining, 5k borrowed → 240% ✓
        vm.prank(USER);
        ghostLend.withdrawCollateral(address(weth), 4 ether);
        assertEq(ghostLend.getCollateral(USER, address(weth)), 6 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                BORROW
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_BorrowWithoutCollateral() external {
        _seedProtocolLiquidity();

        vm.prank(USER);
        vm.expectRevert(GhostLend.GhostLend__Undercollateralized.selector);
        ghostLend.borrow(address(usdc), 1e6);
    }

    function test_RevertWhen_BorrowExceedsCollateralRatio() external {
        _seedProtocolLiquidity();

        // 10 WETH = $20k collateral → max borrow = $10k (200% ratio)
        vm.startPrank(USER);
        ghostLend.depositCollateral(address(weth), 10 ether);
        vm.expectRevert(GhostLend.GhostLend__Undercollateralized.selector);
        ghostLend.borrow(address(usdc), 10_001e6); // $10,001 > $10k limit
        vm.stopPrank();
    }

    function testFuzz_BorrowWithSufficientCollateral(uint256 borrowAmount) external {
        _seedProtocolLiquidity();

        vm.prank(USER);
        ghostLend.depositCollateral(address(weth), 10 ether);

        // 10 WETH = $20k → max borrow = $10k USDC
        borrowAmount = bound(borrowAmount, 1, 10_000e6);

        vm.prank(USER);
        ghostLend.borrow(address(usdc), borrowAmount);

        assertEq(ghostLend.getBorrowed(USER, address(usdc)), borrowAmount);
    }

    function test_BorrowExactlyAt200Percent() external {
        _seedProtocolLiquidity();

        // 10 WETH = $20k, borrow exactly $10k → 200% ratio
        vm.startPrank(USER);
        ghostLend.depositCollateral(address(weth), 10 ether);
        ghostLend.borrow(address(usdc), 10_000e6);
        vm.stopPrank();

        assertEq(ghostLend.getHealthFactor(USER), 2e18);
    }

    function test_BorrowTransfersTokens() external {
        _seedProtocolLiquidity();

        uint256 balanceBefore = usdc.balanceOf(USER);
        vm.startPrank(USER);
        ghostLend.depositCollateral(address(weth), 10 ether);
        ghostLend.borrow(address(usdc), 5000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(USER), balanceBefore + 5000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                REPAY
    //////////////////////////////////////////////////////////////*/

    function testFuzz_RepayPartialDebt(uint256 repayAmount) external {
        _seedProtocolLiquidity();
        uint256 borrowed = 5000e6;
        _depositAndBorrow(USER, 10 ether, borrowed);

        repayAmount = bound(repayAmount, 1, borrowed);

        vm.prank(USER);
        ghostLend.repay(address(usdc), repayAmount);

        assertEq(ghostLend.getBorrowed(USER, address(usdc)), borrowed - repayAmount);
    }

    function test_RepayFullDebt() external {
        _seedProtocolLiquidity();
        _depositAndBorrow(USER, 10 ether, 5000e6);

        vm.prank(USER);
        ghostLend.repay(address(usdc), 5000e6);

        assertEq(ghostLend.getBorrowed(USER, address(usdc)), 0);
        assertEq(ghostLend.getHealthFactor(USER), type(uint256).max);
    }

    function test_RepayCappedAtOwedAmount() external {
        _seedProtocolLiquidity();
        _depositAndBorrow(USER, 10 ether, 5000e6);

        uint256 balanceBefore = usdc.balanceOf(USER);

        // Try to repay more than owed
        vm.prank(USER);
        ghostLend.repay(address(usdc), 999_999e6);

        // Only the owed amount (5000 USDC) should be transferred
        assertEq(ghostLend.getBorrowed(USER, address(usdc)), 0);
        assertEq(usdc.balanceOf(USER), balanceBefore - 5000e6);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_LiquidateSelf() external {
        vm.prank(USER);
        vm.expectRevert(GhostLend.GhostLend__CannotLiquidateSelf.selector);
        ghostLend.liquidate(USER, address(weth), address(usdc), 1000e6);
    }

    function test_RevertWhen_UserIsCollateralized() external {
        _seedProtocolLiquidity();
        _depositAndBorrow(USER, 10 ether, 5000e6);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(GhostLend.GhostLend__NotUndercollateralized.selector);
        ghostLend.liquidate(USER, address(weth), address(usdc), 1000e6);
    }

    function test_LiquidateUndercollateralizedPosition() external {
        _seedProtocolLiquidity();

        // USER deposits 10 WETH ($20k), borrows 8000 USDC → 250%
        _depositAndBorrow(USER, 10 ether, 8000e6);

        // ETH crashes to $1000 → collateral = $10k, debt = $8k → 125%
        ethPriceFeed.updateAnswer(1000e8);

        uint256 liquidatorWethBefore = weth.balanceOf(LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        ghostLend.liquidate(USER, address(weth), address(usdc), 8000e6);

        // Debt repaid: 8000 USDC ($8k)
        // Collateral seized: $8k + 10% bonus = $8.8k → 8.8 WETH at $1k
        assertEq(ghostLend.getBorrowed(USER, address(usdc)), 0);
        assertEq(ghostLend.getCollateral(USER, address(weth)), 10 ether - 8.8 ether);
        assertEq(weth.balanceOf(LIQUIDATOR), liquidatorWethBefore + 8.8 ether);
    }

    function test_LiquidatePartialDebt() external {
        _seedProtocolLiquidity();
        _depositAndBorrow(USER, 10 ether, 8000e6);

        // ETH drops to $1000
        ethPriceFeed.updateAnswer(1000e8);

        // Liquidate only half the debt
        vm.prank(LIQUIDATOR);
        ghostLend.liquidate(USER, address(weth), address(usdc), 4000e6);

        // 4000 USDC repaid, collateral seized: $4k + 10% = $4.4k → 4.4 WETH
        assertEq(ghostLend.getBorrowed(USER, address(usdc)), 4000e6);
        assertEq(ghostLend.getCollateral(USER, address(weth)), 10 ether - 4.4 ether);
    }

    function test_LiquidateCollateralCappedAtUserBalance() external {
        _seedProtocolLiquidity();

        // USER deposits 1 WETH ($2k), borrows 900 USDC → 222%
        _depositAndBorrow(USER, 1 ether, 900e6);

        // ETH crashes to $500 → collateral = $500, debt = $900 → 55%
        ethPriceFeed.updateAnswer(500e8);

        // Debt to repay: 900 USDC, bonus would be $990 → 1.98 WETH
        // But user only has 1 WETH → capped at 1 WETH
        vm.prank(LIQUIDATOR);
        ghostLend.liquidate(USER, address(weth), address(usdc), 900e6);

        assertEq(ghostLend.getBorrowed(USER, address(usdc)), 0);
        assertEq(ghostLend.getCollateral(USER, address(weth)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_HealthFactorMaxWhenNoBorrows() external {
        vm.prank(USER);
        ghostLend.depositCollateral(address(weth), 10 ether);
        assertEq(ghostLend.getHealthFactor(USER), type(uint256).max);
    }

    function test_HealthFactorCalculation() external {
        _seedProtocolLiquidity();
        // 10 WETH ($20k) collateral, 5000 USDC ($5k) borrowed → 400%
        _depositAndBorrow(USER, 10 ether, 5000e6);
        assertEq(ghostLend.getHealthFactor(USER), 4e18);
    }

    function test_GetUsdValueWeth() external view {
        // 1 WETH at $2000
        assertEq(ghostLend.getUsdValue(address(weth), 1 ether), 2000e18);
    }

    function test_GetUsdValueUsdc() external view {
        // 1 USDC at $1
        assertEq(ghostLend.getUsdValue(address(usdc), 1e6), 1e18);
    }

    function test_GetTokenAmountFromUsdWeth() external view {
        // $2000 → 1 WETH
        assertEq(ghostLend.getTokenAmountFromUsd(address(weth), 2000e18), 1 ether);
    }

    function test_GetTokenAmountFromUsdUsdc() external view {
        // $100 → 100 USDC
        assertEq(ghostLend.getTokenAmountFromUsd(address(usdc), 100e18), 100e6);
    }

    function test_AccountCollateralValueUsd() external {
        vm.startPrank(USER);
        ghostLend.depositCollateral(address(weth), 5 ether);
        ghostLend.depositCollateral(address(usdc), 10_000e6);
        vm.stopPrank();

        // 5 WETH ($10k) + 10k USDC ($10k) = $20k
        assertEq(ghostLend.getAccountCollateralValueUsd(USER), 20_000e18);
    }

    function test_GetMinCollateralRatio() external view {
        assertEq(ghostLend.getMinCollateralRatio(), 2e18);
    }

    function test_GetLiquidationBonusPercent() external view {
        assertEq(ghostLend.getLiquidationBonusPercent(), 10);
    }

    /*//////////////////////////////////////////////////////////////
                           ORACLE STALENESS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_OraclePriceIsStale() external {
        vm.warp(block.timestamp + 3 hours + 1);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        ghostLend.getUsdValue(address(weth), 1 ether);
    }

    function test_RevertWhen_OracleRoundIncomplete() external {
        ethPriceFeed.updateRoundData(2, ETH_USD_PRICE, block.timestamp, 1);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        ghostLend.getUsdValue(address(weth), 1 ether);
    }

    function test_OracleAcceptsFreshPrice() external {
        ethPriceFeed.updateRoundData(2, ETH_USD_PRICE, block.timestamp, 2);
        assertEq(ghostLend.getUsdValue(address(weth), 1 ether), 2000e18);
    }

    /*//////////////////////////////////////////////////////////////
                             ORACLE EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_HealthFactorChangesWithPrice() external {
        _seedProtocolLiquidity();
        _depositAndBorrow(USER, 10 ether, 5000e6);

        // 10 WETH ($20k) / $5k = 4x
        assertEq(ghostLend.getHealthFactor(USER), 4e18);

        // ETH drops to $1000 → 10 WETH ($10k) / $5k = 2x
        ethPriceFeed.updateAnswer(1000e8);
        assertEq(ghostLend.getHealthFactor(USER), 2e18);

        // ETH drops to $500 → 10 WETH ($5k) / $5k = 1x (liquidatable)
        ethPriceFeed.updateAnswer(500e8);
        assertEq(ghostLend.getHealthFactor(USER), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fundAndApprove(address user) private {
        weth.mint(user, STARTING_WETH_BALANCE);
        usdc.mint(user, STARTING_USDC_BALANCE);
        vm.startPrank(user);
        weth.approve(address(ghostLend), type(uint256).max);
        usdc.approve(address(ghostLend), type(uint256).max);
        vm.stopPrank();
    }

    function _seedProtocolLiquidity() private {
        vm.startPrank(DEPOSITOR);
        usdc.mint(DEPOSITOR, 1_000_000e6);
        usdc.approve(address(ghostLend), type(uint256).max);
        ghostLend.depositCollateral(address(usdc), 1_000_000e6);
        weth.mint(DEPOSITOR, 1000 ether);
        weth.approve(address(ghostLend), type(uint256).max);
        ghostLend.depositCollateral(address(weth), 1000 ether);
        vm.stopPrank();
    }

    function _depositAndBorrow(address user, uint256 wethAmount, uint256 usdcBorrow) private {
        vm.startPrank(user);
        ghostLend.depositCollateral(address(weth), wethAmount);
        ghostLend.borrow(address(usdc), usdcBorrow);
        vm.stopPrank();
    }
}
