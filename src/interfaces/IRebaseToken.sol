// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title RebaseToken
 * @author Yufei
 * @notice This is a cross-chain rebase token that incentivises users to deposit into a vault and gain interest in rewards.
 * @notice The interest rate in the smart contract can only decrease.
 * @notice Each user will have their own interest rate that is the global interest rate at the time of deposit.
 */
interface IRebaseToken {
    /**
     * @notice Mints tokens to a user, typically upon deposit.
     * @dev Also mints accrued interest and locks in the current global rate for the user.
     * @param _to The address to mint tokens to.
     * @param _amount The principal amount of tokens to mint.
     */
    function mint(address _to, uint256 _amount) external;

    /**
     * @notice Burn the user tokens, e.g., when they withdraw from a vault or for cross-chain transfers.
     * Handles burning the entire balance if _amount is type(uint256).max.
     * @param _from The user address from which to burn tokens.
     * @param _amount The amount of tokens to burn. Use type(uint256).max to burn all tokens.
     */
    function burn(address _from, uint256 _amount) external;

    /**
     * @notice Returns the current balance of an account, including accrued interest.
     * @param _user The address of the account.
     * @return The total balance including interest.
     */
    function balanceOf(address _user) external view returns (uint256);
}
