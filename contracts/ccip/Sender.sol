// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CCIPReceiver } from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import { OwnerIsCreator } from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IReciever } from "./IReciever.sol";
import { ILootery } from "../interfaces/ILootery.sol";

contract Sender is OwnerIsCreator, IReciever {
    using SafeERC20 for IERC20;

    error NoFundsLocked(address msgSender, bool locked);
    error NoMessageReceived(); // Used when trying to access a message but no messages have been received.
    error IndexOutOfBound(uint256 providedIndex, uint256 maxIndex); // Used when the provided index is out of bounds.
    error MessageIdNotExist(bytes32 messageId); // Used when the provided message ID does not exist.
    error NotEnoughBalance(uint256, uint256);
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, uint256 value); // Used when the withdrawal of Ether fails.

    struct Deposit {
        uint256 amount;
        bool locked;
    }

    // Storage variables.
    bytes32[] public receivedMessages; // Array to keep track of the IDs of received messages.
    mapping(bytes32 => MessageIn) public messageDetail; // Mapping from message ID to MessageIn struct, storing details
        // of each received message.
    mapping(address => Deposit) public deposits;

    address router;

    // variables from Looteery
    uint256 communityFeeBps = 0.5e4;
    uint256 public constant PROTOCOL_FEE_BPS = 500;

    IERC20 public usdc;

    constructor(address _router, address _usdc) {
        require(_usdc != address(0), "USDC address cannot be 0");
        require(_router != address(0), "Router address cannot be 0");
        
				router = _router;
        usdc = IERC20(_usdc);
    }

    function sendMessage(
        uint64 destinationChainSelector,
        address receiver,
        ILootery.Ticket[] calldata tickets,
        address beneficiary
    )
        external
        returns (bytes32 messageId)
    {
        uint256 ticketsCount = tickets.length;
        uint256 totalPrice = 1 * 10 ** 6 * ticketsCount; // 1USDC for each ticket

        usdc.safeTransferFrom(msg.sender, address(this), totalPrice);

        // Handle fee splits
        uint256 communityFeeShare = (totalPrice * communityFeeBps) / 1e4;
        // address protocolFeeRecipient = ILooteryFactory(factory).getFeeRecipient();
        address protocolFeeRecipient = beneficiary;
        uint256 protocolFeeShare = protocolFeeRecipient == address(0) ? 0 : (totalPrice * PROTOCOL_FEE_BPS) / 1e4;
        uint256 jackpotShare = totalPrice - communityFeeShare - protocolFeeShare;

        // encode the depositor's EOA as  data to be sent in the message.
        bytes memory data = abi.encode(tickets);
        // Compose the EVMTokenAmountStruct. This struct describes the tokens being transferred using CCIP.
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({ token: address(usdc), amount: jackpotShare });

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = tokenAmount;

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver), // ABI-encoded receiver contract address
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({ gasLimit: 200_000 }) // Additional arguments, setting gas limit and
                    // non-strict sequency mode
            ),
            feeToken: address(0) // Setting feeToken to LinkToken address, indicating LINK will be used for fees
         });

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient routerClient = IRouterClient(router);

        // Get the fee required to send the message. Fee paid in LINK.
        uint256 fees = routerClient.getFee(destinationChainSelector, evm2AnyMessage);

        require(address(this).balance > fees, NotEnoughBalance(address(this).balance, fees));

        // Approve the Router to transfer the tokens on contract's behalf.
        usdc.approve(address(router), jackpotShare);

        // Send the message through the router and store the returned message ID
        messageId = routerClient.ccipSend(destinationChainSelector, evm2AnyMessage);

        // Emit an event with message details
        emit MessageSent(messageId, destinationChainSelector, receiver, msg.sender, tokenAmount, fees);

        // Return the message ID
        return messageId;
    }

    function getNumberOfReceivedMessages() external view returns (uint256 number) {
        return receivedMessages.length;
    }

    function getLastReceivedMessageDetails()
        external
        view
        returns (bytes32 messageId, uint64, address, address, uint256, bytes memory)
    {
        // Revert if no messages have been received
        if (receivedMessages.length == 0) revert NoMessageReceived();

        // Fetch the last received message ID
        messageId = receivedMessages[receivedMessages.length - 1];

        // Fetch the details of the last received message
        MessageIn memory detail = messageDetail[messageId];

        return (messageId, detail.sourceChainSelector, detail.sender, detail.token, detail.amount, detail.encodedTicket);
    }

    function isChainSupported(uint64 destChainSelector) external view returns (bool supported) {
        return IRouterClient(router).isChainSupported(destChainSelector);
    }

    function getSendFees(
        uint64 destinationChainSelector,
        address receiver
    )
        public
        view
        returns (uint256 fees, Client.EVM2AnyMessage memory message)
    {
        message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver), // ABI-encoded receiver contract address
            data: abi.encode(msg.sender),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({ gasLimit: 200_000 }) // Additional arguments, setting gas limit and
                    // non-strict sequency mode
            ),
            feeToken: address(0) // Setting feeToken to zero address, indicating native asset will be used for fees
         });

        // Get the fee required to send the message
        fees = IRouterClient(router).getFee(destinationChainSelector, message);
        return (fees, message);
    }

    /// @notice Fallback function to allow the contract to receive Ether.
    /// @dev This function has no function body, making it a default function for receiving Ether.
    /// It is automatically called when Ether is sent to the contract without any data.
    receive() external payable { }

    /// @notice Allows the contract owner to withdraw the entire balance of Ether from the contract.
    /// @dev This function reverts if there are no funds to withdraw or if the transfer fails.
    /// It should only be callable by the owner of the contract.
    function withdraw() public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = address(this).balance;

        // Attempt to send the funds, capturing the success status and discarding any return data
        (bool sent,) = msg.sender.call{ value: amount }("");

        // Revert if the send failed, with information about the attempted transfer
        if (!sent) revert FailedToWithdrawEth(msg.sender, amount);
    }

    function withdrawToken(address token) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(msg.sender, amount);
    }
}
