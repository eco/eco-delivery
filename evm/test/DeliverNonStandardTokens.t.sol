// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deliver} from "../src/Deliver.sol";
import {FalseReturningERC20, FeeOnTransferERC20, NoReturnERC20} from "./mocks/MockTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Tokens that do not follow the ERC-20 return convention, and the fee-on-transfer class the
///         contract explicitly documents as under-deliverable.
contract DeliverNonStandardTokensTest is Test {
    Deliver internal deliver;

    address internal recipient = makeAddr("recipient");
    address internal feeSink = makeAddr("feeSink");

    function setUp() public {
        deliver = new Deliver();
    }

    /*//////////////////////////////////////////////////////////////
                  USDT-STYLE: transfer RETURNS NOTHING
    //////////////////////////////////////////////////////////////*/

    function test_NoReturnTokenIsDeliveredInFull() public {
        NoReturnERC20 usdtStyle = new NoReturnERC20();
        usdtStyle.mint(address(deliver), 1000e6);

        deliver.deliverToken(IERC20(address(usdtStyle)), recipient, 1000e6);

        assertEq(usdtStyle.balanceOf(recipient), 1000e6, "SafeERC20 must accept an empty return");
        assertEq(usdtStyle.balanceOf(address(deliver)), 0);
    }

    function test_NoReturnTokenHonoursTheMinFloor() public {
        NoReturnERC20 usdtStyle = new NoReturnERC20();
        usdtStyle.mint(address(deliver), 999e6);

        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 999e6, 1000e6));
        deliver.deliverToken(IERC20(address(usdtStyle)), recipient, 1000e6);

        assertEq(usdtStyle.balanceOf(address(deliver)), 999e6);
    }

    function test_NoReturnTokenSucceedsAtExactlyMin() public {
        NoReturnERC20 usdtStyle = new NoReturnERC20();
        usdtStyle.mint(address(deliver), 1000e6);

        deliver.deliverToken(IERC20(address(usdtStyle)), recipient, 1000e6);

        assertEq(usdtStyle.balanceOf(recipient), 1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                 MISBEHAVING: transfer RETURNS false
    //////////////////////////////////////////////////////////////*/

    /// @dev A token that reports failure by returning `false` must abort the delivery, not be
    ///      treated as a silent success.
    function test_RevertWhen_TokenTransferReturnsFalse() public {
        FalseReturningERC20 liar = new FalseReturningERC20();
        liar.mint(address(deliver), 500e18);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(liar)));
        deliver.deliverToken(IERC20(address(liar)), recipient, 500e18);

        assertEq(liar.balanceOf(address(deliver)), 500e18, "nothing moves on a failed transfer");
        assertEq(liar.balanceOf(recipient), 0);
    }

    /*//////////////////////////////////////////////////////////////
              THE DOCUMENTED FEE-ON-TRANSFER UNDER-DELIVERY
    //////////////////////////////////////////////////////////////*/

    /// @dev The accepted consequence of checking `min` against the *held* balance pre-transfer.
    ///      This test exists so the documented hole is a pinned, tested fact: the call SUCCEEDS
    ///      while the recipient ends up with strictly less than `min`.
    function test_Hole_FeeOnTransferTokenCanDeliverLessThanMin() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20(100, feeSink); // 1%
        uint256 min = 100e18;
        fee.mint(address(deliver), min); // balance == min exactly, so the floor is satisfied

        deliver.deliverToken(IERC20(address(fee)), recipient, min); // no revert

        assertEq(fee.balanceOf(recipient), 99e18, "recipient receives the post-fee amount");
        assertLt(fee.balanceOf(recipient), min, "recipient got strictly less than min, as documented");
        assertEq(fee.balanceOf(feeSink), 1e18, "the fee went to the token's fee sink");
        assertEq(fee.balanceOf(address(deliver)), 0, "the sweep still emptied the contract");
    }

    /// @dev The sweep itself is still total for a fee-taking token: the contract keeps nothing, the
    ///      shortfall is taken by the token, not retained here.
    function test_FeeOnTransferTokenIsStillFullySwept() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20(2500, feeSink); // 25%
        fee.mint(address(deliver), 400e18);

        deliver.deliverToken(IERC20(address(fee)), recipient, 0);

        assertEq(fee.balanceOf(address(deliver)), 0);
        assertEq(fee.balanceOf(recipient), 300e18);
        assertEq(fee.balanceOf(feeSink), 100e18);
    }

    /// @dev The floor is still enforced against what is *held*, so a fee token below `min` reverts
    ///      exactly like a standard one.
    function test_FeeOnTransferTokenStillRevertsBelowMin() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20(100, feeSink);
        fee.mint(address(deliver), 10e18);

        vm.expectRevert(abi.encodeWithSelector(Deliver.BalanceBelowMin.selector, 10e18, 20e18));
        deliver.deliverToken(IERC20(address(fee)), recipient, 20e18);
    }
}
