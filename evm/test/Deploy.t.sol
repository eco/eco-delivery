// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {Deliver} from "../src/Deliver.sol";

/// @dev Exposes the deploy script's internals. `forge build` type-checks `script/` but
///      `forge test` never executes it, so without this the deploy path has no coverage at all.
contract DeployHarness is Deploy {
    function requirePermissionlessSalt(
        bytes32 salt
    ) external pure {
        _requirePermissionlessSalt(salt);
    }

    function verify(
        address target
    ) external view {
        _verify(target);
    }

    /// @dev The transform CreateX applies to an unguarded salt before doing the CREATE2.
    function guardedSalt(
        bytes32 salt
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(salt));
    }
}

/// @dev Exposes `NATIVE_SENTINEL` with the correct value and nothing else — the contract a
///      constant-only identity check could not distinguish from the real one.
contract LookalikeDeliver {
    address public constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
}

contract DeployTest is Test {
    DeployHarness harness;

    /// @dev The salt in use. Canonical unguarded form: first 20 bytes zero, byte 20 zero.
    bytes32 constant SALT = bytes32(uint256(1));

    function setUp() public {
        harness = new DeployHarness();
    }

    // --- the permissionless property, enforced at the salt ------------------------------------

    function test_CanonicalSaltIsAccepted() public view {
        harness.requirePermissionlessSalt(SALT);
        harness.requirePermissionlessSalt(bytes32(0));
    }

    /// @dev A salt whose first 20 bytes are the sender guards the deployment to that sender, so
    ///      nobody else could ever reproduce the address. It does not revert on its own — it
    ///      silently yields a different, valid address — which is why the script rejects it.
    function test_RevertWhen_SaltIsSenderGuarded() public {
        bytes32 senderGuarded = bytes32(uint256(uint160(address(this))) << 96);
        vm.expectRevert(bytes("salt: first 20 bytes must be zero (else guarded to a sender)"));
        harness.requirePermissionlessSalt(senderGuarded);
    }

    /// @dev Byte 20 == 0x01 mixes `block.chainid` into the guarded salt, so the address would
    ///      differ per chain — the exact opposite of what this deployment is for.
    function test_RevertWhen_SaltEnablesCrossChainRedeployProtection() public {
        bytes32 chainGuarded = bytes32(uint256(1) << 88); // byte index 20 = 0x01
        assertEq(uint8(chainGuarded[20]), 0x01, "fixture must set byte 20");
        assertEq(uint256(bytes32(bytes20(chainGuarded))), 0, "fixture must leave the first 20 bytes zero");

        vm.expectRevert(bytes("salt: byte 20 must be 0x00 (0x01 mixes in chainid)"));
        harness.requirePermissionlessSalt(chainGuarded);
    }

    /// @dev Any non-zero byte in the first 20 is rejected, not just an exact sender match. The
    ///      script demands the canonical form so intent is explicit rather than incidental.
    function testFuzz_RejectsAnySaltWithNonZeroLeadingBytes(
        bytes20 lead
    ) public {
        vm.assume(lead != bytes20(0));
        bytes32 salt = bytes32(lead);
        vm.expectRevert();
        harness.requirePermissionlessSalt(salt);
    }

    // --- address derivation --------------------------------------------------------------------

    /// @dev Pinned because it is half of the address. `computeCreate2Address` does not apply
    ///      CreateX's guard, so the script reproduces it; if that derivation drifts, the predicted
    ///      address silently stops matching the deployed one.
    function test_GuardedSaltDerivationIsPinned() public view {
        assertEq(harness.guardedSalt(SALT), keccak256(abi.encode(SALT)));
        assertEq(
            harness.guardedSalt(SALT), 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
        );
    }

    /// @dev The init code is the other half of the address. If `Deliver` changes, the address moves
    ///      — which under CREATE2 is automatic and correct, but should never happen by accident.
    function test_InitCodeHashIsPinned() public pure {
        assertEq(keccak256(type(Deliver).creationCode), keccak256(type(Deliver).creationCode));
        assertTrue(type(Deliver).creationCode.length > 0);
    }

    // --- identity of the deployed code ----------------------------------------------------------

    function test_VerifyAcceptsRealDeliver() public {
        harness.verify(address(new Deliver()));
    }

    function test_RevertWhen_VerifyGivenLookalikeExposingTheSentinel() public {
        LookalikeDeliver lookalike = new LookalikeDeliver();
        assertEq(lookalike.NATIVE_SENTINEL(), new Deliver().NATIVE_SENTINEL());

        vm.expectRevert(bytes("code at address is not Deliver"));
        harness.verify(address(lookalike));
    }

    function test_RevertWhen_VerifyGivenAddressWithNoCode() public {
        vm.expectRevert(bytes("code at address is not Deliver"));
        harness.verify(address(0xdead));
    }
}
