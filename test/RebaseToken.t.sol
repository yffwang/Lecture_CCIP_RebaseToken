// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../src/RebaseToken.sol";

/**
 * @title RebaseTokenTest
 * @notice Unit, edge-case and fuzz tests for RebaseToken.sol.
 *
 * Conventions used below:
 *  - "principal"  : tokens actually minted to a user (ERC20._balances), excluding unminted interest.
 *  - "balance"    : interest-inclusive value returned by RebaseToken.balanceOf().
 *  - interest     : balance = principal * (1e18 + userRate * elapsed) / 1e18
 */
contract RebaseTokenTest is Test {
    RebaseToken private token;

    // The test contract deploys the token, so it is the owner.
    address private owner;
    address private minter;
    address private alice;
    address private bob;
    address private carol;

    uint256 private constant PRECISION_FACTOR = 1e18;
    uint256 private constant INITIAL_INTEREST_RATE = 5e10;
    uint256 private constant ONE_DAY = 1 days;
    uint256 private constant START_TIME = 1_700_000_000;

    bytes32 private mintAndBurnRole;

    /*//////////////////////////////////////////////////////////////
                        EXTERNALLY DECLARED ERRORS
    //////////////////////////////////////////////////////////////*/

    // OpenZeppelin errors are declared locally so the selectors match the library
    // declarations exactly (same name + same parameter types => same selector).
    error OwnableUnauthorizedAccount(address account);
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSender(address sender);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 value);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event InterestRateSet(uint256 newInterestRate);

    /*//////////////////////////////////////////////////////////////
                                SET UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.warp(START_TIME);

        owner = address(this);
        minter = makeAddr("minter");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        token = new RebaseToken();
        mintAndBurnRole = token.MINT_AND_BURN_ROLE();
        token.grantMintAndBurnRole(minter);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mint(address _to, uint256 _amount) private {
        vm.prank(minter);
        token.mint(_to, _amount);
    }

    function _burn(address _from, uint256 _amount) private {
        vm.prank(minter);
        token.burn(_from, _amount);
    }

    /// @dev Expected interest-inclusive balance using the same linear formula as the contract.
    function _expectedBalance(uint256 _principal, uint256 _rate, uint256 _elapsed) private pure returns (uint256) {
        return _principal * (PRECISION_FACTOR + _rate * _elapsed) / PRECISION_FACTOR;
    }

    /// @dev Advance time and return the elapsed amount.
    function _warp(uint256 _seconds) private returns (uint256) {
        vm.warp(vm.getBlockTimestamp() + _seconds);
        return _seconds;
    }

    /*//////////////////////////////////////////////////////////////
                       CONSTRUCTOR / METADATA / GETTERS
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public view {
        assertEq(token.name(), "Rebase Token");
        assertEq(token.symbol(), "RBT");
        assertEq(token.totalSupply(), 0);
    }

    function test_Constructor_SetsDeployerAsOwner() public view {
        assertEq(token.owner(), owner);
    }

    function test_Constructor_SetsInitialInterestRate() public view {
        assertEq(token.getInterestRate(), INITIAL_INTEREST_RATE);
    }

    function test_Constructor_MintAndBurnRoleId() public view {
        assertEq(mintAndBurnRole, keccak256("MINT_AND_BURN_ROLE"));
    }

    function test_GetUserInterestRate_IsZeroForNewUser() public view {
        assertEq(token.getUserInterestRate(alice), 0);
    }

    function test_PrincipleBalanceOf_IsZeroForNewUser() public view {
        assertEq(token.principleBalanceOf(alice), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_GrantMintAndBurnRole_GrantsRole() public {
        token.grantMintAndBurnRole(alice);
        assertTrue(token.hasRole(mintAndBurnRole, alice));
    }

    function test_GrantMintAndBurnRole_EmitsRoleGranted() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit RoleGranted(mintAndBurnRole, alice, owner);

        token.grantMintAndBurnRole(alice);
    }

    function test_GrantMintAndBurnRole_RevertsIfCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        token.grantMintAndBurnRole(bob);
    }

    function test_GrantMintAndBurnRole_DoesNotGrantAdminRole() public {
        token.grantMintAndBurnRole(alice);
        assertFalse(token.hasRole(bytes32(0), alice));
    }

    function test_Mint_RevertsIfCallerLacksRole() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, alice, mintAndBurnRole));
        token.mint(alice, 1e18);
    }

    function test_Burn_RevertsIfCallerLacksRole() public {
        _mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, alice, mintAndBurnRole));
        token.burn(alice, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            SET INTEREST RATE
    //////////////////////////////////////////////////////////////*/

    function test_SetInterestRate_DecreasesRate() public {
        token.setInterestRate(1e10);
        assertEq(token.getInterestRate(), 1e10);
    }

    function test_SetInterestRate_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit InterestRateSet(1e10);

        token.setInterestRate(1e10);
    }

    function test_SetInterestRate_CanBeSetToSameValue() public {
        token.setInterestRate(INITIAL_INTEREST_RATE);
        assertEq(token.getInterestRate(), INITIAL_INTEREST_RATE);
    }

    function test_SetInterestRate_CanBeSetToZero() public {
        token.setInterestRate(0);
        assertEq(token.getInterestRate(), 0);
    }

    function test_SetInterestRate_RevertsWhenIncreasing() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                RebaseToken.RebaseToken__InterestRateCanOnlyDecrease.selector,
                INITIAL_INTEREST_RATE,
                INITIAL_INTEREST_RATE + 1
            )
        );
        token.setInterestRate(INITIAL_INTEREST_RATE + 1);
    }

    function test_SetInterestRate_RevertsWhenIncreasingAfterADecrease() public {
        token.setInterestRate(1e10);

        vm.expectRevert(
            abi.encodeWithSelector(RebaseToken.RebaseToken__InterestRateCanOnlyDecrease.selector, 1e10, 2e10)
        );
        token.setInterestRate(2e10);
    }

    function test_SetInterestRate_RevertsIfCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        token.setInterestRate(1e10);
    }

    /*//////////////////////////////////////////////////////////////
                                 MINT
    //////////////////////////////////////////////////////////////*/

    function test_Mint_SetsPrincipalAndRate() public {
        _mint(alice, 100e18);

        assertEq(token.principleBalanceOf(alice), 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.getUserInterestRate(alice), INITIAL_INTEREST_RATE);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_Mint_ToMultipleUsers() public {
        _mint(alice, 100e18);
        _mint(bob, 25e18);

        assertEq(token.principleBalanceOf(alice), 100e18);
        assertEq(token.principleBalanceOf(bob), 25e18);
        assertEq(token.totalSupply(), 125e18);
    }

    /// @dev A second mint must first capitalise the interest accrued since the last interaction.
    function test_Mint_AccruesOutstandingInterestFirst() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 expectedInterest = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed) - 100e18;

        _mint(alice, 1e18);

        // Interest was minted into principal before the new deposit was added.
        assertEq(token.principleBalanceOf(alice), 100e18 + expectedInterest + 1e18);
        assertEq(token.balanceOf(alice), 100e18 + expectedInterest + 1e18);
        // Time was reset, so no further interest has accrued yet.
        assertEq(token.balanceOf(alice), _expectedBalance(100e18 + expectedInterest + 1e18, INITIAL_INTEREST_RATE, 0));
    }

    /// @dev Documents the design: minting re-locks the user's rate to the *current* global rate.
    ///      Because the global rate can only decrease, a redeposit lowers the user's future rate
    ///      (already-accrued interest is preserved by the _mintAccruedInterest call).
    function test_Mint_RelocksUserRateToCurrentGlobalRate() public {
        _mint(alice, 100e18);
        assertEq(token.getUserInterestRate(alice), INITIAL_INTEREST_RATE);

        token.setInterestRate(1e10);
        _mint(alice, 1e18);

        assertEq(token.getUserInterestRate(alice), 1e10);
    }

    function test_Mint_RevertsOnZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 1e18);
    }

    function testFuzz_Mint_PrincipalEqualsAmount(uint96 _amount) public {
        uint256 amount = bound(uint256(_amount), 0, 1e30);

        _mint(alice, amount);

        assertEq(token.principleBalanceOf(alice), amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 BURN
    //////////////////////////////////////////////////////////////*/

    function test_Burn_ReducesPrincipal() public {
        _mint(alice, 100e18);

        _burn(alice, 40e18);

        assertEq(token.principleBalanceOf(alice), 60e18);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.totalSupply(), 60e18);
    }

    /// @dev Burning only the principal leaves accrued interest behind as new principal.
    function test_Burn_AccruesInterestFirst() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 expectedInterest = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed) - 100e18;

        _burn(alice, 100e18);

        assertEq(token.principleBalanceOf(alice), expectedInterest);
        assertEq(token.balanceOf(alice), expectedInterest);
    }

    function test_Burn_TypeMaxBurnsEntireBalance() public {
        _mint(alice, 100e18);
        _warp(ONE_DAY);

        _burn(alice, type(uint256).max);

        assertEq(token.principleBalanceOf(alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_Burn_TypeMaxWhenBalanceIsZeroDoesNotRevert() public {
        _burn(alice, type(uint256).max);

        assertEq(token.balanceOf(alice), 0);
    }

    function test_Burn_TypeMaxOnlyBurnsCallersTarget() public {
        _mint(alice, 100e18);
        _mint(bob, 50e18);

        _burn(alice, type(uint256).max);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 50e18);
        assertEq(token.totalSupply(), 50e18);
    }

    function test_Burn_RevertsWhenAmountExceedsBalance() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 balance = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, alice, balance, balance + 1));
        token.burn(alice, balance + 1);
    }

    function test_Burn_KeepsUserInterestRate() public {
        _mint(alice, 100e18);
        _burn(alice, type(uint256).max);

        assertEq(token.getUserInterestRate(alice), INITIAL_INTEREST_RATE);
    }

    function test_Burn_RevertsOnZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(ERC20InvalidSender.selector, address(0)));
        token.burn(address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            BALANCE / INTEREST
    //////////////////////////////////////////////////////////////*/

    function test_BalanceOf_NoInterestBeforeTimePasses() public {
        _mint(alice, 100e18);

        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_BalanceOf_AccruesLinearInterest() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);

        assertEq(token.balanceOf(alice), _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed));
        // Principal is unaffected until interest is capitalised.
        assertEq(token.principleBalanceOf(alice), 100e18);
    }

    function test_BalanceOf_ExactValuesAfterOneDay() public {
        _mint(alice, 1e18);

        vm.warp(vm.getBlockTimestamp() + ONE_DAY);

        // 1e18 * 5e10 / 1e18 = 5e10 tokens per second => 4.32e15 after 86_400 seconds.
        assertEq(token.balanceOf(alice), 1e18 + 4.32e15);
    }

    function test_BalanceOf_InterestIsLinearInTime() public {
        _mint(alice, 1e18);

        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 tenSeconds = token.balanceOf(alice) - 1e18;

        vm.warp(vm.getBlockTimestamp() + 90);
        uint256 hundredSeconds = token.balanceOf(alice) - 1e18;

        assertEq(hundredSeconds, tenSeconds * 10);
    }

    /// @dev A user keeps the rate that was locked in at deposit time, even if the global rate drops.
    function test_BalanceOf_UsesUserRateNotGlobalRate() public {
        _mint(alice, 100e18);
        token.setInterestRate(0);

        uint256 elapsed = _warp(ONE_DAY);

        assertEq(token.balanceOf(alice), _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed));
    }

    function test_BalanceOf_ZeroInterestRateDoesNotAccrue() public {
        token.setInterestRate(0);
        _mint(alice, 100e18);

        _warp(30 days);

        assertEq(token.balanceOf(alice), 100e18);
    }

    /// @dev The user rate is locked at deposit, so lowering the global rate does not change
    ///      the accrual of an existing depositor.
    function test_BalanceOf_RateLockedAtDepositTime() public {
        token.setInterestRate(2e10);
        _mint(alice, 100e18);

        token.setInterestRate(1e10);
        uint256 elapsed = _warp(ONE_DAY);

        assertEq(token.balanceOf(alice), _expectedBalance(100e18, 2e10, elapsed));
    }

    function test_TotalSupply_ExcludesUnmintedInterest() public {
        _mint(alice, 100e18);
        _warp(ONE_DAY);

        assertEq(token.totalSupply(), 100e18);
        assertGt(token.balanceOf(alice), token.totalSupply());
    }

    function test_TotalSupply_CatchesUpAfterSync() public {
        _mint(alice, 100e18);
        _warp(ONE_DAY);
        uint256 accrued = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(alice, 0); // any interaction capitalises the interest

        assertEq(token.totalSupply(), accrued);
        assertEq(token.principleBalanceOf(alice), accrued);
    }

    function testFuzz_BalanceOf_LinearInterest(uint96 _principal, uint32 _elapsed, uint64 _rate) public {
        uint256 principal = bound(uint256(_principal), 0, 1e26);
        uint256 elapsed = bound(uint256(_elapsed), 0, 365 days);
        uint256 rate = bound(uint256(_rate), 0, INITIAL_INTEREST_RATE);

        token.setInterestRate(rate);
        _mint(alice, principal);
        vm.warp(vm.getBlockTimestamp() + elapsed);

        assertEq(token.balanceOf(alice), _expectedBalance(principal, rate, elapsed));
    }

    function testFuzz_BalanceOf_NeverBelowPrincipal(uint96 _principal, uint32 _elapsed) public {
        uint256 principal = bound(uint256(_principal), 0, 1e30);

        _mint(alice, principal);
        vm.warp(vm.getBlockTimestamp() + bound(uint256(_elapsed), 0, 10 * 365 days));

        assertGe(token.balanceOf(alice), token.principleBalanceOf(alice));
    }

    /*//////////////////////////////////////////////////////////////
                               TRANSFER
    //////////////////////////////////////////////////////////////*/

    function test_Transfer_MovesPrincipal() public {
        _mint(alice, 100e18);

        vm.prank(alice);
        token.transfer(bob, 40e18);

        assertEq(token.principleBalanceOf(alice), 60e18);
        assertEq(token.principleBalanceOf(bob), 40e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_Transfer_EmitsTransferWithRequestedAmount() public {
        _mint(alice, 100e18);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(alice, bob, 40e18);

        vm.prank(alice);
        token.transfer(bob, 40e18);
    }

    function test_Transfer_ReturnsTrue() public {
        _mint(alice, 100e18);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 1e18));
    }

    function test_Transfer_CapitalisesSenderInterest() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 expectedInterest = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed) - 100e18;

        vm.prank(alice);
        token.transfer(bob, 10e18);

        // alice: principal + interest - transferred
        assertEq(token.principleBalanceOf(alice), 100e18 + expectedInterest - 10e18);
        assertEq(token.balanceOf(alice), 100e18 + expectedInterest - 10e18);
    }

    function test_Transfer_CapitalisesRecipientInterest() public {
        _mint(bob, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 bobInterest = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed) - 100e18;

        _mint(alice, 10e18);
        vm.prank(alice);
        token.transfer(bob, 10e18);

        assertEq(token.principleBalanceOf(bob), 100e18 + bobInterest + 10e18);
        assertEq(token.balanceOf(bob), 100e18 + bobInterest + 10e18);
    }

    /// @dev A brand new recipient inherits the sender's (possibly higher) rate, not the global rate.
    function test_Transfer_NewRecipientInheritsSenderRate() public {
        _mint(alice, 100e18); // alice locked at 5e10
        token.setInterestRate(1e10); // global rate drops

        vm.prank(alice);
        token.transfer(bob, 10e18);

        assertEq(token.getUserInterestRate(bob), INITIAL_INTEREST_RATE);
    }

    /// @dev An existing recipient keeps their own locked rate.
    function test_Transfer_ExistingRecipientKeepsOwnRate() public {
        _mint(alice, 100e18); // alice at 5e10
        token.setInterestRate(1e10);
        _mint(bob, 100e18); // bob at 1e10

        vm.prank(alice);
        token.transfer(bob, 10e18);

        assertEq(token.getUserInterestRate(bob), 1e10);
        assertEq(token.getUserInterestRate(alice), INITIAL_INTEREST_RATE);
    }

    function test_Transfer_RecipientRateDrivesFutureAccrual() public {
        _mint(alice, 100e18);
        token.setInterestRate(1e10);

        vm.prank(alice);
        token.transfer(bob, 100e18);

        uint256 elapsed = _warp(ONE_DAY);
        assertEq(token.balanceOf(bob), _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed));
    }

    /// @dev A recipient whose balance was fully burnt has a stale rate but a zero balance, so the
    ///      next incoming transfer re-locks their rate to the sender's.
    function test_Transfer_ZeroBalanceRecipientRelocksRate() public {
        token.setInterestRate(1e10);
        _mint(bob, 100e18);
        _burn(bob, type(uint256).max);
        assertEq(token.balanceOf(bob), 0);

        _mint(alice, 100e18); // alice at 1e10 too, lower it for clarity
        token.setInterestRate(0);
        _mint(carol, 100e18); // carol locked at 0
        vm.prank(carol);
        token.transfer(bob, 1e18);

        assertEq(token.getUserInterestRate(bob), 0);
    }

    function test_Transfer_TypeMaxMovesEntireBalanceIncludingInterest() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 expected = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed);

        vm.prank(alice);
        token.transfer(bob, type(uint256).max);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.principleBalanceOf(alice), 0);
        assertEq(token.balanceOf(bob), expected);
        assertEq(token.principleBalanceOf(bob), expected);
        assertEq(token.totalSupply(), expected);
    }

    function test_Transfer_TypeMaxFromEmptyBalanceTransfersNothing() public {
        vm.prank(alice);
        token.transfer(bob, type(uint256).max);

        assertEq(token.balanceOf(bob), 0);
        assertEq(token.getUserInterestRate(bob), 0);
    }

    function test_Transfer_ZeroAmountDoesNotLockRateForNewRecipient() public {
        _mint(alice, 100e18);

        vm.prank(alice);
        token.transfer(bob, 0);

        assertEq(token.getUserInterestRate(bob), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_Transfer_ToSelfIsANoOp() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 expected = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed);

        vm.prank(alice);
        token.transfer(alice, 100e18);

        assertEq(token.balanceOf(alice), expected);
        assertEq(token.totalSupply(), expected);
    }

    function test_Transfer_RevertsWhenAmountExceedsBalance() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 balance = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, alice, balance, balance + 1));
        token.transfer(bob, balance + 1);
    }

    function test_Transfer_RevertsOnZeroAddress() public {
        _mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function testFuzz_Transfer_ConservesPrincipalAndSupply(uint96 _mintAmount, uint32 _elapsed, uint96 _transferAmount)
        public
    {
        uint256 mintAmount = bound(uint256(_mintAmount), 1, 1e26);
        _mint(alice, mintAmount);
        vm.warp(vm.getBlockTimestamp() + bound(uint256(_elapsed), 0, 365 days));

        uint256 balance = token.balanceOf(alice);
        uint256 amount = bound(uint256(_transferAmount), 0, balance);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.principleBalanceOf(alice) + token.principleBalanceOf(bob), token.totalSupply());
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), token.totalSupply());
    }

    function testFuzz_Transfer_SenderBalanceDecreasesByAmount(
        uint96 _mintAmount,
        uint32 _elapsed,
        uint96 _transferAmount
    ) public {
        _mint(alice, bound(uint256(_mintAmount), 1, 1e26));
        vm.warp(vm.getBlockTimestamp() + bound(uint256(_elapsed), 0, 365 days));

        uint256 senderBalance = token.balanceOf(alice);
        uint256 amount = bound(uint256(_transferAmount), 0, senderBalance);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(alice), senderBalance - amount);
    }

    /*//////////////////////////////////////////////////////////////
                             TRANSFER FROM
    //////////////////////////////////////////////////////////////*/

    function test_TransferFrom_SpendsAllowance() public {
        _mint(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 50e18);

        vm.prank(bob);
        token.transferFrom(alice, carol, 30e18);

        assertEq(token.balanceOf(carol), 30e18);
        assertEq(token.allowance(alice, bob), 20e18);
    }

    function test_TransferFrom_RevertsWithoutAllowance() public {
        _mint(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientAllowance.selector, bob, 0, 1e18));
        token.transferFrom(alice, carol, 1e18);
    }

    function test_TransferFrom_RevertsWhenAllowanceTooLow() public {
        _mint(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientAllowance.selector, bob, 10e18, 20e18));
        token.transferFrom(alice, carol, 20e18);
    }

    function test_TransferFrom_NewRecipientInheritsSenderRate() public {
        _mint(alice, 100e18); // alice at 5e10
        token.setInterestRate(0);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 10e18);

        assertEq(token.getUserInterestRate(carol), INITIAL_INTEREST_RATE);
    }

    function test_TransferFrom_ExistingRecipientKeepsOwnRate() public {
        _mint(alice, 100e18); // 5e10
        token.setInterestRate(1e10);
        _mint(carol, 100e18); // 1e10
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 10e18);

        assertEq(token.getUserInterestRate(carol), 1e10);
    }

    function test_TransferFrom_TypeMaxMovesFullInterestInclusiveBalance() public {
        _mint(alice, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 expected = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, type(uint256).max);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(carol), expected);
        assertEq(token.totalSupply(), expected);
    }

    function test_TransferFrom_CapitalisesBothSides() public {
        _mint(alice, 100e18);
        _mint(carol, 100e18);
        uint256 elapsed = _warp(ONE_DAY);
        uint256 aliceInterest = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed) - 100e18;
        uint256 carolInterest = _expectedBalance(100e18, INITIAL_INTEREST_RATE, elapsed) - 100e18;

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 10e18);

        assertEq(token.principleBalanceOf(alice), 100e18 + aliceInterest - 10e18);
        assertEq(token.principleBalanceOf(carol), 100e18 + carolInterest + 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                        MULTI-USER / TIME SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @dev Two depositors at different times keep different rates, and interest is
    ///      capitalised independently on every interaction.
    function test_Scenario_TwoDepositorsDifferentRates() public {
        _mint(alice, 100e18); // 5e10
        token.setInterestRate(1e10);
        _mint(bob, 100e18); // 1e10

        vm.warp(vm.getBlockTimestamp() + ONE_DAY);

        assertEq(token.balanceOf(alice), _expectedBalance(100e18, 5e10, ONE_DAY));
        assertEq(token.balanceOf(bob), _expectedBalance(100e18, 1e10, ONE_DAY));

        // A transfer to bob capitalises his interest at his own rate.
        vm.prank(alice);
        token.transfer(bob, 0);
        assertEq(token.balanceOf(bob), _expectedBalance(100e18, 1e10, ONE_DAY));
        assertEq(token.totalSupply(), _expectedBalance(100e18, 5e10, ONE_DAY) + _expectedBalance(100e18, 1e10, ONE_DAY));
    }

    function test_Scenario_TransferBackAndForthKeepsRates() public {
        _mint(alice, 100e18);
        token.setInterestRate(1e10);

        vm.prank(alice);
        token.transfer(bob, 50e18);
        assertEq(token.getUserInterestRate(bob), 5e10);

        vm.prank(bob);
        token.transfer(alice, 50e18);

        assertEq(token.getUserInterestRate(alice), 5e10);
        assertEq(token.getUserInterestRate(bob), 5e10);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_Scenario_BurnAllThenReceiveAgain() public {
        _mint(alice, 100e18);
        _warp(ONE_DAY);
        _burn(alice, type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);

        _mint(alice, 10e18);
        uint256 elapsed = _warp(ONE_DAY);

        assertEq(token.balanceOf(alice), _expectedBalance(10e18, INITIAL_INTEREST_RATE, elapsed));
    }
}
