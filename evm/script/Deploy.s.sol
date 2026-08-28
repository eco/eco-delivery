// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Deliver} from "../src/Deliver.sol";
import {ICreate3Deployer} from "./ICreate3Deployer.sol";

/**
 * @title Deploy
 * @notice Deploys the {Deliver} singleton to one or more chains using CREATE3.
 *
 * @dev Follows the conventions in `eco-routes/scripts/DeployIntentChainer.s.sol`: the shared
 *      CREATE3 deployer, a version-discriminated salt, an idempotent run, and a `predictAddress()`
 *      entry point for checking an address without broadcasting.
 *
 * @dev Why CREATE3 matters more here than usual. `Deliver` takes no constructor arguments and holds
 *      no state, so the same bytecode is correct on every chain — and integrators are expected to
 *      hardcode this address as the destination their route pays into. One address everywhere means
 *      an SDK, a settlement contract, and a partner's config can all name a single constant instead
 *      of a per-chain table.
 *
 * @dev **Bump DELIVER_VERSION on any change to the contract's interface.** CREATE3 derives the
 *      address from `(deployer, salt)` and ignores bytecode entirely. Without a salt bump, a
 *      modified contract would land on top of the old address on a chain that has not been deployed
 *      yet, so the "same address" invariant would silently start meaning "same address, different
 *      code". That is also why {run} verifies the deployed code below rather than trusting that a
 *      matching address implies matching behaviour.
 *
 * @dev Usage:
 *      PRIVATE_KEY=0x... SALT=0x... forge script script/Deploy.s.sol \
 *        --rpc-url <RPC_URL> --broadcast --slow --verify
 *
 *      To check the address on a chain without deploying:
 *      PRIVATE_KEY=0x... SALT=0x... forge script script/Deploy.s.sol \
 *        --sig "predictAddress()" --rpc-url <RPC_URL>
 */
contract Deploy is Script {
    /// @dev The shared eco CREATE3 deployer. Same address across eco's repos and chains.
    ICreate3Deployer constant CREATE3_DEPLOYER = ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    /// @dev Salt discriminator. Bump on any interface change — see the CREATE3 note above.
    string constant DELIVER_VERSION = "ECO_DELIVERY_V1";

    /// @dev Mirrors `Deliver.NATIVE_SENTINEL`. A cheap first assertion only — {_verify} compares the
    ///      full runtime code, because this constant alone does not identify the contract.
    address constant EXPECTED_NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function run() external {
        bytes32 rootSalt = _rootSalt();
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));

        bytes32 salt = _contractSalt(rootSalt, DELIVER_VERSION);
        address predicted = CREATE3_DEPLOYER.deployedAddress(bytes(""), deployer, salt);

        console.log("Chain ID       :", block.chainid);
        console.log("Deployer       :", deployer);
        console.log("Predicted addr :", predicted);

        if (predicted.code.length > 0) {
            console.log("Already deployed, nothing to do.");
            _verify(predicted);
            return;
        }

        vm.startBroadcast(deployer);
        address deployed = CREATE3_DEPLOYER.deploy(type(Deliver).creationCode, salt);
        vm.stopBroadcast();

        require(deployed == predicted, "address mismatch");
        require(deployed.code.length > 0, "deployment produced no code");
        _verify(deployed);

        console.log("Deployed at    :", deployed);
    }

    /// @notice Print the address this deployer+salt resolves to on this chain, without broadcasting.
    function predictAddress() external view {
        bytes32 salt = _contractSalt(_rootSalt(), DELIVER_VERSION);
        address deployer = _deployer();
        address predicted = CREATE3_DEPLOYER.deployedAddress(bytes(""), deployer, salt);

        console.log("Chain ID       :", block.chainid);
        console.log("Deployer       :", deployer);
        console.log("Predicted addr :", predicted);
        console.log("Deployed       :", predicted.code.length > 0);
    }

    /**
     * @dev Confirm the code at `target` really is {Deliver}.
     *
     *      Worth doing precisely because CREATE3 ignores bytecode: a matching address proves only
     *      that the same deployer used the same salt, not that it deployed the same contract. This
     *      catches a salt collision with an older or different build before anyone points a route
     *      at the address.
     *
     *      The code hash is the assertion that actually earns the error message. Reading
     *      `NATIVE_SENTINEL()` alone would pass for *any* contract exposing that constant —
     *      including a modified {Deliver} whose constant survived but whose `deliverToken` did not,
     *      which is precisely the case this check exists to catch. It is kept as a friendly first
     *      failure for the common "wrong address entirely" mistake.
     *
     *      Comparing against `runtimeCode` is only sound because {Deliver} has no immutables and no
     *      constructor arguments, so its deployed code is a compile-time constant. Adding an
     *      immutable would make `type(Deliver).runtimeCode` illegal and this check would stop
     *      compiling — which is the right way to find out.
     */
    function _verify(
        address target
    ) internal view {
        require(
            Deliver(payable(target)).NATIVE_SENTINEL() == EXPECTED_NATIVE_SENTINEL,
            "code at address is not Deliver"
        );
        require(
            keccak256(target.code) == keccak256(type(Deliver).runtimeCode), "code at address is not Deliver"
        );
    }

    /// @dev The root salt, rejecting the zero value.
    ///      `SALT` fixes the address on every chain permanently, so an unset or empty env var is far
    ///      more likely to be a mistake than an intent — and it is not a mistake you can take back.
    function _rootSalt() internal view returns (bytes32) {
        bytes32 rootSalt = vm.envBytes32("SALT");
        require(rootSalt != bytes32(0), "SALT must be non-zero");
        return rootSalt;
    }

    /// @dev Deployer address for a read-only prediction.
    ///      Prefers an explicit `DEPLOYER` so the address integrators are meant to hardcode can be
    ///      checked from a machine that holds no key at all; falls back to deriving it from
    ///      `PRIVATE_KEY`.
    function _deployer() internal view returns (address) {
        address explicitDeployer = vm.envOr("DEPLOYER", address(0));
        return explicitDeployer != address(0) ? explicitDeployer : vm.addr(vm.envUint("PRIVATE_KEY"));
    }

    function _contractSalt(
        bytes32 rootSalt,
        string memory contractName
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(rootSalt, keccak256(abi.encodePacked(contractName))));
    }
}
