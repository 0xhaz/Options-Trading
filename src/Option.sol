// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC1155Burnable} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Access, AccessControl} from "./Access.sol";

/**
 * @title ERC1155 Option contract
 * @dev the prices used in the contract refer to `sqrt(1.0001^tick) * 2^96` (tick.getSqrtPriceAtTick())
 */
abstract contract Option is ERC1155, ERC1155Supply, ERC1155Burnable, Access {
    using EnumerableSet for EnumerableSet.UintSet;

    /*//////////////////////////////////////////////////////////////
                              GLOBAL STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Struct to store the Option info of an option token
     * @dev Option with the same strike price and expiry price will be minted under the same token id
     * a new tokenId will be used for the option if the previous option token has been voided
     * call `isOptionTokenValid()` function to check if the current option token is valid
     */
    struct OptionToken {
        bool void;
        uint256 tokenId;
        uint256 strikePrice;
        uint256 expiryPrice;
    }

    /// @notice next tokenId to mint a new type of option token
    /// @dev a valid tokenId starting from 1
    uint256 public nextTokenId = 1;

    /// @notice store the option info of an option token
    mapping(uint256 tokenId => OptionToken option) public tokenId2Option;

    /// @notice return the valid option token ids of the expiry price
    /// @dev use EnumerableSet instead of an array as we need to check if the token id is valid upon minting new option tokens
    mapping(uint256 expiryPrice => EnumerableSet.UintSet tokenIds) internal expiryPrice2TokenIds;

    /// @notice get the current valid token Id with option strike price and expiry price
    /// @dev key is keccak256(abi.encode(strikePrice, expiryPrice))
    mapping(bytes32 option => uint256 tokenId) public option2TokenId;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(string memory uri_) ERC1155(uri_) {}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice hook call this function to mint option tokens for user
     * @dev the option token id is determined by the option strike price and expiry price
     * @param user the address to receive the minted option tokens
     * @param amount the amount of option token to mint
     * @param strikePrice the option strike price
     * @param expiryPrice the option expiry price
     */
    function _mintOption(address user, uint256 amount, uint256 strikePrice, uint256 expiryPrice) internal {
        bytes32 optionKey = getOptionKey(strikePrice, expiryPrice);
        uint256 id = option2TokenId[optionKey];
        bool isValid = isOptionTokenValid(id);

        if (isValid) {
            // a valid option token already exists
            _mint(user, id, amount, "");
        } else {
            // use a new token id the option with the same strike price and expiry price
            // increment the nextTokenId after using its value for the new token id
            uint256 newTokenId = nextTokenId++;
            _mint(user, newTokenId, amount, "");

            // update option info for this new option token
            tokenId2Option[newTokenId] =
                OptionToken({void: false, tokenId: newTokenId, strikePrice: strikePrice, expiryPrice: expiryPrice});

            // add this new tokenId into expiryPrice2TokenIds
            expiryPrice2TokenIds[expiryPrice].add(newTokenId);

            // update option2TokenId mapping
            option2TokenId[optionKey] = newTokenId;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice call this function to void options that met the expiry price condition
     * @param expiryPrices_ we void options with these expiry prices
     */
    function voidOptionsByExpiryPrices(uint256[] calldata expiryPrices_) public {
        uint256 length = expiryPrices_.length;
        for (uint256 i; i < length; ++i) {
            _voidOptionByExpiryPrice(expiryPrices_[i]);
        }
    }

    /**
     * @notice call this function to void options that met the expiry price condition
     * @param tokenIds option ids to void
     */
    function voidOptionsByTokenIds(uint256[] calldata tokenIds) public {
        uint256 length = tokenIds.length;
        for (uint256 i; i < length; ++i) {
            _voidOptionByTokenId(tokenIds[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 UTILS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice get the key value for mapping `option2TokenId`
     * @param strikePrice_ the option strike price
     * @param expiryPrice_ the option expiry price
     */
    function getOptionKey(uint256 strikePrice_, uint256 expiryPrice_) public pure returns (bytes32 key) {
        key = keccak256(abi.encode(strikePrice_, expiryPrice_));
    }

    /**
     * @notice it returns the corresponding option token id with option strike price and expiry price
     * if the id is zero, it means the option token does not exists
     * @dev it only returns id. use `isOptionTokenValie` to check if the option token is valid or not
     * @param strikePrice_ the option strike price
     * @param expiryPrice_ the option expiry price
     */
    function getTokenId(uint256 strikePrice_, uint256 expiryPrice_) public view returns (uint256 id) {
        id = option2TokenId[getOptionKey(strikePrice_, expiryPrice_)];
    }

    /**
     * @notice check if an option token is valid
     * true: valid. can be executed
     * false: option token does not exist or has been voided
     * @param tokenId_ token id to check
     */
    function isOptionTokenValid(uint256 tokenId_) public view returns (bool) {
        if (tokenId_ == 0) return false;

        uint256 expiryPrice = tokenId2Option[tokenId_].expiryPrice;
        if (expiryPrice == 0) return false;

        return !tokenId2Option[tokenId_].void;
    }

    /**
     * @notice given an expiry price, return the total number of valid option tokens
     * @param expiryPrice_ the option expiry price
     */
    function getNumberOfValidToken(uint256 expiryPrice_) public view returns (uint256) {
        return expiryPrice2TokenIds[expiryPrice_].length();
    }

    /**
     * @notice Given an expiry price, return the valid option token ids from index start to end
     * @dev Note there are not guarantees on the ordering of values inside the array, and it may change when more values are added or removed
     * @param expiryPrice_ the option expiry price
     * @param start_ the start index of the option token ids. It must <= end_
     * @param end_ the end index of the option token ids. It must <= getNumberOfValidToken(expiryPrice_)
     */
    function getValidTokenIdByExpiryPrice(uint256 expiryPrice_, uint256 start_, uint256 end_)
        public
        view
        returns (uint256[] memory validTokenIds)
    {
        for (uint256 i = start_; i <= end_; ++i) {
            validTokenIds[i - start_] = expiryPrice2TokenIds[expiryPrice_].at(i);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Override it in the hook
     * @param expiryPrice_ we void options with this expiry price
     */
    function _voidOptionByExpiryPrice(uint256 expiryPrice_) internal virtual {}

    /**
     * @dev Override it in the hook
     * @param tokenId option id to void
     */
    function _voidOptionByTokenId(uint256 tokenId) internal virtual {}

    /*//////////////////////////////////////////////////////////////
                           OVERRIDE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _update(address from_, address to_, uint256[] memory ids_, uint256[] memory values_)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from_, to_, ids_, values_);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
