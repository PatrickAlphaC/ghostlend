// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Chainlink oracle helper that validates price feed responses.
library OracleLib {
    error OracleLib__InvalidPrice();

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        internal
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        if (answer <= 0) {
            revert OracleLib__InvalidPrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
