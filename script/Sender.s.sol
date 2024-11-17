// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Lootery } from "../contracts/Lootery.sol";
import { TicketSVGRenderer } from "../contracts/periphery/TicketSVGRenderer.sol";
import { ILootery } from "../contracts/interfaces/ILootery.sol";
import { Sender } from "../contracts/ccip/Sender.sol";

contract DeploySender is Script {
    address usdc;
    address ccipRouter;

    function configureChain() internal {
        if (block.chainid == 11_155_111) {
            usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            ccipRouter = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
        } else if (block.chainid == 84532) {
            usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
            ccipRouter = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
        } else {
            revert("Chain not supported");
        }
    }

    function run() public {
        configureChain();

        vm.startBroadcast();
				new Sender(usdc, ccipRouter);
        vm.stopBroadcast();
    }
}
