// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deliver} from "../src/Deliver.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice `deliverToken` treats two token addresses as "native ETH": `address(0)` and the
///         conventional `0xEeee...EEeE`. Both must route to the native path, and the `address(0)`
///         hazard documented in the contract NatSpec is pinned here as a tested fact rather than a
///         claim.
contract DeliverSentinelsTest is Test {
    Deliver internal deliver;
    MockERC20 internal token;

    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        deliver = new Deliver();
        token = new MockERC20();
    }

    function test_NativeSentinelConstant() public view {
        assertEq(deliver.NATIVE_SENTINEL(), 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }

    /*//////////////////////////////////////////////////////////////
                          BOTH SENTINELS ROUTE
    //////////////////////////////////////////////////////////////*/

    function test_ZeroAddressSentinelRoutesToNativePath() public {
        vm.deal(address(deliver), 6 ether);

        deliver.deliverToken(IERC20(address(0)), recipient, 6 ether);

        assertEq(recipient.balance, 6 ether, "address(0) must sweep ETH");
        assertEq(address(deliver).balance, 0);
    }

    function test_EeeeSentinelRoutesToNativePath() public {
        vm.deal(address(deliver), 6 ether);

        deliver.deliverToken(IERC20(deliver.NATIVE_SENTINEL()), recipient, 6 ether);

        assertEq(recipient.balance, 6 ether, "0xEeee... must sweep ETH");
        assertEq(address(deliver).balance, 0);
    }

    /// @dev Both sentinels are the same code path, so `min` is checked against the ETH balance and
    ///      not against any token balance.
    function test_RevertWhen_ZeroAddressSentinelBalanceBelowMin() public {
        vm.deal(address(deliver), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 1 ether, 2 ether));
        deliver.deliverToken(IERC20(address(0)), recipient, 2 ether);

        assertEq(address(deliver).balance, 1 ether);
    }

    function test_RevertWhen_EeeeSentinelBalanceBelowMin() public {
        IERC20 sentinel = IERC20(deliver.NATIVE_SENTINEL());
        vm.deal(address(deliver), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 1 ether, 2 ether));
        deliver.deliverToken(sentinel, recipient, 2 ether);

        assertEq(address(deliver).balance, 1 ether);
    }

    /// @dev The sentinel path never touches ERC-20 state; the held token balance is untouched.
    function test_SentinelPathLeavesErc20BalancesUntouched() public {
        token.mint(address(deliver), 100e18);
        vm.deal(address(deliver), 1 ether);

        deliver.deliverToken(IERC20(address(0)), recipient, 1 ether);

        assertEq(recipient.balance, 1 ether);
        assertEq(token.balanceOf(address(deliver)), 100e18, "ERC-20 balance must be untouched");
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_UnrelatedCallerCanUseSentinelPath() public {
        vm.deal(address(deliver), 2 ether);

        vm.prank(stranger);
        deliver.deliverToken(IERC20(address(0)), recipient, 2 ether);

        assertEq(recipient.balance, 2 ether);
    }

    function test_SentinelZeroBalanceWithZeroMinSucceedsAsNoOp() public {
        deliver.deliverToken(IERC20(address(0)), recipient, 0);
        deliver.deliverToken(IERC20(deliver.NATIVE_SENTINEL()), recipient, 0);

        assertEq(recipient.balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                     THE DOCUMENTED address(0) HAZARD
    //////////////////////////////////////////////////////////////*/

    /// @dev This is the accepted downside of treating `address(0)` as a native sentinel, pinned so
    ///      it cannot regress silently into something anyone believes is safe.
    ///
    ///      A caller with an uninitialized `token` field passes the zero address. On a contract that
    ///      rejected `address(0)` this would revert harmlessly. Here it does not revert: it sweeps
    ///      the entire ETH balance to whatever `recipient` that buggy caller supplied.
    function test_Hazard_UninitializedTokenSweepsEthInsteadOfReverting() public {
        IERC20 uninitializedTokenField; // never assigned — this is the caller's bug
        assertEq(address(uninitializedTokenField), address(0));

        vm.deal(address(deliver), 12 ether);
        address whateverTheCallerPassed = makeAddr("whateverTheCallerPassed");

        // No revert. The ETH leaves.
        vm.prank(stranger);
        deliver.deliverToken(uninitializedTokenField, whateverTheCallerPassed, 0);

        assertEq(whateverTheCallerPassed.balance, 12 ether, "the uninitialized-token bug moves ETH");
        assertEq(address(deliver).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SentinelBoundaryBalanceVersusMin(
        bool useZeroSentinel,
        uint256 balance,
        uint256 min
    ) public {
        IERC20 sentinel = useZeroSentinel ? IERC20(address(0)) : IERC20(deliver.NATIVE_SENTINEL());
        balance = bound(balance, 0, type(uint128).max);
        min = bound(min, 0, type(uint128).max);
        vm.deal(address(deliver), balance);

        if (balance < min) {
            vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, balance, min));
            deliver.deliverToken(sentinel, recipient, min);

            assertEq(address(deliver).balance, balance);
        } else {
            deliver.deliverToken(sentinel, recipient, min);

            assertEq(recipient.balance, balance);
            assertEq(address(deliver).balance, 0);
        }
    }
}
