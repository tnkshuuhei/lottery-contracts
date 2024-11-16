// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Lootery } from "../contracts/Lootery.sol";
import { TicketSVGRenderer } from "../contracts/periphery/TicketSVGRenderer.sol";
import { ILootery } from "../contracts/interfaces/ILootery.sol";

contract DeployLootery is Script {
    address public admin = 0xc3593524E2744E547f013E17E6b0776Bc27Fc614;
    address ticketSVGRenderer;
    uint256 subscriptionId;
    bytes32 keyhash;
    address usdc;
    address ccipRouter;

    function configureChain() internal {
        if (block.chainid == 11_155_111) {
            ticketSVGRenderer = address(new TicketSVGRenderer());
            subscriptionId = 0;
            keyhash = 0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c;
            usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            ccipRouter = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
        } else if (block.chainid == 11_155_111) {
            ticketSVGRenderer = address(new TicketSVGRenderer());
            subscriptionId =
                52_583_392_386_139_978_788_287_834_954_922_830_646_012_130_925_743_222_032_793_193_524_782_781_572_502;
            keyhash = 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71;
            usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
            ccipRouter = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
        } else {
            revert("Chain not supported");
        }
    }

    function run() public {
        configureChain();

        vm.startBroadcast();

        // Create the init config struct
        ILootery.InitConfig memory config = ILootery.InitConfig({
            owner: admin,
            name: "ETHGlobal Bangkok",
            symbol: "ETHBKK",
            pickLength: 5,
            maxBallValue: 36,
            gamePeriod: 10 minutes,
            ticketPrice: 1 * 10 ** 6,
            communityFeeBps: 0.5e4,
            subscriptionId: subscriptionId,
            keyHash: keyhash,
            prizeToken: usdc,
            seedJackpotDelay: 10 minutes,
            seedJackpotMinValue: 1 * 10 ** 6,
            ticketSVGRenderer: ticketSVGRenderer,
            ccipRouter: ccipRouter
        });

        Lootery lootery = new Lootery(config);
        console.log("Deployed Lootery at", address(lootery));
        vm.stopBroadcast();
    }
}
