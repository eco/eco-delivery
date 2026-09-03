// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICreateX
/// @notice The two CreateX functions this repo's deploy script needs.
/// @dev CreateX lives at the same address on every chain it is deployed to. Deployment tooling
///      only, which is why this sits under `script/` rather than `src/`.
interface ICreateX {
    /// @notice CREATE2-deploy `initCode` under `salt`.
    /// @dev CreateX transforms `salt` internally before the CREATE2 (see `_guard`). For an
    ///      unguarded salt the transform is `keccak256(abi.encode(salt))`.
    function deployCreate2(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address);

    /// @notice Address that `initCodeHash` would land at under `salt`, with CreateX as deployer.
    /// @dev Takes an **already-guarded** salt — it does not apply the transform itself.
    function computeCreate2Address(
        bytes32 salt,
        bytes32 initCodeHash
    ) external view returns (address);
}
