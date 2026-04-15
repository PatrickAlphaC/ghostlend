// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {GhostLend} from "src/GhostLend.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

interface ITokenTransferReceiver {
    function onTokenTransfer(address token, uint256 amount) external;
}

contract CallbackMockERC20 is MockERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals_) MockERC20(name, symbol, decimals_) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transfer(to, amount);
        if (to.code.length > 0) {
            ITokenTransferReceiver(to).onTokenTransfer(address(this), amount);
        }
        return transferred;
    }
}

contract ReentrantAttacker is ITokenTransferReceiver {
    GhostLend private immutable i_ghostLend;
    address private immutable i_borrowToken;
    bool private s_attackInProgress;

    constructor(address ghostLend, address borrowToken) {
        i_ghostLend = GhostLend(ghostLend);
        i_borrowToken = borrowToken;
    }

    function attackBorrow(uint256 amount) external {
        s_attackInProgress = true;
        i_ghostLend.borrow(i_borrowToken, amount);
        s_attackInProgress = false;
    }

    function onTokenTransfer(address token, uint256 amount) external {
        if (!s_attackInProgress || msg.sender != token) {
            return;
        }
        i_ghostLend.borrow(i_borrowToken, amount);
    }
}
