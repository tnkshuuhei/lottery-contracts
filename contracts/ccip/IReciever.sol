// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

interface IReciever {
    struct MessageIn {
        uint64 sourceChainSelector; // The chain selector of the source chain.
        address sender; // The address of the sender.
        address token; // received token.
        uint256 amount; // received amount.
        bytes encodedTicket; // encoded ticket
    }

    // The chain selector of the destination chain.
    // The address of the receiver on the destination chain.
    // The borrower's EOA - would map to a depositor on the source chain.
    // The token amount that was sent.
    // The fees paid for sending the message.
    event MessageSent( 
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        address sender,
        Client.EVMTokenAmount tokenAmount,
        uint256 fees
    );

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        Client.EVMTokenAmount tokenAmount,
        bytes encodedTicket
    );
}
