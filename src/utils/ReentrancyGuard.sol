// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Gas-efficient reentrancy guard using transient storage (EIP-1153).
/// @dev Uses transient storage so the lock is automatically cleared at the end
///      of each transaction, saving a cold SSTORE on exit.
abstract contract ReentrancyGuard {
    error ReentrancyGuard__ReentrantCall();

    uint256 private transient _locked;

    modifier nonReentrant() {
        if (_locked != 0) {
            revert ReentrancyGuard__ReentrantCall();
        }
        _locked = 1;
        _;
        _locked = 0;
    }
}
