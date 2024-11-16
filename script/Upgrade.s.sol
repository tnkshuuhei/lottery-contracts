// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Lootery } from "../contracts/Lootery.sol";
import { TicketSVGRenderer } from "../contracts/periphery/TicketSVGRenderer.sol";
import { ILootery } from "../contracts/interfaces/ILootery.sol";

contract UpgradeLootery is Script {
    address public admin = 0xc3593524E2744E547f013E17E6b0776Bc27Fc614;

    function run() public {
        vm.startBroadcast();

        address proxy = 0x43e090616677b6ff8f86875c27e34855E252c9fB;

        Upgrades.upgradeProxy(proxy, "Lootery.sol", abi.encodeCall(Lootery.changeTicketPrice, (1 * 10 ** 6)));

        console.log("Deployed Lootery at", proxy);
        vm.stopBroadcast();
    }
}
