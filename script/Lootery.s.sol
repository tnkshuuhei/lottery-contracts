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

    function run() public {
        // Deploy the proxy with the config struct
        vm.startBroadcast();
        address ticketSVGRenderer = address(new TicketSVGRenderer());
        uint256 subscriptionId =
            52_583_392_386_139_978_788_287_834_954_922_830_646_012_130_925_743_222_032_793_193_524_782_781_572_502;
        bytes32 keyhash = 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71;
        address usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

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
            seedJackpotMinValue: 0.1 ether,
            ticketSVGRenderer: ticketSVGRenderer
        });

        address proxy =
            Upgrades.deployTransparentProxy("Lootery.sol", admin, abi.encodeCall(Lootery.initialize, (config)));
        console.log("Deployed Lootery at", proxy);
        vm.stopBroadcast();
    }
}
