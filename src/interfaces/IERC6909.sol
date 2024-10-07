// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

/**
 * @title ERC6909 interface for Multi Token Standard
 */
interface IERC6909 {
    /// @dev Thrown when owner balance of id is insufficient
    /// @param owner The owner of the token
    /// @param id The id of the token
    error InsufficientBalance(address owner, uint256 id);

    /// @dev Thrown when spender allowance for id is insufficient
    /// @param spender The spender of the token
    /// @param id The id of the token
    error InsufficientPermission(address spender, uint256 id);

    /// @notice The event emitted when a transfer occurs
    /// @param sender The address of the sender
    /// @param receiver The address of the receiver
    /// @param id The id of the token
    /// @param amount The amount of the token
    event Transfer(
        address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount
    );

    /// @notice The event emitted when an operator is set
    /// @param owner The address of the owner
    /// @param spender The address of the spender
    /// @param approved The approval status
    event OperatorSet(address indexed owner, address indexed spender, bool approved);

    /// @notice The event emitted when an approval occurs
    /// @param owner The address of the owner
    /// @param spender The address of the spender
    /// @param id The id of the token
    /// @param amount The amount of the token
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    /// @notice Transfers an amount of an id from the caller to a receiver
    /// @param receiver The address of the receiver
    /// @param id The id of the token
    /// @param amount The amount of the token
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);

    /// @notice Transfers an amount of an id from a sender to a receiver
    /// @param sender The address of the sender
    /// @param receiver The address of the receiver
    /// @param id The id of the token
    /// @param amount The amount of the token
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool);

    /// @notice Sets or removes a spender as an operator for the caller.
    /// @param spender The address of the spender.
    /// @param approved The approval status.
    function setOperator(address spender, bool approved) external returns (bool);

    /// @notice Checks if a contract implements an interface.
    /// @param interfaceId The interface identifier, as specified in ERC-165.
    /// @return supported True if the contract implements `interfaceId`.
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
