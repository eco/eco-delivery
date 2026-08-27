// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deliver} from "../src/Deliver.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Core ERC-20 path: the sweep, the `min` floor and its boundaries, dust, permissionlessness
///         and statelessness.
contract DeliverTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);

    Deliver internal deliver;
    MockERC20 internal token;

    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        deliver = new Deliver();
        token = new MockERC20();
    }

    /*//////////////////////////////////////////////////////////////
                          SWEEP, NOT AMOUNT
    //////////////////////////////////////////////////////////////*/

    /// @dev The full held balance moves, not `min` and not any partial amount.
    function test_DeliversFullBalanceNotPartialAmount() public {
        token.mint(address(deliver), 1000e18);

        deliver.deliverToken(IERC20(address(token)), recipient, 1e18);

        assertEq(token.balanceOf(recipient), 1000e18, "recipient must receive the whole balance");
        assertEq(token.balanceOf(address(deliver)), 0, "deliver must retain nothing");
    }

    /// @dev Dust from an unrelated prior flow is part of "what arrived" and is swept too.
    function test_PreExistingDustIsIncludedInSweep() public {
        token.mint(address(deliver), 7); // stranded from some earlier flow
        token.mint(address(deliver), 500e18); // this delivery's funds

        deliver.deliverToken(IERC20(address(token)), recipient, 500e18);

        assertEq(token.balanceOf(recipient), 500e18 + 7, "dust must be swept along with the delivery");
        assertEq(token.balanceOf(address(deliver)), 0);
    }

    /// @dev The contract is a pass-through: after a sweep it holds nothing, and a second call finds
    ///      nothing to move.
    function test_HoldsNoFundsBetweenCalls() public {
        token.mint(address(deliver), 42e18);
        deliver.deliverToken(IERC20(address(token)), recipient, 42e18);
        assertEq(token.balanceOf(address(deliver)), 0);

        deliver.deliverToken(IERC20(address(token)), recipient, 0);

        assertEq(token.balanceOf(recipient), 42e18, "second call must not move anything new");
        assertEq(token.balanceOf(address(deliver)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            THE MIN FLOOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_BalanceBelowMin() public {
        token.mint(address(deliver), 10e18);

        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 10e18, 100e18));
        deliver.deliverToken(IERC20(address(token)), recipient, 100e18);

        assertEq(token.balanceOf(address(deliver)), 10e18, "a failed check must move nothing");
        assertEq(token.balanceOf(recipient), 0);
    }

    /// @dev The tight boundary below: `balance == min - 1` must revert.
    function test_RevertWhen_BalanceIsOneBelowMin() public {
        uint256 min = 100e18;
        token.mint(address(deliver), min - 1);

        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, min - 1, min));
        deliver.deliverToken(IERC20(address(token)), recipient, min);
    }

    /// @dev The tight boundary at equality: `balance == min` must succeed.
    function test_SucceedsWhenBalanceExactlyEqualsMin() public {
        uint256 min = 100e18;
        token.mint(address(deliver), min);

        deliver.deliverToken(IERC20(address(token)), recipient, min);

        assertEq(token.balanceOf(recipient), min);
        assertEq(token.balanceOf(address(deliver)), 0);
    }

    /// @dev Decision: an empty delivery with `min == 0` succeeds as a no-op transfer of 0, exactly
    ///      like the reference implementation. It is not rejected.
    function test_ZeroBalanceWithZeroMinSucceedsAsNoOp() public {
        assertEq(token.balanceOf(address(deliver)), 0);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(deliver), recipient, 0);
        deliver.deliverToken(IERC20(address(token)), recipient, 0);

        assertEq(token.balanceOf(recipient), 0, "a no-op must move nothing");
        assertEq(token.balanceOf(address(deliver)), 0);
    }

    function test_RevertWhen_ZeroBalanceAndPositiveMin() public {
        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 0, 1));
        deliver.deliverToken(IERC20(address(token)), recipient, 1);
    }

    /*//////////////////////////////////////////////////////////////
                    PERMISSIONLESS AND STATELESS
    //////////////////////////////////////////////////////////////*/

    /// @dev Permissionless is a feature, so assert it rather than assume it: an address with no
    ///      relationship to the deployment or the funds can trigger the delivery.
    function test_UnrelatedCallerCanDeliver() public {
        token.mint(address(deliver), 250e18);

        vm.prank(stranger);
        deliver.deliverToken(IERC20(address(token)), recipient, 250e18);

        assertEq(token.balanceOf(recipient), 250e18);
        assertEq(token.balanceOf(stranger), 0, "the caller gets nothing for calling");
    }

    /// @dev The flip side of permissionless: whoever calls chooses the recipient, so a balance
    ///      sitting here is claimable by anyone for anyone. Pinned so the hazard is a tested fact.
    function test_AnyoneCanDivertAStrandedBalance() public {
        token.mint(address(deliver), 1e18);
        address attackerChosen = makeAddr("attackerChosen");

        vm.prank(stranger);
        deliver.deliverToken(IERC20(address(token)), attackerChosen, 0);

        assertEq(token.balanceOf(attackerChosen), 1e18, "stranded funds are claimable by anyone");
    }

    /// @dev No owner, no storage: nothing is written, so there is nothing to corrupt or capture.
    function test_ContractWritesNoStorage() public {
        token.mint(address(deliver), 5e18);
        deliver.deliverToken(IERC20(address(token)), recipient, 5e18);

        for (uint256 slot = 0; slot < 8; slot++) {
            assertEq(vm.load(address(deliver), bytes32(slot)), bytes32(0), "deliver must be stateless");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev The revert/success boundary over the whole `(balance, min)` relationship.
    function testFuzz_BoundaryBalanceVersusMin(
        uint256 balance,
        uint256 min
    ) public {
        balance = bound(balance, 0, type(uint128).max);
        min = bound(min, 0, type(uint128).max);
        token.mint(address(deliver), balance);

        if (balance < min) {
            vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, balance, min));
            deliver.deliverToken(IERC20(address(token)), recipient, min);

            assertEq(token.balanceOf(address(deliver)), balance, "reverted delivery must move nothing");
            assertEq(token.balanceOf(recipient), 0);
        } else {
            deliver.deliverToken(IERC20(address(token)), recipient, min);

            assertEq(token.balanceOf(recipient), balance, "success must deliver the full balance");
            assertEq(token.balanceOf(address(deliver)), 0);
        }
    }

    /// @dev Any caller, any recipient: the sweep is total and the caller is irrelevant to the
    ///      outcome.
    function testFuzz_AnyCallerSweepsFullBalance(
        address caller,
        address to,
        uint256 balance
    ) public {
        vm.assume(caller != address(0));
        vm.assume(to != address(0) && to != address(deliver));
        assumeNotForgeAddress(caller);
        assumeNotForgeAddress(to);
        balance = bound(balance, 0, type(uint128).max);
        token.mint(address(deliver), balance);

        vm.prank(caller);
        deliver.deliverToken(IERC20(address(token)), to, balance);

        assertEq(token.balanceOf(to), balance);
        assertEq(token.balanceOf(address(deliver)), 0);
    }
}
