// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deliver} from "../src/Deliver.sol";
import {PassiveNativeRecipient, RejectingNativeRecipient} from "./mocks/MockReceivers.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Native ETH path: the same sweep semantics and `min` boundaries as the ERC-20 path, plus
///         fail-closed behaviour when the recipient refuses the funds.
contract DeliverNativeTest is Test {
    Deliver internal deliver;

    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        deliver = new Deliver();
    }

    /*//////////////////////////////////////////////////////////////
                          SWEEP, NOT AMOUNT
    //////////////////////////////////////////////////////////////*/

    function test_DeliversFullNativeBalanceNotPartialAmount() public {
        vm.deal(address(deliver), 10 ether);

        deliver.deliverNative(recipient, 1 wei);

        assertEq(recipient.balance, 10 ether, "recipient must receive the whole ETH balance");
        assertEq(address(deliver).balance, 0, "deliver must retain no ETH");
    }

    function test_PreExistingNativeDustIsIncludedInSweep() public {
        vm.deal(address(deliver), 3 wei); // stranded from some earlier flow
        vm.deal(address(deliver), address(deliver).balance + 2 ether); // this delivery's funds

        deliver.deliverNative(recipient, 2 ether);

        assertEq(recipient.balance, 2 ether + 3 wei, "dust must be swept along with the delivery");
        assertEq(address(deliver).balance, 0);
    }

    function test_HoldsNoNativeFundsBetweenCalls() public {
        vm.deal(address(deliver), 1 ether);
        deliver.deliverNative(recipient, 1 ether);
        assertEq(address(deliver).balance, 0);

        deliver.deliverNative(recipient, 0);

        assertEq(recipient.balance, 1 ether, "second call must not move anything new");
    }

    /// @dev `receive()` exists so the contract can actually be funded by a plain send, not only by
    ///      the `vm.deal` shortcut the other tests use.
    function test_ReceiveAcceptsPlainEthSend() public {
        vm.deal(stranger, 5 ether);

        vm.prank(stranger);
        (bool ok,) = address(deliver).call{value: 5 ether}("");

        assertTrue(ok, "funding send must succeed");
        assertEq(address(deliver).balance, 5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            THE MIN FLOOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NativeBalanceBelowMin() public {
        vm.deal(address(deliver), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 1 ether, 5 ether));
        deliver.deliverNative(recipient, 5 ether);

        assertEq(address(deliver).balance, 1 ether, "a failed check must move nothing");
        assertEq(recipient.balance, 0);
    }

    function test_RevertWhen_NativeBalanceIsOneBelowMin() public {
        uint256 min = 5 ether;
        vm.deal(address(deliver), min - 1);

        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, min - 1, min));
        deliver.deliverNative(recipient, min);
    }

    function test_SucceedsWhenNativeBalanceExactlyEqualsMin() public {
        uint256 min = 5 ether;
        vm.deal(address(deliver), min);

        deliver.deliverNative(recipient, min);

        assertEq(recipient.balance, min);
        assertEq(address(deliver).balance, 0);
    }

    /// @dev Same decision as the ERC-20 path: an empty native delivery with `min == 0` is a
    ///      successful no-op, a 0-value call.
    function test_ZeroNativeBalanceWithZeroMinSucceedsAsNoOp() public {
        assertEq(address(deliver).balance, 0);

        deliver.deliverNative(recipient, 0);

        assertEq(recipient.balance, 0, "a no-op must move nothing");
        assertEq(address(deliver).balance, 0);
    }

    function test_RevertWhen_ZeroNativeBalanceAndPositiveMin() public {
        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 0, 1));
        deliver.deliverNative(recipient, 1);
    }

    /*//////////////////////////////////////////////////////////////
                             FAIL CLOSED
    //////////////////////////////////////////////////////////////*/

    /// @dev A recipient that reverts on receive takes the whole delivery down with it. The contract
    ///      never swallows a failed send, so a "delivered" outcome is never reported for ETH that
    ///      did not move.
    function test_RevertWhen_NativeRecipientRejectsEth() public {
        RejectingNativeRecipient rejecting = new RejectingNativeRecipient();
        vm.deal(address(deliver), 4 ether);

        vm.expectRevert(
            abi.encodeWithSelector(Deliver.NativeTransferFailed.selector, address(rejecting), 4 ether)
        );
        deliver.deliverNative(address(rejecting), 4 ether);

        assertEq(address(deliver).balance, 4 ether, "funds stay put when the send fails");
        assertEq(address(rejecting).balance, 0);
    }

    /// @dev Even the `min == 0` no-op path fails closed: the 0-value call still has to succeed.
    function test_RevertWhen_NativeRecipientRejectsZeroValueNoOp() public {
        RejectingNativeRecipient rejecting = new RejectingNativeRecipient();

        vm.expectRevert(abi.encodeWithSelector(Deliver.NativeTransferFailed.selector, address(rejecting), 0));
        deliver.deliverNative(address(rejecting), 0);
    }

    function test_DeliversToContractRecipientThatAcceptsEth() public {
        PassiveNativeRecipient passive = new PassiveNativeRecipient();
        vm.deal(address(deliver), 8 ether);

        deliver.deliverNative(address(passive), 8 ether);

        assertEq(address(passive).balance, 8 ether);
        assertEq(address(deliver).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            PERMISSIONLESS
    //////////////////////////////////////////////////////////////*/

    function test_UnrelatedCallerCanDeliverNative() public {
        vm.deal(address(deliver), 3 ether);

        vm.prank(stranger);
        deliver.deliverNative(recipient, 3 ether);

        assertEq(recipient.balance, 3 ether);
        assertEq(stranger.balance, 0, "the caller gets nothing for calling");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_NativeBoundaryBalanceVersusMin(
        uint256 balance,
        uint256 min
    ) public {
        balance = bound(balance, 0, type(uint128).max);
        min = bound(min, 0, type(uint128).max);
        vm.deal(address(deliver), balance);

        if (balance < min) {
            vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, balance, min));
            deliver.deliverNative(recipient, min);

            assertEq(address(deliver).balance, balance, "reverted delivery must move nothing");
            assertEq(recipient.balance, 0);
        } else {
            deliver.deliverNative(recipient, min);

            assertEq(recipient.balance, balance, "success must deliver the full balance");
            assertEq(address(deliver).balance, 0);
        }
    }

    /// Naming the contract itself as recipient is a no-op that succeeds: the balance is sent to
    /// the address that already holds it. Nothing is lost and nothing is delivered.
    ///
    /// Pinned because it was raised as a finding (Octane df9b0426) against the SVM twin, where
    /// `deliver_sol` behaves the same way. Constraining it on one side only would be the real
    /// defect — it would break parity. Note that a caller free to choose any recipient would name
    /// *themselves* and take the funds, so this is strictly the weaker of the two things such a
    /// caller can do; see `test_AnyoneCanDivertAStrandedBalance`.
    function test_SelfDeliveryIsANoOpOnBothPaths() public {
        vm.deal(address(deliver), 3 ether);
        deliver.deliverNative(address(deliver), 3 ether);
        assertEq(address(deliver).balance, 3 ether, "native: nothing moved, call succeeded");

        MockERC20 token = new MockERC20();
        token.mint(address(deliver), 1000e18);
        deliver.deliverToken(IERC20(address(token)), address(deliver), 1000e18);
        assertEq(token.balanceOf(address(deliver)), 1000e18, "token: nothing moved, call succeeded");
    }
}
