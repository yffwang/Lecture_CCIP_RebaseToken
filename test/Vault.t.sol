// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {Vault} from "../src/Vault.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";

/// @notice A contract that rejects any ETH transfer back to it.
contract RevertingReceiver {
    Vault private immutable i_vault;

    constructor(Vault _vault) {
        i_vault = _vault;
    }

    function deposit() external payable {
        i_vault.deposit{value: msg.value}();
    }

    function redeem(uint256 _amount) external {
        i_vault.redeem(_amount);
    }

    receive() external payable {
        revert("ETH not accepted");
    }
}

/// @notice Attempts to re-enter Vault.redeem() from its receive() hook.
/// @dev The burn-before-send order means a re-entrant call can only ever pull
///      out tokens the attacker still owns — this contract proves no more ETH
///      leaves the vault than tokens were burned.
contract ReentrancyAttacker {
    Vault private immutable i_vault;
    IRebaseToken private immutable i_token;
    uint256 public reentries;
    uint256 private constant MAX_REENTRIES = 1;

    constructor(Vault _vault) {
        i_vault = _vault;
        i_token = IRebaseToken(_vault.getRebaseTokenAddress());
    }

    function attack() external payable {
        uint256 amount = msg.value;
        i_vault.deposit{value: amount}();
        // Redeeming half triggers receive() mid-transfer, where we re-enter.
        i_vault.redeem(amount / 2);
    }

    receive() external payable {
        if (reentries < MAX_REENTRIES) {
            reentries++;
            uint256 remaining = RebaseToken(address(i_token)).principleBalanceOf(address(this));
            if (remaining > 0) {
                i_vault.redeem(remaining);
            }
        }
    }
}

/**
 * @title VaultTest
 * @notice Unit, integration and fuzz tests for Vault.sol.
 * @dev The Vault must hold the token's MINT_AND_BURN_ROLE (granted in setUp)
 *      because deposit() and redeem() call RebaseToken.mint/burn.
 *
 * Conventions:
 *  - "principal" : tokens actually minted (ERC20._balances), excluding unminted interest.
 *  - interest    : vault only ever holds ETH (deposits + rewards), while token
 *                  balances grow. Redeeming an interest-inclusive balance is only
 *                  possible once rewards cover the difference — several tests pin
 *                  down this accounting.
 */
