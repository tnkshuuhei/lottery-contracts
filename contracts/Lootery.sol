// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import { ILootery } from "./interfaces/ILootery.sol";
import { Pick } from "./lib/Pick.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IAnyrand } from "./interfaces/IAnyrand.sol";
import { ITicketSVGRenderer } from "./interfaces/ITicketSVGRenderer.sol";
import { RandomNumber } from "./ccip/RandomNumber.sol";
import { IRandomNumber } from "./ccip/IRandomNumber.sol";
import { CCIPReceiver } from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import { OwnerIsCreator } from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import { IReciever } from "./ccip/IReciever.sol";

/// @title Lootery
/// @notice Lootery is a number lottery contract where players can pick a
///     configurable set of numbers/balls per ticket, similar to IRL lottos
///     such as Powerball or EuroMillions. At the end of every round, a keeper
///     may call the `draw` function to determine the winning set of numbers
///     for that round. Then a new round is immediately started.
///
///     Any player with a winning ticket (i.e. their ticket's set of numbers is
///     set-equal to the winning set of numbers) has one round to claim their
///     winnings. Otherwise, the winnings are rolled back into the jackpot.
///
///     The lottery will run forever until the owner invokes *apocalypse mode*,
///     which invokes a special rule for the current round: if no player wins
///     the jackpot, then every ticket buyer from the current round may claim
///     an equal share of the jackpot.
///
///     Players may permissionlessly buy tickets through the `purchase`
///     function, paying a ticket price (in the form of `prizeToken`), where
///     the proceeds are split into the jackpot and the community fee (this is
///     configurable only at initialisation). Alternatively, the owner of the
///     lottery contract may also distribute free tickets via the `ownerPick`
///     function.
///
///     While the jackpot builds up over time, it is possible (and desirable)
///     to seed the jackpot at any time using the `seedJackpot` function.
contract Lootery is ILootery, ERC721, ReentrancyGuard, CCIPReceiver, OwnerIsCreator, IReciever {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice The protocol fee, taken from purchase fee, if switched on
    uint256 public constant PROTOCOL_FEE_BPS = 500;

    /// @notice How many numbers must be picked per draw (and per ticket)
    ///     The range of this number should be something like 3-7
    uint8 public pickLength;
    /// @notice Maximum value of a ball (pick) s.t. value \in [1, maxBallValue]
    uint8 public maxBallValue;
    /// @notice How long a game lasts in seconds (before numbers are drawn)
    uint256 public gamePeriod;
    // /// @notice Trusted randomiser
    // address public randomiser;
    /// @notice Token used for prizes
    address public prizeToken;
    /// @notice Ticket price
    uint256 public ticketPrice;
    /// @notice Percentage of ticket price directed to the community
    uint256 public communityFeeBps;
    /// @notice Minimum seconds to wait between seeding jackpot
    uint256 public seedJackpotDelay;
    /// @notice Minimum value required when seeding jackpot
    uint256 public seedJackpotMinValue;
    /// @notice Ticket SVG renderer
    address public ticketSVGRenderer;

    /// @dev Total supply of tokens/tickets, also used to determine next tokenId
    uint256 public totalSupply;
    /// @notice Current state of the game
    CurrentGame public currentGame;
    /// @notice Running jackpot
    uint256 public jackpot;
    /// @notice Unclaimed jackpot payouts from previous game; will be rolled
    ///     over if not claimed in current game
    uint256 public unclaimedPayouts;

    //----------- VRF variables -----------//
    uint256 public s_subscriptionId;
    uint256[] public requestIds;
    uint256 public lastRequestId;
    bytes32 public keyHash;

    IRandomNumber public vrf;

    modifier onlyVrfContract() {
        require(msg.sender == address(vrf), "Only VRF contract can call this function");
        _;
    }

    /// @notice Current random request details
    RandomnessRequest public randomnessRequest;
    /// @notice token id => purchased ticked details (gameId, pickId)
    mapping(uint256 tokenId => PurchasedTicket) public purchasedTickets;
    /// @notice Game data
    mapping(uint256 gameId => Game) public gameData;
    /// @notice Game id => pick identity => tokenIds
    mapping(uint256 gameId => mapping(uint256 id => uint256[])) public tokenByPickIdentity;
    /// @notice Game id => # of claimed winning tickets
    mapping(uint256 gameId => uint256) public numClaimedWinningTickets;
    /// @notice Whether a token id has been used to claim winnings
    mapping(uint256 tokenId => bool) public isWinningsClaimed;
    /// @notice Accrued community fee share (wei)
    uint256 public accruedCommunityFees;
    /// @notice When true, current game will be the last
    bool public isApocalypseMode;
    /// @notice Timestamp of when jackpot was last seeded
    uint256 public jackpotLastSeededAt;
    /// @notice Beneficiaries; these addresses may be selected during purchase
    ///     to receive the community fee share.
    EnumerableSet.AddressSet private _beneficiaries;
    /// @notice Beneficiary display names for human readability
    mapping(address beneficiary => string name) public beneficiaryDisplayNames;

    // VRF mapping
    mapping(uint256 => RequestStatus) public s_requests; /* requestId --> requestStatus */

    constructor(InitConfig memory initConfig)
        ERC721(initConfig.name, initConfig.symbol)
        CCIPReceiver(initConfig.ccipRouter)
    {
        // deploy RandomNumber contract
        vrf = IRandomNumber(address(new RandomNumber(initConfig.subscriptionId, initConfig.keyHash, address(this))));

        require(initConfig.subscriptionId != 0, INVALID_SUBSCRIPTION_ID(initConfig.subscriptionId));
        s_subscriptionId = initConfig.subscriptionId;

        require(initConfig.keyHash.length != 0, INVALID_KEY_HASH(initConfig.keyHash));
        keyHash = initConfig.keyHash;

        // Pick length of 0 doesn't make sense, pick length > 32 would consume
        // too much gas. Also realistically, lottos usually pick 5-8 numbers.
        if (initConfig.pickLength == 0 || initConfig.pickLength > 32) {
            revert InvalidPickLength(initConfig.pickLength);
        }
        pickLength = initConfig.pickLength;

        // If pick length > max ball value, then it's impossible to even
        // purchase tickets. This is a configuration error.
        if (initConfig.pickLength > initConfig.maxBallValue) {
            revert InvalidMaxBallValue(initConfig.maxBallValue);
        }
        maxBallValue = initConfig.maxBallValue;

        if (initConfig.gamePeriod < 10 minutes) {
            revert InvalidGamePeriod(initConfig.gamePeriod);
        }
        gamePeriod = initConfig.gamePeriod;

        if (initConfig.ticketPrice == 0) {
            revert InvalidTicketPrice(initConfig.ticketPrice);
        }
        ticketPrice = initConfig.ticketPrice;

        // Community fee + protocol fee should not overflow 100%
        // 0% jackpot fee share is allowed
        if (initConfig.communityFeeBps + PROTOCOL_FEE_BPS > 1e4) {
            revert InvalidFeeShares();
        }
        communityFeeBps = initConfig.communityFeeBps;

        // if (initConfig.randomiser == address(0)) {
        //     revert InvalidRandomiser(initConfig.randomiser);
        // }
        // randomiser = initConfig.randomiser;

        if (initConfig.prizeToken == address(0)) {
            revert InvalidPrizeToken(initConfig.prizeToken);
        }
        prizeToken = initConfig.prizeToken;

        seedJackpotDelay = initConfig.seedJackpotDelay;
        seedJackpotMinValue = initConfig.seedJackpotMinValue;
        if (seedJackpotDelay == 0 || seedJackpotMinValue == 0) {
            revert InvalidSeedJackpotConfig(seedJackpotDelay, seedJackpotMinValue);
        }

        _setTicketSVGRenderer(initConfig.ticketSVGRenderer);

        currentGame.state = GameState.Purchase;
        gameData[0] = Game({
            ticketsSold: 0,
            // The first game starts straight away
            startedAt: uint64(block.timestamp),
            winningPickId: 0
        });
    }

    function typeAndVersion() external pure returns (string memory) {
        return "Lootery 1.8.0";
    }

    /// @dev The contract should be able to receive Ether to pay for VRF.
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice Only allow calls in the specified game state
    /// @param state Required game state
    modifier onlyInState(GameState state) {
        if (currentGame.state != state) {
            revert UnexpectedState(currentGame.state);
        }
        _;
    }

    /// @notice Get all beneficiaries (shouldn't be such a huge list)
    function beneficiaries() external view returns (address[] memory addresses, string[] memory names) {
        addresses = _beneficiaries.values();
        names = new string[](addresses.length);
        for (uint256 i; i < addresses.length; ++i) {
            names[i] = beneficiaryDisplayNames[addresses[i]];
        }
    }

    /// @notice Add or remove a beneficiary
    /// @param beneficiary Address to add/remove
    /// @param displayName Display name for the beneficiary
    /// @param isBeneficiary Whether to add or remove
    /// @return didMutate Whether the beneficiary was added/removed
    function setBeneficiary(
        address beneficiary,
        string calldata displayName,
        bool isBeneficiary
    )
        external
        onlyOwner
        returns (bool didMutate)
    {
        if (isBeneficiary) {
            if (bytes(displayName).length == 0) {
                revert EmptyDisplayName();
            }
            // Set display name if it changed (or was unset)
            bool didDisplayNameChange =
                keccak256(bytes(beneficiaryDisplayNames[beneficiary])) != keccak256(bytes(displayName));
            beneficiaryDisplayNames[beneficiary] = displayName;
            // Upsert beneficiary
            didMutate = _beneficiaries.add(beneficiary) || didDisplayNameChange;
            if (didMutate) {
                emit BeneficiarySet(beneficiary, displayName);
            }
        } else {
            didMutate = _beneficiaries.remove(beneficiary);
            if (didMutate) {
                delete beneficiaryDisplayNames[beneficiary];
                emit BeneficiaryRemoved(beneficiary);
            }
        }
    }

    /// @notice Seed the jackpot.
    /// @dev We allow seeding jackpot during purchase phase only, so we don't
    ///     have to fuck around with accounting
    /// @notice NB: This function is rate-limited by `jackpotLastSeededAt`!
    /// @param value Amount of `prizeToken` to be taken from the caller and
    ///     added to the jackpot.
    function seedJackpot(uint256 value) external onlyInState(GameState.Purchase) {
        // Disallow seeding the jackpot with zero value
        if (value < seedJackpotMinValue) {
            revert InsufficientJackpotSeed(value);
        }

        // Rate limit seeding the jackpot
        if (block.timestamp < jackpotLastSeededAt + seedJackpotDelay) {
            revert RateLimited(jackpotLastSeededAt + seedJackpotDelay - block.timestamp);
        }
        jackpotLastSeededAt = block.timestamp;

        jackpot += value;
        IERC20(prizeToken).safeTransferFrom(msg.sender, address(this), value);
        emit JackpotSeeded(msg.sender, value);
    }

    /// @notice Pick tickets and increase jackpot
    /// @param tickets Tickets!
    function _pickTickets(Ticket[] memory tickets) internal onlyInState(GameState.Purchase) {
        CurrentGame memory currentGame_ = currentGame;
        uint256 currentGameId = currentGame_.id;

        uint256 ticketsCount = tickets.length;
        Game memory game = gameData[currentGameId];
        gameData[currentGameId].ticketsSold = game.ticketsSold + uint64(ticketsCount);

        uint256 pickLength_ = pickLength;
        uint256 maxBallValue_ = maxBallValue;
        uint256 startingTokenId = totalSupply + 1;
        for (uint256 t; t < ticketsCount; ++t) {
            address whomst = tickets[t].whomst;
            uint8[] memory pick = tickets[t].pick;

            // Empty pick means this particular player does not wish to receive
            // an entry to the lottery.
            if (pick.length != pickLength_ && pick.length != 0) {
                revert InvalidPickLength(pick.length);
            }

            if (pick.length != 0) {
                // Assert balls are ascendingly sorted, with no possibility of duplicates
                uint8 lastBall;
                for (uint256 i; i < pickLength_; ++i) {
                    uint8 ball = pick[i];
                    if (ball <= lastBall) revert UnsortedPick(pick);
                    if (ball > maxBallValue_) revert InvalidBallValue(ball);
                    lastBall = ball;
                }
            }

            // Record picked numbers
            uint256 tokenId = startingTokenId + t;
            uint256 pickId = Pick.id(pick);
            purchasedTickets[tokenId] = PurchasedTicket({ gameId: currentGameId, pickId: pickId });

            // Account for this pick set
            tokenByPickIdentity[currentGameId][pickId].push(tokenId);
            emit TicketPurchased(currentGameId, whomst, tokenId, pick);
        }
        // Finally, mint NFTs
        for (uint256 t; t < ticketsCount; ++t) {
            address whomst = tickets[t].whomst;
            _safeMint(whomst, startingTokenId + t); // NB: Increases totalSupply
        }
    }

    /// @notice Purchase a ticket
    /// @param tickets Tickets! Tickets!
    /// @param beneficiary Beneficiary address to receive community fee share
    function purchase(Ticket[] calldata tickets, address beneficiary) external {
        if (tickets.length == 0) {
            revert NoTicketsSpecified();
        }

        uint256 ticketsCount = tickets.length;
        uint256 totalPrice = ticketPrice * ticketsCount;

        IERC20(prizeToken).safeTransferFrom(msg.sender, address(this), totalPrice);

        // Handle fee splits
        uint256 communityFeeShare = (totalPrice * communityFeeBps) / 1e4;
        // address protocolFeeRecipient = ILooteryFactory(factory).getFeeRecipient();
        address protocolFeeRecipient = beneficiary;
        uint256 protocolFeeShare = protocolFeeRecipient == address(0) ? 0 : (totalPrice * PROTOCOL_FEE_BPS) / 1e4;
        uint256 jackpotShare = totalPrice - communityFeeShare - protocolFeeShare;
        uint256 currentGameId = currentGame.id;

        // Payout community/beneficiary fees
        if (beneficiary == address(0)) {
            accruedCommunityFees += communityFeeShare;
        } else {
            if (!_beneficiaries.contains(beneficiary)) {
                revert UnknownBeneficiary(beneficiary);
            }
            if (communityFeeShare > 0) {
                IERC20(prizeToken).safeTransfer(beneficiary, communityFeeShare);
            }
        }
        emit BeneficiaryPaid(currentGameId, beneficiary == address(0) ? address(this) : beneficiary, communityFeeShare);

        // Payout protocol fees
        if (protocolFeeShare > 0) {
            IERC20(prizeToken).safeTransfer(protocolFeeRecipient, protocolFeeShare);
            emit ProtocolFeePaid(protocolFeeRecipient, protocolFeeShare);
        }

        // Payout jackpot
        jackpot += jackpotShare;
        _pickTickets(tickets);
    }

    /// @notice Helper to get the request price for VRF call
    // function getRequestPrice() public view returns (uint256) {
    //     return IAnyrand(randomiser).getRequestPrice(callbackGasLimit);
    // }

    /// @notice Draw numbers, picking potential jackpot winners and ending the
    ///     current game. This should be automated by a keeper.
    function draw() external onlyInState(GameState.Purchase) {
        Game memory game = gameData[currentGame.id];
        // Assert that the game is actually over
        uint256 gameDeadline = (game.startedAt + gamePeriod);
        if (block.timestamp < gameDeadline) {
            revert WaitLonger(gameDeadline);
        }

        // Assert that there are actually tickets sold in this game
        // slither-disable-next-line incorrect-equality
        if (game.ticketsSold == 0) {
            if (isApocalypseMode) {
                // Case #0: Apocalypse mode is triggered, but there were no
                // tickets sold and therefore nobody to distribute jackpot or
                // prize to.
                revert NoTicketsSold();
            } else {
                // Case #1: No tickets were sold, just skip the game
                emit DrawSkipped(currentGame.id);
            }
            _setupNextGame();
        } else {
            // Case #2: Tickets were sold
            _requestRandomness();
        }
    }

    /// @notice This is an escape hatch to re-request randomness in case there
    ///     is some issue with the VRF fulfiller.
    function forceRedraw() external payable nonReentrant onlyInState(GameState.DrawPending) {
        RandomnessRequest memory request = randomnessRequest;
        if (request.timestamp == 0) {
            revert NoRandomnessRequestInFlight();
        }

        // There is a pending request present: check if it's been waiting for a while
        if (block.timestamp >= request.timestamp + 1 hours) {
            // 30 minutes have passed since the request was made
            _requestRandomness();
        } else {
            revert WaitLonger(request.timestamp + 1 hours);
        }
    }

    /// @notice Request randomness from VRF
    function _requestRandomness() internal returns (uint256 requestId) {
        currentGame.state = GameState.DrawPending;

        // uint256 requestPrice = getRequestPrice();
        // if (msg.value > requestPrice) {
        //     // Refund excess to caller, if any
        //     uint256 excess = msg.value - requestPrice;
        //     (bool success, bytes memory data) = msg.sender.call{ value: excess }("");
        //     if (!success) {
        //         revert TransferFailure(msg.sender, excess, data);
        //     }
        //     emit ExcessRefunded(msg.sender, excess);
        // }
        // if (address(this).balance < requestPrice) {
        //     revert InsufficientOperationalFunds(address(this).balance, requestPrice);
        // }

        // VRF call to trusted coordinator
        // slither-disable-next-line reentrancy-eth,arbitrary-send-eth
        requestId = vrf.requestRandomWords(false);
        s_requests[requestId] = RequestStatus({ randomWords: new uint256[](0), exists: true, fulfilled: false });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, 2);
        return requestId;
    }

    /// @notice Callback for VRF fulfiller.
    function receiveRandomWords(
        // uint256 _requestId,
        uint256[] calldata _randomWords
    )
        external
        onlyVrfContract
        onlyInState(GameState.DrawPending)
    {
        // if (msg.sender != randomiser) {
        //     revert CallerNotRandomiser(msg.sender);
        // }
        // if (randomWords.length == 0) {
        //     revert InsufficientRandomWords();
        // }
        // if (randomnessRequest.requestId != requestId) {
        //     revert RequestIdMismatch(requestId, randomnessRequest.requestId);
        // }
        // randomnessRequest = RandomnessRequest({ requestId: 0, timestamp: 0 });
        // Will revert if subscription is not set and funded.

        // Pick winning numbers
        uint8[] memory balls = computeWinningPick(_randomWords[0]);
        uint248 gameId = currentGame.id;
        emit GameFinalised(gameId, balls);

        // Record winning pick bitset
        uint256 winningPickId = Pick.id(balls);
        gameData[gameId].winningPickId = winningPickId;

        _setupNextGame();
    }

    /// @dev Transition to next game, locking and/or rolling over any jackpots
    ///     as necessary.
    function _setupNextGame() internal {
        // Invariant: can't setup a next game if the lottery has been killed
        assert(currentGame.state != GameState.Dead);

        // Current game id, before the state transition
        uint248 gameId = currentGame.id;

        GameState nextState;
        if (isApocalypseMode) {
            // Apocalypse mode, kill game forever
            nextState = GameState.Dead;
        } else {
            // Otherwise, ready for next game
            nextState = GameState.Purchase;
        }

        // Initialise data for next game
        currentGame = CurrentGame({ state: nextState, id: gameId + 1 });
        gameData[gameId + 1].startedAt = uint64(block.timestamp);

        // Jackpot accounting: rollover jackpot if no winner
        uint256 winningPickId = gameData[gameId].winningPickId;
        uint256 numWinners = tokenByPickIdentity[gameId][winningPickId].length;
        uint256 currentUnclaimedPayouts = unclaimedPayouts;
        uint256 currentJackpot = jackpot;

        if (numWinners == 0 && nextState != GameState.Dead) {
            // No winners, normal game transition, current jackpot and
            // unclaimed payouts are rolled over to the next game
            uint256 nextJackpot = currentUnclaimedPayouts + currentJackpot;
            uint256 nextUnclaimedPayouts = 0;
            jackpot = nextJackpot;
            unclaimedPayouts = 0;
            emit JackpotRollover(gameId, currentUnclaimedPayouts, currentJackpot, nextUnclaimedPayouts, nextJackpot);
        } else {
            // There are winners, or apocalypse mode has been triggered
            // => jackpot+unclaimed goes into next game's unclaimed
            uint256 nextJackpot = 0;
            uint256 nextUnclaimedPayouts = currentUnclaimedPayouts + currentJackpot;
            jackpot = 0;
            unclaimedPayouts = nextUnclaimedPayouts;
            emit JackpotRollover(gameId, currentUnclaimedPayouts, currentJackpot, nextUnclaimedPayouts, nextJackpot);
        }
    }

    /// @notice Get the number of winners in a game
    /// @param gameId Game id
    /// @param pickId Pick id
    /// @return Number of winners
    function numWinnersInGame(uint256 gameId, uint256 pickId) public view returns (uint256) {
        return tokenByPickIdentity[gameId][pickId].length;
    }

    /// @notice Claim a share of the jackpot with a winning ticket.
    /// @param tokenId Token id of the ticket (will be burnt)
    function claimWinnings(uint256 tokenId) external returns (uint256 prizeShare) {
        // Only allow claims during Purchase state so we don't have to deal
        // with intermediate states between gameIds.
        // Dead state is also ok since the entire game has ended forever.
        if (currentGame.state != GameState.Purchase && currentGame.state != GameState.Dead) {
            revert UnexpectedState(currentGame.state);
        }

        address whomst = _ownerOf(tokenId);
        if (whomst == address(0)) {
            revert ERC721NonexistentToken(tokenId);
        }

        PurchasedTicket memory ticket = purchasedTickets[tokenId];
        uint256 currentGameId = currentGame.id;
        // Can only claim winnings from the last game
        if (ticket.gameId != currentGameId - 1) {
            revert ClaimWindowMissed(tokenId);
        }

        // Determine if the jackpot was won
        Game memory game = gameData[ticket.gameId];
        uint256 winningPickId = game.winningPickId;
        uint256 numWinners = numWinnersInGame(ticket.gameId, winningPickId);

        if (numWinners == 0 && currentGame.state == GameState.Dead) {
            // No jackpot winners, and game is no longer active!
            // Jackpot is shared between all tickets
            // Invariant: `ticketsSold[gameId] > 0`
            prizeShare = unclaimedPayouts / totalSupply;
            // Decrease unclaimed payouts by the amount just claimed
            unclaimedPayouts -= prizeShare;
            // Burning the token is our "consolation prize claim nullifier"
            _burn(tokenId); // NB: decreases totalSupply
            // Transfer share of jackpot to ticket holder
            IERC20(prizeToken).safeTransfer(whomst, prizeShare);
            emit ConsolationClaimed(tokenId, ticket.gameId, whomst, prizeShare);
        } else if (winningPickId == ticket.pickId) {
            assert(numWinners > 0);
            // This ticket did have the winning numbers; just check it hasn't
            // been used to claim a prize already
            if (isWinningsClaimed[tokenId]) {
                revert AlreadyClaimed(tokenId);
            }
            // OK - compute the prize share to transfer
            uint256 numClaimedWinningTickets_ = numClaimedWinningTickets[ticket.gameId];
            prizeShare = unclaimedPayouts / (numWinners - numClaimedWinningTickets_);
            // Decrease unclaimed payouts by the amount just claimed
            unclaimedPayouts -= prizeShare;
            // Record that this ticket has claimed its winnings, but don't burn
            isWinningsClaimed[tokenId] = true;
            numClaimedWinningTickets[ticket.gameId] += 1;
            // Transfer share of jackpot to ticket holder
            IERC20(prizeToken).safeTransfer(whomst, prizeShare);

            emit WinningsClaimed(tokenId, ticket.gameId, whomst, prizeShare);
        } else {
            revert NoWin(ticket.pickId, winningPickId);
        }
    }

    /// @notice Withdraw accrued community fees.
    function withdrawAccruedFees() external onlyOwner {
        uint256 totalAccrued = accruedCommunityFees;
        accruedCommunityFees = 0;
        IERC20(prizeToken).safeTransfer(msg.sender, totalAccrued);
        emit AccruedCommunityFeesWithdrawn(msg.sender, totalAccrued);
    }

    /// @notice Set this game as the last game of the lottery.
    ///     aka invoke apocalypse mode.
    function kill() external onlyOwner onlyInState(GameState.Purchase) {
        if (isApocalypseMode) {
            // Already set
            revert GameInactive();
        }
        isApocalypseMode = true;
        emit ApocalypseModeActivated(currentGame.id);
    }

    /// @notice Withdraw any ETH (used for VRF requests).
    function rescueETH() external onlyOwner {
        uint256 amount = address(this).balance;
        (bool success, bytes memory data) = msg.sender.call{ value: amount }("");
        if (!success) {
            revert TransferFailure(msg.sender, amount, data);
        }
        emit OperationalFundsWithdrawn(msg.sender, amount);
    }

    /// @notice Allow owner to rescue any tokens sent to the contract;
    ///     excluding jackpot and accrued fees.
    /// @param tokenAddress Address of token to withdraw
    function rescueTokens(address tokenAddress) external onlyOwner {
        if (tokenAddress == prizeToken) {
            revert PrizeTokenWithdrawalNotAllowed();
        }

        uint256 amount = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).safeTransfer(msg.sender, amount);
    }

    /// @notice Helper to parse a pick id into a pick array
    /// @param pickId Pick id
    function computePick(uint256 pickId) public view returns (uint8[] memory pick) {
        return Pick.parse(pickLength, pickId);
    }

    /// @notice Helper to compute the winning numbers/balls given a random seed.
    /// @param randomSeed Seed that determines the permutation of BALLS
    /// @return balls Ordered set of winning numbers
    function computeWinningPick(uint256 randomSeed) public view returns (uint8[] memory balls) {
        return Pick.draw(pickLength, maxBallValue, randomSeed);
    }

    function changeTicketPrice(uint256 _newPrice) external onlyOwner {
        require(_newPrice > 0, InvalidTicketPrice(_newPrice));
        ticketPrice = _newPrice;
        emit TicketPriceUpdated(_newPrice);
    }

    /// @notice Set the SVG renderer for tickets (privileged)
    /// @param renderer Address of renderer contract
    function _setTicketSVGRenderer(address renderer) internal {
        bool isValidRenderer = IERC165(renderer).supportsInterface(type(ITicketSVGRenderer).interfaceId);
        if (!isValidRenderer) {
            revert InvalidTicketSVGRenderer(renderer);
        }
        ticketSVGRenderer = renderer;
        emit TicketSVGRendererSet(renderer);
    }

    /// @notice Set the SVG renderer for tickets
    /// @param renderer Address of renderer contract
    function setTicketSVGRenderer(address renderer) external onlyOwner {
        _setTicketSVGRenderer(renderer);
    }

    /// @notice Determine if game is active (in any playable state). If this
    ///     returns `false`, it means that the lottery is no longer playable.
    /// @dev This is a helper function exposed for frontend (also for legacy
    ///     reasons). Check the game state directly in the contract.
    function isGameActive() external view returns (bool) {
        return currentGame.state != GameState.Dead;
    }

    /// @notice See {ERC721-tokenURI}
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return ITicketSVGRenderer(ticketSVGRenderer).renderTokenURI(
            name(), tokenId, maxBallValue, Pick.parse(pickLength, purchasedTickets[tokenId].pickId)
        );
    }

    /// @notice Overrides {ERC721-_update} to track totalSupply
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address previousOwner = super._update(to, tokenId, auth);

        if (previousOwner == address(0)) {
            totalSupply += 1;
        }
        if (to == address(0)) {
            totalSupply -= 1;
        }

        return previousOwner;
    }

    // Storage variables.
    bytes32[] public receivedMessages; // Array to keep track of the IDs of received messages.
    mapping(bytes32 => MessageIn) public messageDetail; // Mapping from message ID to MessageIn struct, storing details
        // of the message.

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        bytes32 messageId = any2EvmMessage.messageId; // fetch the messageId
        uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector; // fetch the source chain identifier (aka
            // selector)
        address sender = abi.decode(any2EvmMessage.sender, (address)); // abi-decoding of the sender address
        (bytes memory encodedTicket) = abi.decode(any2EvmMessage.data, (bytes)); // abi-decoding tuple

        // abi-decoding of the encoded ticket
        (Ticket[] memory tickets) = abi.decode(encodedTicket, (Ticket[]));

        // Collect tokens transferred. This increases this contract's balance for that Token.
        Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage.destTokenAmounts;
        address token = tokenAmounts[0].token;
        uint256 amount = tokenAmounts[0].amount;

        receivedMessages.push(messageId);
        MessageIn memory detail = MessageIn(sourceChainSelector, sender, token, amount, encodedTicket);
        messageDetail[messageId] = detail;

        emit MessageReceived(messageId, sourceChainSelector, sender, tokenAmounts[0], encodedTicket);

        jackpot += amount;

        // mint ticket
        _pickTickets(tickets);
    }

    /// @notice Override supportsInterface to handle multiple inheritance
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, CCIPReceiver, IERC165)
        returns (bool)
    {
        return ERC721.supportsInterface(interfaceId) || CCIPReceiver.supportsInterface(interfaceId);
    }
}
