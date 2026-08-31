// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Deliver} from "../src/Deliver.sol";
import {ICreateX} from "./ICreateX.sol";

/**
 * @title Deploy
 * @notice Deploys the {Deliver} singleton via CreateX CREATE2 — same address on every chain,
 *         reproducible by **anyone**.
 *
 * @dev ## Why permissionless
 *
 *      `Deliver` is a stateless public utility: no constructor arguments, no owner, nothing to
 *      configure, and no privileged relationship to whoever put it on chain. There is no reason for
 *      eco to be the only party able to deploy it to a new chain, and a good reason not to be —
 *      integrators hardcode this address, so extending the fleet to chain N+1 should not depend on
 *      one key still existing.
 *
 *      With CREATE2 through CreateX and an unguarded salt, `address = f(CreateX, salt, initCode)`.
 *      There is no deployer term. Anyone can put `Deliver` on a new chain at the identical address
 *      without coordinating with eco.
 *
 *      This matches `eco-swap-gateway`, which deploys the same way for the same reason, and is a
 *      deliberate departure from `eco-routes`, whose CREATE3 deployer derives the address from
 *      `(deployer, salt)` and can therefore only be extended by the original deployer.
 *
 * @dev ## The salt must be in CreateX's *unguarded* form
 *
 *      CreateX inspects the first 21 bytes of the salt and picks one of four behaviours. Two would
 *      silently destroy the property above:
 *
 *      - `salt[0..19] == msg.sender` — guards to that sender; nobody else reproduces the address.
 *      - `salt[20] == 0x01`          — mixes in `block.chainid`; the address differs per chain.
 *
 *      Anything else falls through to `guardedSalt = keccak256(abi.encode(salt))`, which is what we
 *      want. {_requirePermissionlessSalt} demands the canonical unguarded form — first 20 bytes
 *      zero, byte 20 zero — so a salt that would quietly produce a per-deployer or per-chain address
 *      is rejected before anything is broadcast. Getting this wrong does not fail loudly on its own;
 *      it produces a *different but perfectly valid* address, and the fleet stops sharing one.
 *
 * @dev ## No version discriminator, on purpose
 *
 *      An earlier revision used eco's CREATE3 deployer and folded a `DELIVER_VERSION` string into
 *      the salt, because CREATE3 ignores bytecode: without a manual bump, changed code would land on
 *      the old address. CREATE2 does not have that problem — the address derives from the init code
 *      hash, so any change to {Deliver} moves the address by itself. The mechanism now enforces what
 *      a comment used to have to.
 *
 * @dev ## Reproducibility
 *
 *      Because the address depends on the init code, anyone reproducing it must compile identically.
 *      `foundry.toml` pins `solc = "0.8.28"`, `optimizer = true`, `optimizer_runs = 1_000_000`,
 *      `evm_version = "paris"` and `bytecode_hash = "none"` (so no metadata hash varies the
 *      bytecode). Changing any of those changes the address.
 *
 * @dev Usage:
 *      SALT=0x... forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast --slow --verify
 *
 *      Predicting needs no private key at all, which is rather the point:
 *      SALT=0x... forge script script/Deploy.s.sol --sig "predictAddress()" --rpc-url <RPC_URL>
 */
contract Deploy is Script {
    /// @dev CreateX, at the same address on every chain it is deployed to.
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run() external {
        bytes32 salt = vm.envBytes32("SALT");
        _requirePermissionlessSalt(salt);
        require(address(CREATEX).code.length > 0, "CreateX is not deployed on this chain");

        bytes memory initCode = type(Deliver).creationCode;
        address predicted = _predict(salt, initCode);

        console.log("Chain ID       :", block.chainid);
        console.log("Predicted addr :", predicted);

        if (predicted.code.length > 0) {
            console.log("Already deployed, nothing to do.");
            _verify(predicted);
            return;
        }

        vm.startBroadcast();
        address deployed = CREATEX.deployCreate2(salt, initCode);
        vm.stopBroadcast();

        require(deployed == predicted, "deployed address does not match prediction");
        _verify(deployed);

        console.log("Deployed at    :", deployed);
    }

    /// @notice Print the address this salt resolves to on this chain.
    /// @dev Requires no private key — the address does not depend on who deploys it. That is the
    ///      point of the unguarded salt, and it means anyone can verify the address independently
    ///      before trusting it.
    function predictAddress() external view {
        bytes32 salt = vm.envBytes32("SALT");
        _requirePermissionlessSalt(salt);

        address predicted = _predict(salt, type(Deliver).creationCode);
        console.log("Chain ID       :", block.chainid);
        console.log("Predicted addr :", predicted);
        console.log("CreateX present:", address(CREATEX).code.length > 0);
        console.log("Deployed       :", predicted.code.length > 0);
    }

    /**
     * @dev CreateX hashes the salt internally before the CREATE2, but `computeCreate2Address` does
     *      **not** apply that transform — it takes an already-guarded salt. So the guard has to be
     *      reproduced here, or the prediction silently disagrees with the deploy. For an unguarded
     *      salt the transform is `keccak256(abi.encode(salt))`, which is exactly why
     *      {_requirePermissionlessSalt} runs first: it is what makes this the correct branch.
     */
    function _predict(
        bytes32 salt,
        bytes memory initCode
    ) internal view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encode(salt));
        return CREATEX.computeCreate2Address(guardedSalt, keccak256(initCode));
    }

    /// @dev Reject any salt CreateX would treat as guarded. See the contract-level note.
    function _requirePermissionlessSalt(
        bytes32 salt
    ) internal pure {
        require(bytes20(salt) == bytes20(0), "salt: first 20 bytes must be zero (else guarded to a sender)");
        require(salt[20] == 0x00, "salt: byte 20 must be 0x00 (0x01 mixes in chainid)");
    }

    /**
     * @dev Confirm the code at `target` is {Deliver}.
     *
     *      Belt-and-braces under CREATE2, unlike under CREATE3. CREATE2 derives the address from the
     *      init code hash, so different code cannot occupy this address and this check cannot fail in
     *      normal operation. It costs one staticcall and is kept so that a change in CreateX's
     *      behaviour, or a mistake in the guarded-salt derivation above, surfaces here rather than at
     *      the first delivery.
     */
    function _verify(
        address target
    ) internal view {
        require(
            keccak256(target.code) == keccak256(type(Deliver).runtimeCode), "code at address is not Deliver"
        );
    }
}
