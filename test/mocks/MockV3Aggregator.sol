// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal Chainlink AggregatorV3Interface mock for testing.
contract MockV3Aggregator {
    uint8 public decimals;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    uint80 public latestRound;
    uint80 public latestAnsweredInRound;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        latestAnswer = _initialAnswer;
        latestTimestamp = block.timestamp;
        latestRound = 1;
        latestAnsweredInRound = 1;
    }

    function updateAnswer(int256 _answer) external {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        ++latestRound;
        latestAnsweredInRound = latestRound;
    }

    function updateRoundData(uint80 _roundId, int256 _answer, uint256 _updatedAt, uint80 _answeredInRound)
        external
    {
        latestRound = _roundId;
        latestAnswer = _answer;
        latestTimestamp = _updatedAt;
        latestAnsweredInRound = _answeredInRound;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (latestRound, latestAnswer, latestTimestamp, latestTimestamp, latestAnsweredInRound);
    }
}
