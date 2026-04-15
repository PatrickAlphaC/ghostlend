// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address weth;
        address usdc;
        address ethUsdPriceFeed;
        address usdcUsdPriceFeed;
    }

    uint8 private constant FEED_DECIMALS = 8;
    int256 private constant ETH_USD_PRICE = 2000e8;
    int256 private constant USDC_USD_PRICE = 1e8;

    NetworkConfig private s_activeConfig;

    constructor() {
        if (block.chainid == 1) {
            s_activeConfig = _getMainnetConfig();
        } else {
            s_activeConfig = _getAnvilConfig();
        }
    }

    function getActiveConfig() external view returns (NetworkConfig memory) {
        return s_activeConfig;
    }

    function _getMainnetConfig() private pure returns (NetworkConfig memory) {
        return NetworkConfig({
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            ethUsdPriceFeed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
            usdcUsdPriceFeed: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6
        });
    }

    function _getAnvilConfig() private returns (NetworkConfig memory) {
        MockV3Aggregator ethFeed = new MockV3Aggregator(FEED_DECIMALS, ETH_USD_PRICE);
        MockV3Aggregator usdcFeed = new MockV3Aggregator(FEED_DECIMALS, USDC_USD_PRICE);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        return NetworkConfig({
            weth: address(weth),
            usdc: address(usdc),
            ethUsdPriceFeed: address(ethFeed),
            usdcUsdPriceFeed: address(usdcFeed)
        });
    }
}
