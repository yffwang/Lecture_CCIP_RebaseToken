// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

contract Vault {
    // Core Requirements:
    // 1. Store the address of the RebaseToken contract (passed in constructor).
    // 2. Implement a deposit function:
    //    - Accepts ETH from the user.
    //    - Mints RebaseTokens to the user, equivalent to the ETH sent (1:1 peg initially).
    // 3. Implement a redeem function:
    //    - Burns the user's RebaseTokens.
    //    - Sends the corresponding amount of ETH back to the user.
    // 4. Implement a mechanism to add ETH rewards to the vault.

    IRebaseToken private immutable i_rebaseToken; // Type will be interface

    // Event for deposits (user is indexed for efficient filtering)
    event Deposit(address indexed user, uint256 amount);
    // Event for redemptions (user is indexed for efficient filtering)
    event Redeem(address indexed user, uint256 amount);

    error Vault_DepositAmountIsZero();
    error Vault_RedeemFailed(uint256 amount);

    constructor(IRebaseToken _rebaseToken) {
        // Parameter type will be interface
        i_rebaseToken = _rebaseToken;
    }

    /* External Functions */

    /**
     * @notice Gets the address of the RebaseToken contract associated with this vault.
     * @return The address of the RebaseToken.
     */
    function getRebaseTokenAddress() external view returns (address) {
        return address(i_rebaseToken); // Cast to address for return
    }

    /**
     * @notice Allows a user to deposit ETH and receive an equivalent amount of RebaseTokens.
     * @dev The amount of ETH sent with the transaction (msg.value) determines the amount of tokens minted.
     * Assumes a 1:1 peg for ETH to RebaseToken for simplicity in this version.
     */
    function deposit() external payable {
        // The amount of ETH sent is msg.value
        // The user making the call is msg.sender
        uint256 amountToMint = msg.value;

        // Ensure some ETH is actually sent
        if (amountToMint == 0) {
            revert Vault_DepositAmountIsZero();
        }

        // Call the mint function on the RebaseToken contract
        i_rebaseToken.mint(msg.sender, amountToMint);

        // Emit an event to log the deposit
        emit Deposit(msg.sender, amountToMint);
    }

    /**
     * @notice Allows a user to burn their RebaseTokens and receive a corresponding amount of ETH.
     * @param _amount The amount of RebaseTokens to redeem. Use type(uint256).max to redeem the full balance.
     * @dev Follows Checks-Effects-Interactions pattern. Uses low-level .call for ETH transfer.
     * @dev The type(uint256).max sentinel is resolved here in the vault: the token's burn()
     *      would resolve it against token balances internally, but the ETH side of the
     *      redemption must send the exact same resolved amount.
     */
    function redeem(uint256 _amount) external {
        // Resolve "redeem everything" before interacting with the token so the
        // ETH transfer below burns and pays out the exact same amount.
        uint256 amount = _amount;
        if (amount == type(uint256).max) {
            amount = i_rebaseToken.balanceOf(msg.sender);
        }

        // 1. Effects (State changes occur first)
        // Burn the resolved amount of tokens from the caller (msg.sender)
        // The RebaseToken's burn function should handle checks for sufficient balance.
        i_rebaseToken.burn(msg.sender, amount);

        // 2. Interactions (External calls / ETH transfer last)
        // Send the equivalent amount of ETH back to the user
        (bool success,) = payable(msg.sender).call{value: amount}("");

        // Check if the ETH transfer succeeded
        if (!success) {
            revert Vault_RedeemFailed(amount); // Use the custom error
        }

        // Emit an event logging the redemption
        emit Redeem(msg.sender, amount);
    }

    /**
     * @notice Fallback function to accept ETH rewards sent directly to the contract.
     * @dev Any ETH sent to this contract's address without data will be accepted.
     */
    receive() external payable {}
}