contract VaultTest is Test {
    RebaseToken private token;
    Vault private vault;

    address private owner;
    address private alice;
    address private bob;

    bytes32 private mintAndBurnRole;

    uint256 private constant PRECISION_FACTOR = 1e18;
    uint256 private constant INITIAL_INTEREST_RATE = 5e10;
    uint256 private constant ONE_DAY = 1 days;
    uint256 private constant START_TIME = 1_700_000_000;

    /*//////////////////////////////////////////////////////////////
                        EXTERNALLY DECLARED ERRORS
    //////////////////////////////////////////////////////////////*/

    // OpenZeppelin errors declared locally so selectors match the library.
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                SET UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.warp(START_TIME);

        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        token = new RebaseToken();
        vault = new Vault(IRebaseToken(address(token)));
        mintAndBurnRole = token.MINT_AND_BURN_ROLE();
        token.grantMintAndBurnRole(address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address _user, uint256 _amount) internal {
        vm.deal(_user, _amount);
        vm.prank(_user);
        vault.deposit{value: _amount}();
    }

    /// @dev Mirrors the token's linear interest formula.
    function _expectedBalance(uint256 _principal, uint256 _rate, uint256 _elapsed) internal pure returns (uint256) {
        return _principal * (PRECISION_FACTOR + _rate * _elapsed) / PRECISION_FACTOR;
    }

    function _accruedInterest(uint256 _principal, uint256 _elapsed) internal pure returns (uint256) {
        return _expectedBalance(_principal, INITIAL_INTEREST_RATE, _elapsed) - _principal;
    }

    /// @dev Sends ETH rewards to the vault through its receive() function.
    function _addRewards(uint256 _amount) internal {
        vm.deal(owner, _amount);
        (bool success,) = address(vault).call{value: _amount}("");
        assertTrue(success);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_StoresRebaseTokenAddress() public view {
        assertEq(vault.getRebaseTokenAddress(), address(token));
    }

    function test_Constructor_VaultHoldsMintAndBurnRole() public view {
        assertTrue(token.hasRole(mintAndBurnRole, address(vault)));
    }

    /*//////////////////////////////////////////////////////////////
                                 DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_MintsEquivalentTokens() public {
        _deposit(alice, 1 ether);

        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.principleBalanceOf(alice), 1 ether);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.totalSupply(), 1 ether);
    }

    function test_Deposit_EmitsDepositEvent() public {
        vm.deal(alice, 1 ether);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, 1 ether);

        vm.prank(alice);
        vault.deposit{value: 1 ether}();
    }

    function test_Deposit_RevertsOnZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(Vault.Vault_DepositAmountIsZero.selector);
        vault.deposit();
    }

    function test_Deposit_RevertsIfVaultLacksMintRole() public {
        Vault unprivilegedVault = new Vault(IRebaseToken(address(token)));
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AccessControlUnauthorizedAccount.selector, address(unprivilegedVault), mintAndBurnRole
            )
        );
        unprivilegedVault.deposit{value: 1 ether}();
    }

    function test_Deposit_MultipleUsersTrackedIndependently() public {
        _deposit(alice, 1 ether);
        _deposit(bob, 2 ether);

        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(address(vault).balance, 3 ether);
        assertEq(token.totalSupply(), 3 ether);
    }

    function test_Deposit_LocksCurrentGlobalInterestRate() public {
        _deposit(alice, 1 ether);
        token.setInterestRate(1e10);
        _deposit(bob, 1 ether);

        assertEq(token.getUserInterestRate(alice), INITIAL_INTEREST_RATE);
        assertEq(token.getUserInterestRate(bob), 1e10);
    }

    /// @dev A second deposit first capitalises interest earned on the first deposit.
    function test_Deposit_AccruesOutstandingInterestBeforeMinting() public {
        _deposit(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ONE_DAY);
        uint256 interest = _accruedInterest(1 ether, ONE_DAY);

        _deposit(alice, 0.5 ether);

        assertEq(token.principleBalanceOf(alice), 1 ether + interest + 0.5 ether);
        assertEq(address(vault).balance, 1.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                 REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_BurnsTokensAndReturnsETH() public {
        _deposit(alice, 1 ether);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(1 ether);

        assertEq(alice.balance, ethBefore + 1 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_Redeem_EmitsRedeemEvent() public {
        _deposit(alice, 1 ether);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, 0.4 ether);

        vm.prank(alice);
        vault.redeem(0.4 ether);
    }

    function test_Redeem_PartialAmount() public {
        _deposit(alice, 1 ether);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(0.4 ether);

        assertEq(alice.balance, ethBefore + 0.4 ether);
        assertEq(token.balanceOf(alice), 0.6 ether);
        assertEq(address(vault).balance, 0.6 ether);
    }

    /// @dev Key vault accounting rule: redeeming the principal returns the ETH,
    ///      but accrued interest stays in the user's wallet as unredeemed tokens
    ///      until rewards are added to the vault.
    function test_Redeem_PrincipalLeavesInterestAsTokens() public {
        _deposit(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ONE_DAY);
        uint256 interest = _accruedInterest(1 ether, ONE_DAY);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(1 ether);

        assertEq(alice.balance, ethBefore + 1 ether);
        assertEq(token.balanceOf(alice), interest);
        assertEq(address(vault).balance, 0);
    }

    /// @dev Redeeming the full interest-inclusive balance fails while the vault
    ///      holds only the principal — and the whole transaction (including the
    ///      burn) is rolled back.
    function test_Redeem_FullBalanceFailsWithoutRewards() public {
        _deposit(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ONE_DAY);
        uint256 balance = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault_RedeemFailed.selector, balance));
        vault.redeem(balance);

        // State must be unchanged after the revert.
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.principleBalanceOf(alice), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_Redeem_FullBalanceSucceedsOnceRewardsCoverInterest() public {
        _deposit(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ONE_DAY);
        uint256 balance = token.balanceOf(alice);
        _addRewards(balance - 1 ether); // exactly cover the accrued interest

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(balance);

        assertEq(alice.balance, ethBefore + balance);
        assertEq(token.balanceOf(alice), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_Redeem_LeavesExcessRewardsInVault() public {
        _deposit(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ONE_DAY);
        uint256 balance = token.balanceOf(alice);
        _addRewards(0.1 ether); // more than the ~0.00432 interest

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(balance);

        assertEq(alice.balance, ethBefore + balance);
        assertEq(token.balanceOf(alice), 0);
        assertEq(address(vault).balance, 0.1 ether - (balance - 1 ether));
    }

    function test_Redeem_RevertsWhenAmountExceedsBalance() public {
        _deposit(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, alice, 1 ether, 1 ether + 1));
        vault.redeem(1 ether + 1);
    }

    /// @dev The type(uint256).max sentinel is resolved in the vault to the caller's
    ///      interest-inclusive balance, so "redeem everything" works end to end.
    function test_Redeem_TypeMaxRedeemsFullBalance() public {
        _deposit(alice, 1 ether);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(type(uint256).max);

        assertEq(alice.balance, ethBefore + 1 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(address(vault).balance, 0);
    }

    /// @dev With rewards covering accrued interest, the sentinel redeems the
    ///      full interest-inclusive balance.
    function test_Redeem_TypeMaxRedeemsInterestInclusiveBalanceWithRewards() public {
        _deposit(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ONE_DAY);
        uint256 balance = token.balanceOf(alice);
        _addRewards(balance - 1 ether);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(type(uint256).max);

        assertEq(alice.balance, ethBefore + balance);
        assertEq(token.balanceOf(alice), 0);
        assertEq(address(vault).balance, 0);
    }

    /// @dev Without sufficient ETH the sentinel still reverts — but now because
    ///      the vault is illiquid, not because the sentinel itself is broken.
    function test_Redeem_TypeMaxRevertsWhenVaultCannotCoverBalance() public {
        _deposit(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ONE_DAY);
        uint256 balance = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault_RedeemFailed.selector, balance));
        vault.redeem(type(uint256).max);

        assertEq(token.balanceOf(alice), balance);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_Redeem_RevertsOnFailingReceiver() public {
        RevertingReceiver receiver = new RevertingReceiver(vault);
        vm.deal(address(receiver), 1 ether);
        receiver.deposit{value: 1 ether}();
        assertEq(token.balanceOf(address(receiver)), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Vault.Vault_RedeemFailed.selector, 1 ether));
        receiver.redeem(1 ether);

        // Burn was rolled back together with the failed ETH transfer.
        assertEq(token.balanceOf(address(receiver)), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    /// @dev redeem(0) is a valid no-op that still capitalises accrued interest
    ///      into the caller's principal (the token's burn path syncs first).
    function test_Redeem_ZeroAmountSyncsInterest() public {
        _deposit(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ONE_DAY);
        uint256 interest = _accruedInterest(1 ether, ONE_DAY);

        uint256 ethBefore = alice.balance;
        uint256 vaultEthBefore = address(vault).balance;
        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, 0);

        vm.prank(alice);
        vault.redeem(0);

        assertEq(alice.balance, ethBefore);
        assertEq(address(vault).balance, vaultEthBefore);
        assertEq(token.principleBalanceOf(alice), 1 ether + interest);
        assertEq(token.balanceOf(alice), 1 ether + interest);
    }

    function test_Redeem_CannotDrainAnotherUser() public {
        _deposit(alice, 1 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, bob, 0, 1 ether));
        vault.redeem(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                 REWARDS
    //////////////////////////////////////////////////////////////*/

    function test_Receive_AcceptsRewardsWithoutMinting() public {
        _deposit(alice, 1 ether);
        uint256 supplyBefore = token.totalSupply();

        _addRewards(0.5 ether);

        assertEq(address(vault).balance, 1.5 ether);
        assertEq(token.totalSupply(), supplyBefore);
    }

    /// @dev Two users, one rate cut, sequential redemptions — full integration
    ///      of the vault with the token's per-user rate locking. Also documents
    ///      pooled liquidity: the vault owes deposits + interest but only holds
    ///      deposits, so early exiters draw on the shared pool.
    function test_Scenario_TwoUsersWithRewardsFlow() public {
        _deposit(alice, 1 ether); // alice locks 5e10
        token.setInterestRate(1e10);
        _deposit(bob, 2 ether); // bob locks 1e10

        vm.warp(vm.getBlockTimestamp() + ONE_DAY);

        uint256 aliceInterest = _accruedInterest(1 ether, ONE_DAY); // at 5e10
        uint256 bobInterest = _expectedBalance(2 ether, 1e10, ONE_DAY) - 2 ether; // at 1e10
        assertEq(token.balanceOf(alice), 1 ether + aliceInterest);
        assertEq(token.balanceOf(bob), 2 ether + bobInterest);

        // alice exits first, drawing on the pool of all deposits (3 ETH).
        // Balance must be read BEFORE the prank: the external call would
        // otherwise consume the one-shot prank.
        uint256 aliceBalance = token.balanceOf(alice);
        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(aliceBalance);
        assertEq(alice.balance, aliceEthBefore + 1 ether + aliceInterest);
        assertEq(token.balanceOf(alice), 0);

        // Vault now holds less than bob's interest-inclusive balance: his full
        // exit fails until rewards are added.
        uint256 bobBalance = token.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault_RedeemFailed.selector, bobBalance));
        vault.redeem(bobBalance);

        // Rewards covering both users' interest settle the pool exactly.
        _addRewards(aliceInterest + bobInterest);

        uint256 bobEthBefore = bob.balance;
        vm.prank(bob);
        vault.redeem(bobBalance);
        assertEq(bob.balance, bobEthBefore + 2 ether + bobInterest);
        assertEq(token.balanceOf(bob), 0);

        // Every wei of deposits + rewards accounted for.
        assertEq(address(vault).balance, 0);
        assertEq(token.totalSupply(), 0);
    }

    /// @dev A re-entrant redeem during the ETH transfer can never pull out more
    ///      than the attacker's own token balance — burn-before-send holds.
    function test_Scenario_ReentrancyCannotDoubleSpend() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(vault);

        vm.deal(owner, 1 ether);
        attacker.attack{value: 1 ether}();

        assertEq(attacker.reentries(), 1);
        assertEq(address(attacker).balance, 1 ether);
        assertEq(token.balanceOf(address(attacker)), 0);
        assertEq(address(vault).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Deposit_MintsEquivalentTokens(uint96 _amount) public {
        uint256 amount = bound(uint256(_amount), 1, 1e24);

        _deposit(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.principleBalanceOf(alice), amount);
        assertEq(address(vault).balance, amount);
    }

    /// @dev At time zero (no interest), a deposit followed by a full principal
    ///      redeem returns every wei: the 1:1 peg round-trips exactly.
    function testFuzz_DepositRedeem_PrincipalRoundTrip(uint96 _amount) public {
        uint256 amount = bound(uint256(_amount), 1, 1e24);

        _deposit(alice, amount);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(amount);

        assertEq(alice.balance, ethBefore + amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(address(vault).balance, 0);
    }

    /// @dev Partial redeem within the principal after time passes: the user gets
    ///      exactly the requested ETH and the vault keeps the remainder.
    function testFuzz_PartialRedeemAfterTime(uint96 _depositAmount, uint32 _elapsed, uint96 _redeemAmount) public {
        uint256 depositAmount = bound(uint256(_depositAmount), 1, 1e24);
        uint256 elapsed = bound(uint256(_elapsed), 0, 365 days);
        uint256 redeemAmount = bound(uint256(_redeemAmount), 0, depositAmount);

        _deposit(alice, depositAmount);
        vm.warp(vm.getBlockTimestamp() + elapsed);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(redeemAmount);

        assertEq(alice.balance, ethBefore + redeemAmount);
        assertEq(token.balanceOf(alice), _expectedBalance(depositAmount, INITIAL_INTEREST_RATE, elapsed) - redeemAmount);
        assertEq(address(vault).balance, depositAmount - redeemAmount);
    }

    /// @dev With rewards covering the accrued interest, the full interest-inclusive
    ///      balance is always redeemable and the vault settles to exactly the
    ///      leftover rewards.
    function testFuzz_FullRedeemWithRewards(uint96 _depositAmount, uint32 _elapsed, uint96 _extraReward) public {
        uint256 depositAmount = bound(uint256(_depositAmount), 1, 1e22);
        uint256 elapsed = bound(uint256(_elapsed), 0, 30 days);
        uint256 extraReward = bound(uint256(_extraReward), 0, 1e18);

        _deposit(alice, depositAmount);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 balance = token.balanceOf(alice);
        uint256 interest = balance - depositAmount;

        _addRewards(interest + extraReward);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        vault.redeem(balance);

        assertEq(alice.balance, ethBefore + balance);
        assertEq(token.balanceOf(alice), 0);
        assertEq(address(vault).balance, extraReward);
    }
}
