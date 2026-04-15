// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BCScript} from "battlechain-lib/BCScript.sol";
import {Contact} from "battlechain-lib/types/AgreementTypes.sol";
import {GhostLend} from "src/GhostLend.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract DeployGhostLend is BCScript {
    function _protocolName() internal pure override returns (string memory) {
        return "GhostLend";
    }

    function _contacts() internal pure override returns (Contact[] memory) {
        Contact[] memory contacts = new Contact[](1);
        contacts[0] = Contact({name: "GhostLend Security", contact: "security@ghostlend.xyz"});
        return contacts;
    }

    function _recoveryAddress() internal view override returns (address) {
        return msg.sender;
    }

    function run() external returns (GhostLend, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveConfig();

        address[] memory tokens = new address[](2);
        tokens[0] = config.weth;
        tokens[1] = config.usdc;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = config.ethUsdPriceFeed;
        priceFeeds[1] = config.usdcUsdPriceFeed;

        vm.startBroadcast();
        GhostLend ghostLend = GhostLend(
            bcDeployCreate(abi.encodePacked(type(GhostLend).creationCode, abi.encode(tokens, priceFeeds)))
        );

        address agreement = createAndAdoptAgreement(
            defaultAgreementDetails(_protocolName(), _contacts(), getDeployedContracts(), _recoveryAddress()),
            msg.sender,
            keccak256("ghostlend-v1")
        );

        if (_isBattleChain()) {
            requestAttackMode(agreement);
        }
        vm.stopBroadcast();

        return (ghostLend, helperConfig);
    }
}
