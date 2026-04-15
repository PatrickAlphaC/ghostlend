// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * @title GhostLend
 * @notice A basic borrowing and lending protocol using Chainlink price feeds.
 * @dev Supports ERC20 collateral (e.g. WETH, USDC) priced in USD.
 *      Requires 200% minimum collateralization. Positions below 200% are liquidatable.
 * @custom:security-contact security@ghostlend.xyz
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";
import {ReentrancyGuard} from "src/utils/ReentrancyGuard.sol";

contract GhostLend is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;

    struct TokenConfig {
        address priceFeed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_COLLATERAL_RATIO = 2e18; // 200%
    uint256 private constant LIQUIDATION_BONUS_PERCENT = 10;
    uint256 private constant PERCENT_DIVISOR = 100;

    address[] private s_supportedTokens;
    mapping(address token => TokenConfig config) private s_tokenConfigs;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateral;
    mapping(address user => mapping(address token => uint256 amount)) private s_borrowed;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event TokenAdded(address indexed token, address indexed priceFeed);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, address indexed token, uint256 amount);
    event Repaid(address indexed user, address indexed token, uint256 amount);
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        address collateralToken,
        address borrowToken,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error GhostLend__TokenNotSupported();
    error GhostLend__AmountMustBeGreaterThanZero();
    error GhostLend__InsufficientCollateral();
    error GhostLend__Undercollateralized();
    error GhostLend__NotUndercollateralized();
    error GhostLend__ArrayLengthMismatch();
    error GhostLend__CannotLiquidateSelf();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert GhostLend__AmountMustBeGreaterThanZero();
        }
        _;
    }

    modifier supportedToken(address token) {
        if (s_tokenConfigs[token].priceFeed == address(0)) {
            revert GhostLend__TokenNotSupported();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address[] memory tokens, address[] memory priceFeeds) {
        if (tokens.length != priceFeeds.length) {
            revert GhostLend__ArrayLengthMismatch();
        }
        for (uint256 i; i < tokens.length; ++i) {
            s_tokenConfigs[tokens[i]] = TokenConfig({
                priceFeed: priceFeeds[i],
                tokenDecimals: IERC20Metadata(tokens[i]).decimals(),
                feedDecimals: AggregatorV3Interface(priceFeeds[i]).decimals()
            });
            s_supportedTokens.push(tokens[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new token for use as collateral or borrowing.
    function addSupportedToken(address token, address priceFeed) external {
        s_tokenConfigs[token] = TokenConfig({
            priceFeed: priceFeed,
            tokenDecimals: IERC20Metadata(token).decimals(),
            feedDecimals: AggregatorV3Interface(priceFeed).decimals()
        });
        s_supportedTokens.push(token);
        emit TokenAdded(token, priceFeed);
    }

    /// @notice Deposit ERC20 tokens as collateral.
    function depositCollateral(address token, uint256 amount)
        external
        nonReentrant
        supportedToken(token)
        moreThanZero(amount)
    {
        s_collateral[msg.sender][token] += amount;
        emit CollateralDeposited(msg.sender, token, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw collateral. Reverts if withdrawal would break 200% ratio.
    function withdrawCollateral(address token, uint256 amount)
        external
        supportedToken(token)
        moreThanZero(amount)
    {
        uint256 deposited = s_collateral[msg.sender][token];
        if (deposited < amount) {
            revert GhostLend__InsufficientCollateral();
        }
        emit CollateralWithdrawn(msg.sender, token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
        s_collateral[msg.sender][token] = deposited - amount;
        if (!_isCollateralized(msg.sender)) {
            revert GhostLend__Undercollateralized();
        }
    }

    /// @notice Borrow tokens against deposited collateral. Requires 200% collateralization.
    function borrow(address token, uint256 amount)
        external
        nonReentrant
        supportedToken(token)
        moreThanZero(amount)
    {
        s_borrowed[msg.sender][token] += amount;
        if (!_isCollateralized(msg.sender)) {
            revert GhostLend__Undercollateralized();
        }
        emit Borrowed(msg.sender, token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Repay borrowed tokens. Caps at the outstanding debt.
    function repay(address token, uint256 amount)
        external
        nonReentrant
        supportedToken(token)
        moreThanZero(amount)
    {
        uint256 owed = s_borrowed[msg.sender][token];
        if (amount > owed) {
            amount = owed;
        }
        s_borrowed[msg.sender][token] = owed - amount;
        if (s_borrowed[msg.sender][token] == 0) {
            delete s_borrowed[msg.sender][token];
        }
        emit Repaid(msg.sender, token, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Liquidate an undercollateralized position. Liquidator repays debt and
    ///         receives collateral worth 110% of the repaid debt.
    function liquidate(address user, address collateralToken, address borrowToken, uint256 debtToRepay)
        external
        nonReentrant
        moreThanZero(debtToRepay)
    {
        if (msg.sender == user) {
            revert GhostLend__CannotLiquidateSelf();
        }
        if (_isCollateralized(user)) {
            revert GhostLend__NotUndercollateralized();
        }

        uint256 owed = s_borrowed[user][borrowToken];
        if (debtToRepay > owed) {
            debtToRepay = owed;
        }

        uint256 debtValueUsd = _getUsdValue(borrowToken, debtToRepay);
        uint256 bonusValueUsd = debtValueUsd * LIQUIDATION_BONUS_PERCENT / PERCENT_DIVISOR;
        uint256 collateralToSeize = _getTokenAmountFromUsd(collateralToken, debtValueUsd + bonusValueUsd);

        uint256 userCollateral = s_collateral[user][collateralToken];
        if (collateralToSeize > userCollateral) {
            collateralToSeize = userCollateral;
        }

        s_borrowed[user][borrowToken] -= debtToRepay;
        s_collateral[user][collateralToken] -= collateralToSeize;

        emit Liquidated(msg.sender, user, collateralToken, borrowToken, debtToRepay, collateralToSeize);

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), debtToRepay);
        IERC20(collateralToken).safeTransfer(msg.sender, collateralToSeize);
    }

    /*//////////////////////////////////////////////////////////////
                      USER-FACING READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getAccountCollateralValueUsd(address user) external view returns (uint256) {
        return _getAccountCollateralValueUsd(user);
    }

    function getAccountBorrowValueUsd(address user) external view returns (uint256) {
        return _getAccountBorrowValueUsd(user);
    }

    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountWad) external view returns (uint256) {
        return _getTokenAmountFromUsd(token, usdAmountWad);
    }

    function getCollateral(address user, address token) external view returns (uint256) {
        return s_collateral[user][token];
    }

    function getBorrowed(address user, address token) external view returns (uint256) {
        return s_borrowed[user][token];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return s_supportedTokens;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return s_tokenConfigs[token];
    }

    function getMinCollateralRatio() external pure returns (uint256) {
        return MIN_COLLATERAL_RATIO;
    }

    function getLiquidationBonusPercent() external pure returns (uint256) {
        return LIQUIDATION_BONUS_PERCENT;
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _healthFactor(address user) private view returns (uint256) {
        uint256 borrowValueUsd = _getAccountBorrowValueUsd(user);
        if (borrowValueUsd == 0) return type(uint256).max;
        uint256 collateralValueUsd = _getAccountCollateralValueUsd(user);
        return collateralValueUsd * PRECISION / borrowValueUsd;
    }

    function _isCollateralized(address user) private view returns (bool) {
        return _healthFactor(user) >= MIN_COLLATERAL_RATIO;
    }

    function _getAccountCollateralValueUsd(address user) private view returns (uint256 totalValueUsd) {
        for (uint256 i; i < s_supportedTokens.length; ++i) {
            address token = s_supportedTokens[i];
            uint256 amount = s_collateral[user][token];
            if (amount > 0) {
                totalValueUsd += _getUsdValue(token, amount);
            }
        }
    }

    function _getAccountBorrowValueUsd(address user) private view returns (uint256 totalValueUsd) {
        for (uint256 i; i < s_supportedTokens.length; ++i) {
            address token = s_supportedTokens[i];
            uint256 amount = s_borrowed[user][token];
            if (amount > 0) {
                totalValueUsd += _getUsdValue(token, amount);
            }
        }
    }

    /// @dev Returns USD value with 18 decimal precision.
    ///      Formula: amount * scaledPrice / 10^tokenDecimals
    ///      where scaledPrice = price * 10^(18 - feedDecimals)
    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        TokenConfig memory config = s_tokenConfigs[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(config.priceFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // casting to uint256 is safe because OracleLib reverts when price <= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 scaledPrice = uint256(price) * 10 ** (18 - config.feedDecimals);
        return amount * scaledPrice / 10 ** config.tokenDecimals;
    }

    /// @dev Converts a USD value (18 decimals) to a token amount.
    function _getTokenAmountFromUsd(address token, uint256 usdAmountWad) private view returns (uint256) {
        TokenConfig memory config = s_tokenConfigs[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(config.priceFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // casting to uint256 is safe because OracleLib reverts when price <= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 scaledPrice = uint256(price) * 10 ** (18 - config.feedDecimals);
        return usdAmountWad * 10 ** config.tokenDecimals / scaledPrice;
    }
}
