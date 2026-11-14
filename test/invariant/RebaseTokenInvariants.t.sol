// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";

/**
 * @title RebaseTokenHandler
 * @notice Restricts the invariant fuzzer to meaningful, valid token interactions.
 * @dev Every external call into the token reads its state *before* creating a prank:
 *      cheatcode pranks are one-shot, so an external call in the argument list of
 *      vm.prank(...)'s target would silently consume it.
 */
contract RebaseTokenHandler is Test {
    RebaseToken public immutable token;
    address public immutable owner;
    address public immutable minter;

    address[] internal _users;

    constructor(RebaseToken _token, address _owner, address _minter, address[] memory _actors) {
        token = _token;
        owner = _owner;
        minter = _minter;
        for (uint256 i; i < _actors.length; ++i) {
            _users.push(_actors[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function mint(uint256 userSeed, uint256 amount) public {
        address user = _actor(userSeed);
        uint256 mintAmount = bound(amount, 0, 1e27);

        vm.prank(minter);
        token.mint(user, mintAmount);
    }

    function burn(uint256 userSeed, uint256 amount) public {
        address user = _actor(userSeed);
        uint256 burnAmount = bound(amount, 0, token.balanceOf(user));

        vm.prank(minter);
        token.burn(user, burnAmount);
    }

    function burnAll(uint256 userSeed) public {
        address user = _actor(userSeed);

        vm.prank(minter);
        token.burn(user, type(uint256).max);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 transferAmount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        token.transfer(to, transferAmount);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);

        vm.prank(from);
        token.transfer(to, type(uint256).max);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address tokenOwner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 transferAmount = bound(amount, 0, token.balanceOf(tokenOwner));

        vm.prank(tokenOwner);
        token.approve(spender, type(uint256).max);

        vm.prank(spender);
        token.transferFrom(tokenOwner, to, transferAmount);
    }

    function setInterestRate(uint256 newRate) public {
        uint256 rate = bound(newRate, 0, token.getInterestRate());

        vm.prank(owner);
        token.setInterestRate(rate);
    }

    function advanceTime(uint256 secondsToAdvance) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsToAdvance, 0, 30 days));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _actor(uint256 _seed) internal view returns (address) {
        return _users[bound(_seed, 0, _users.length - 1)];
    }
}

/**
 * @title RebaseTokenInvariantsTest
 * @notice Stateful fuzzing of the invariants that must always hold for RebaseToken.
 */
contract RebaseTokenInvariantsTest is Test {
    RebaseToken private token;
    RebaseTokenHandler private handler;

    address[] private users;

    address private owner;
    address private minter;

    uint256 private constant USER_COUNT = 5;
    uint256 private constant INITIAL_INTEREST_RATE = 5e10;

    function setUp() public {
        vm.warp(1_700_000_000);

        owner = address(this);
        minter = makeAddr("minter");
        for (uint256 i; i < USER_COUNT; ++i) {
            users.push(makeAddr(string.concat("user", vm.toString(i))));
        }

        token = new RebaseToken();
        token.grantMintAndBurnRole(minter);

        handler = new RebaseTokenHandler(token, owner, minter, users);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = RebaseTokenHandler.mint.selector;
        selectors[1] = RebaseTokenHandler.burn.selector;
        selectors[2] = RebaseTokenHandler.burnAll.selector;
        selectors[3] = RebaseTokenHandler.transfer.selector;
        selectors[4] = RebaseTokenHandler.transferAll.selector;
        selectors[5] = RebaseTokenHandler.transferFrom.selector;
        selectors[6] = RebaseTokenHandler.setInterestRate.selector;
        selectors[7] = RebaseTokenHandler.advanceTime.selector;

        // Restrict the fuzzer to the handler: without this, contracts deployed in setUp (the
        // token itself) are still targeted, so calls arrive with untracked senders/recipients.
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                               INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC20 totalSupply must always equal the sum of the principal balances:
    ///      minted interest increases both, burns decrease both.
    function invariant_TotalSupplyEqualsSumOfPrincipalBalances() public view {
        assertEq(_sumPrincipalBalances(), token.totalSupply());
    }

    /// @dev Accrued but unminted interest must never make a balance smaller than its principal.
    function invariant_BalanceOfAtLeastPrincipal() public view {
        for (uint256 i; i < users.length; ++i) {
            assertGe(token.balanceOf(users[i]), token.principleBalanceOf(users[i]));
        }
    }

    /// @dev Because balances include unminted interest, their sum is at least totalSupply.
    function invariant_SumOfBalancesAtLeastTotalSupply() public view {
        uint256 sumBalances;
        for (uint256 i; i < users.length; ++i) {
            sumBalances += token.balanceOf(users[i]);
        }
        assertGe(sumBalances, token.totalSupply());
    }

    /// @dev A user's locked rate can never fall below the global rate: rates only decrease and
    ///      each user's rate is either the global rate at deposit time or inherited from a sender.
    ///      No rate can ever exceed the rate the token was deployed with.
    function invariant_UserRateNeverBelowGlobalRate() public view {
        uint256 globalRate = token.getInterestRate();
        assertLe(globalRate, INITIAL_INTEREST_RATE);

        for (uint256 i; i < users.length; ++i) {
            uint256 userRate = token.getUserInterestRate(users[i]);
            assertLe(userRate, INITIAL_INTEREST_RATE);
            if (userRate == 0) continue;
            assertGe(userRate, globalRate);
        }
    }

    /// @dev The MINT_AND_BURN_ROLE is only ever held by the minter the test granted it to.
    function invariant_OnlyMinterHoldsMintAndBurnRole() public view {
        for (uint256 i; i < users.length; ++i) {
            assertFalse(token.hasRole(token.MINT_AND_BURN_ROLE(), users[i]));
        }
        assertTrue(token.hasRole(token.MINT_AND_BURN_ROLE(), minter));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _sumPrincipalBalances() private view returns (uint256 sum) {
        for (uint256 i; i < users.length; ++i) {
            sum += token.principleBalanceOf(users[i]);
        }
    }
}
