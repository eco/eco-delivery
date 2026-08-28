// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {Deliver} from "../src/Deliver.sol";

/// @dev Exposes the deploy script's internals. The script is otherwise unreachable from tests —
///      `forge build` type-checks `script/` but `forge test` never executes it.
contract DeployHarness is Deploy {
    function contractSalt(
        bytes32 root,
        string memory name
    ) external pure returns (bytes32) {
        return _contractSalt(root, name);
    }

    function verify(
        address target
    ) external view {
        _verify(target);
    }

    function version() external pure returns (string memory) {
        return DELIVER_VERSION;
    }
}

/// @dev Exposes `NATIVE_SENTINEL` with the correct value and nothing else.
///
///      This is the contract the old sentinel-only check could not tell apart from {Deliver}: it
///      answers the one question that check asked, and cannot deliver anything. It stands in for the
///      real hazard — a modified {Deliver} whose constant survived a change to `deliverToken`.
contract LookalikeDeliver {
    address public constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
}

contract DeployTest is Test {
    DeployHarness harness;

    /// @dev keccak256(abi.encode(bytes32(uint256(0x42)), keccak256("ECO_DELIVERY_V1"))), computed
    ///      independently with `cast keccak` rather than by running the code under test.
    bytes32 constant GOLDEN_ROOT = bytes32(uint256(0x42));
    bytes32 constant GOLDEN_SALT = 0x872f21a9b50459f0531f5b941c42c3a1fdb2dad7de848d738a94b445c88e9159;

    function setUp() public {
        harness = new DeployHarness();
    }

    /// @dev The deployed address is this repo's one true one-way door: it is derived from
    ///      `(deployer, salt)` and integrators are meant to hardcode it. Pinning the derivation
    ///      means a refactor of `_contractSalt` cannot silently move every future deployment.
    function test_SaltDerivationIsPinned() public view {
        assertEq(harness.contractSalt(GOLDEN_ROOT, "ECO_DELIVERY_V1"), GOLDEN_SALT);
    }

    /// @dev The version string is part of the address. Renaming it moves every future deployment,
    ///      so it should never change by accident — only as the deliberate bump the NatSpec asks for.
    function test_VersionStringIsPinned() public view {
        assertEq(harness.version(), "ECO_DELIVERY_V1");
    }

    /// @dev A version bump must actually change the address, or the discriminator is decorative.
    function test_SaltChangesWithVersion() public view {
        assertTrue(
            harness.contractSalt(GOLDEN_ROOT, "ECO_DELIVERY_V1")
                != harness.contractSalt(GOLDEN_ROOT, "ECO_DELIVERY_V2")
        );
    }

    function test_SaltChangesWithRoot() public view {
        assertTrue(
            harness.contractSalt(GOLDEN_ROOT, "ECO_DELIVERY_V1")
                != harness.contractSalt(bytes32(uint256(0x43)), "ECO_DELIVERY_V1")
        );
    }

    function test_VerifyAcceptsRealDeliver() public {
        harness.verify(address(new Deliver()));
    }

    /// @dev The regression test for the check itself.
    ///
    ///      Reading `NATIVE_SENTINEL()` and stopping there would pass here, because the lookalike
    ///      answers exactly that question correctly. Since CREATE3 derives the address from
    ///      `(deployer, salt)` alone and ignores bytecode, "wrong code at the right address" is the
    ///      failure the post-deploy check exists to catch — so it has to compare the code.
    function test_RevertWhen_VerifyGivenLookalikeExposingTheSentinel() public {
        LookalikeDeliver lookalike = new LookalikeDeliver();
        assertEq(lookalike.NATIVE_SENTINEL(), Deliver(payable(address(new Deliver()))).NATIVE_SENTINEL());

        vm.expectRevert(bytes("code at address is not Deliver"));
        harness.verify(address(lookalike));
    }

    function test_RevertWhen_VerifyGivenAddressWithNoCode() public {
        vm.expectRevert();
        harness.verify(address(0xdead));
    }
}
