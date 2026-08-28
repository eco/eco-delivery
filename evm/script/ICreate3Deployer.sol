// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICreate3Deployer
/// @notice Minimal interface to the shared CREATE3 deployer eco uses across its repos.
/// @dev Copied from `eco-routes/contracts/tools/ICreate3Deployer.sol`, trimmed to the two
///      functions this repo's deploy script needs. It lives under `script/` rather than `src/`
///      on purpose: it is deployment tooling, not part of the delivered contract surface.
interface ICreate3Deployer {
    /// @notice Deploy `bytecode` at an address derived from `(msg.sender, salt)`.
    /// @dev CREATE3 derives the address from the sender and salt **only** — the bytecode does not
    ///      affect it. That is what gives the same address on every chain, and it is also why the
    ///      deploy script verifies the deployed code afterwards rather than trusting the address.
    function deploy(
        bytes memory bytecode,
        bytes32 salt
    ) external payable returns (address);

    /// @notice The address `sender` would deploy to with `salt`.
    /// @dev `bytecode` is accepted for interface compatibility and ignored by CREATE3; pass `""`.
    function deployedAddress(
        bytes memory bytecode,
        address sender,
        bytes32 salt
    ) external view returns (address);
}
