// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ILootery } from "../interfaces/ILootery.sol";
import { ITicketSVGRenderer } from "../interfaces/ITicketSVGRenderer.sol";
import { Pick } from "../lib/Pick.sol";

contract Ticket is ERC721 {
    ILootery public lootery;
/// @dev Total supply of tokens/tickets, also used to determine next tokenId
    uint256 public totalSupply;

    constructor(string memory name, string memory symbol, address _lootery) ERC721(name, symbol) {
        lootery = ILootery(_lootery);
    }
		    /// @notice See {ERC721-tokenURI}
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        
        return ITicketSVGRenderer(lootery.ticketSVGRenderer()).renderTokenURI(
            name(), tokenId, lootery.maxBallValue(), Pick.parse(lootery.pickLength(), lootery.purchasedTickets[tokenId].pickId)
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

}
