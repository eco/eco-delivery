// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deliver} from "../src/Deliver.sol";
import {ReentrantNativeRecipient, ReentrantTokenRecipient} from "./mocks/MockReceivers.sol";
import {PreUpdateHookERC20, RecipientHookERC20} from "./mocks/MockTokens.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The contract has no state to corrupt and does the transfer last, but "that is fine" is a
///         claim until it is exercised. These tests re-enter from a token hook and from a native
///         recipient and check what the re-entrant call actually sees.
contract DeliverReentrancyTest is Test {
    Deliver internal deliver;

    function setUp() public {
        deliver = new Deliver();
    }

    /*//////////////////////////////////////////////////////////////
              ERC-777-STYLE HOOK, FIRING AFTER THE UPDATE
    //////////////////////////////////////////////////////////////*/

    /// @dev The ordinary hook ordering: by the time the recipient is notified, the balance is
    ///      already gone. The re-entrant call sees zero and no-ops. Nothing is delivered twice.
    function test_TokenHookReentrancyFindsZeroBalance() public {
        RecipientHookERC20 token = new RecipientHookERC20();
        ReentrantTokenRecipient attacker = new ReentrantTokenRecipient(deliver, IERC20(address(token)), 0);
        token.mint(address(deliver), 100e18);

        deliver.deliverToken(IERC20(address(token)), address(attacker), 100e18);

        assertTrue(attacker.reentered(), "the hook must actually have re-entered");
        assertEq(attacker.observedDeliverBalance(), 0, "the re-entrant call must see a zero balance");
        assertFalse(attacker.reentrantCallReverted(), "min == 0 re-entry is a successful no-op");

        assertEq(token.balanceOf(address(attacker)), 100e18, "exactly one delivery, not two");
        assertEq(token.balanceOf(address(deliver)), 0);
        assertEq(token.totalSupply(), 100e18, "no tokens conjured by the re-entry");
    }

    /// @dev Same re-entry, but the re-entrant call demands a positive `min`. It reverts on the
    ///      floor check, is caught by the attacker, and the outer delivery still completes normally.
    function test_TokenHookReentrancyWithPositiveMinReverts() public {
        RecipientHookERC20 token = new RecipientHookERC20();
        ReentrantTokenRecipient attacker = new ReentrantTokenRecipient(deliver, IERC20(address(token)), 1);
        token.mint(address(deliver), 100e18);

        deliver.deliverToken(IERC20(address(token)), address(attacker), 100e18);

        assertTrue(attacker.reentrantCallReverted(), "re-entry with min > 0 must revert");
        assertEq(
            attacker.reentrantRevertData(),
            abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 0, 1),
            "re-entry must fail the floor check against a zero balance"
        );

        assertEq(token.balanceOf(address(attacker)), 100e18, "the outer delivery still completes");
        assertEq(token.balanceOf(address(deliver)), 0);
    }

    /*//////////////////////////////////////////////////////////////
              ERC-777-STYLE HOOK, FIRING BEFORE THE UPDATE
    //////////////////////////////////////////////////////////////*/

    /// @dev The hostile ordering: the recipient is notified *before* balances move, so the
    ///      re-entrant call still sees the full balance and drains it. The outer transfer then has
    ///      nothing left to move and reverts — the whole transaction unwinds atomically and no funds
    ///      are lost. Harmless, but only because the token's own accounting is checked.
    function test_PreUpdateHookTokenCannotDoubleDeliver() public {
        PreUpdateHookERC20 token = new PreUpdateHookERC20();
        ReentrantTokenRecipient attacker = new ReentrantTokenRecipient(deliver, IERC20(address(token)), 0);
        token.mint(address(deliver), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(deliver), 0, 100e18
            )
        );
        deliver.deliverToken(IERC20(address(token)), address(attacker), 100e18);

        assertEq(token.balanceOf(address(deliver)), 100e18, "the whole transaction unwound");
        assertEq(token.balanceOf(address(attacker)), 0, "nothing was delivered twice, or at all");
        assertEq(token.totalSupply(), 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                       NATIVE RECIPIENT RE-ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @dev ETH is sent before the recipient's code runs, so a re-entrant recipient also finds a
    ///      zero balance. The re-entrant call is a 0-value no-op; the recipient is paid exactly once.
    function test_NativeReentrancyFindsZeroBalance() public {
        ReentrantNativeRecipient attacker = new ReentrantNativeRecipient(deliver, 0);
        vm.deal(address(deliver), 5 ether);

        deliver.deliverNative(address(attacker), 5 ether);

        assertTrue(attacker.reentered(), "the recipient must actually have re-entered");
        assertEq(attacker.observedDeliverBalance(), 0, "the re-entrant call must see a zero balance");
        assertFalse(attacker.reentrantCallReverted(), "min == 0 re-entry is a successful no-op");

        assertEq(attacker.totalReceived(), 5 ether, "paid exactly once");
        assertEq(attacker.receiveCount(), 2, "the second entry is the 0-value no-op");
        assertEq(address(attacker).balance, 5 ether);
        assertEq(address(deliver).balance, 0, "no ETH left behind and none conjured");
    }

    /// @dev Re-entering with a positive `min` hits the floor check against a zero balance. The
    ///      attacker catches it; the outer delivery is unaffected.
    function test_NativeReentrancyWithPositiveMinReverts() public {
        ReentrantNativeRecipient attacker = new ReentrantNativeRecipient(deliver, 1);
        vm.deal(address(deliver), 5 ether);

        deliver.deliverNative(address(attacker), 5 ether);

        assertTrue(attacker.reentrantCallReverted(), "re-entry with min > 0 must revert");
        assertEq(
            attacker.reentrantRevertData(),
            abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 0, 1),
            "re-entry must fail the floor check against a zero balance"
        );

        assertEq(attacker.totalReceived(), 5 ether, "paid exactly once");
        assertEq(attacker.receiveCount(), 1, "the reverted re-entry never paid again");
        assertEq(address(deliver).balance, 0);
    }

    /// @dev The sentinel route reaches the same native code, so re-entry through `deliverToken`
    ///      behaves identically.
    function test_NativeReentrancyViaSentinelFindsZeroBalance() public {
        ReentrantNativeRecipient attacker = new ReentrantNativeRecipient(deliver, 0);
        vm.deal(address(deliver), 5 ether);

        deliver.deliverToken(IERC20(address(0)), address(attacker), 5 ether);

        assertEq(attacker.observedDeliverBalance(), 0);
        assertEq(attacker.totalReceived(), 5 ether);
        assertEq(address(deliver).balance, 0);
    }
}
