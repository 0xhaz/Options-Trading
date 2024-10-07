// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {TickPriceLib} from "./libraries/TickPrice.sol";
import {ERC6909} from "src/base/ERC6909.sol";
import {Option} from "./Option.sol";

contract NarrativeController is IERC1155Receiver, Ownable2Step {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              ERROR CODES
    //////////////////////////////////////////////////////////////*/
    error InvalidOptionTokenId();
    error InsufficientOptionTokenBalance();
    error InsufficientETHBalance();
    error ETHTransferFailed();

    /*//////////////////////////////////////////////////////////////
                              GLOBAL STATE
    //////////////////////////////////////////////////////////////*/

    address public constant ETH = address(0);

    /// @notice the token user can buy with option tokens, e.g protocol governance token
    IERC20 public immutable TOKEN;

    /// @notice option token contract (ERC1155)
    Option public immutable OPTION;

    /// @notice uniswapv4 pool key
    PoolKey public POOL_KEY;

    /// @notice uniswapv4 swap router
    PoolSwapTest public SWAP_ROUTER;

    /// @notice true: buy back hook is on. false: buy back hook is off
    bool public buyBackHookControl;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event BuyBackHookControlSet(bool indexed val);
    event OptionExercise(address indexed user, uint256 indexed id, uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address owner, IERC20 token, Option option, PoolKey memory poolKey, PoolSwapTest swapRouter)
        Ownable(owner)
    {
        TOKEN = token;
        OPTION = option;
        POOL_KEY = poolKey;
        SWAP_ROUTER = swapRouter;
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice exercise option by providing the optio token id and amount
     * @param tokenId the option token id
     * @param amount the amount of option token to exercise
     */
    function exerciseOptionByTokenId(uint256 tokenId, uint256 amount) public payable {
        // check pool token balance. if balance <= amount, we only redeem partially
        uint256 poolBalance = TOKEN.balanceOf(address(this));
        if (poolBalance == 0) return;
        if (poolBalance < amount) amount = poolBalance; // partial redeem

        // check if the option token id is valid
        if (!OPTION.isOptionTokenValid(tokenId)) revert InvalidOptionTokenId();

        // check user's option token balance
        if (OPTION.balanceOf(msg.sender, tokenId) < amount) revert InsufficientOptionTokenBalance();

        // calculate how much user should pay
        (,, uint256 strikePrice,) = OPTION.tokenId2Option(tokenId);
        uint256 ethAmountToPay =
            TickPriceLib.getQuoteAtSqrtPrice(uint160(strikePrice), uint128(amount), address(TOKEN), ETH);
        if (msg.value < ethAmountToPay) revert InsufficientETHBalance();

        // burn user's option token
        OPTION.burn(msg.sender, tokenId, amount);

        // transfer token bought to user
        TOKEN.safeTransfer(msg.sender, amount);
        _buyBackHook(ethAmountToPay);

        emit OptionExercise(msg.sender, tokenId, amount);
    }

    /**
     * @notice allow admin to rescue token from the contract
     * @param token erc20 token address
     * @param amount amount of token to rescue
     */
    function rescueTokens(address token, uint256 amount) public onlyOwner {
        if (token == ETH) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @notice allow admin to set buy back hook control
     * @param _buyBackHookControl bool to set buy back hook control
     */
    function setBuyBack(bool _buyBackHookControl) public onlyOwner {
        buyBackHookControl = _buyBackHookControl;

        emit BuyBackHookControlSet(_buyBackHookControl);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev it swap exact amount of ETH into $TOKEN
     * @param amount the amount of tokens to swap. Negative is an exact-input swap
     */
    function _buyBackHook(uint256 amount) internal {
        if (buyBackHookControl) {
            uint160 MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1; // 1.000000000000000001
            uint160 MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1; // 1.000000000000000000
            bool zeroForOne = ETH < address(TOKEN) ? true : false;

            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact on price
            });

            PoolSwapTest.TestSettings memory testSettings =
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

            SWAP_ROUTER.swap{value: amount}(POOL_KEY, swapParams, testSettings, abi.encode(address(this)));
        }
    }

    /*//////////////////////////////////////////////////////////////
                        OVERRIDE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
