# `Deliver` — EVM outcome verifier

`Deliver` forwards the entire balance it is **already holding** of an asset to a recipient, and
reverts unless that balance meets a caller-supplied minimum. It performs no swap and pulls no funds
in. Callers fund it first, then call it.

This is the EVM half of a dual-VM primitive; the Solana/Anchor half lives in `../solana` and is meant
to be behaviorally identical.

## Interface

```solidity
function deliverToken(IERC20 token, address recipient, uint256 min) external;
function deliverNative(address recipient, uint256 min) external;
receive() external payable;

address public constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

error BalanceBelowMin(uint256 balance, uint256 min);
error NativeTransferFailed(address recipient, uint256 amount);
```

`deliverToken` reads `token.balanceOf(address(this))`, reverts with `BalanceBelowMin` if it is under
`min`, and `SafeERC20.safeTransfer`s the whole balance to `recipient`. If `token` is `address(0)` or
`NATIVE_SENTINEL`, it dispatches to the native path instead.

`deliverNative` does the same for `address(this).balance`, sending with a call that forwards all
remaining gas and reverting with `NativeTransferFailed` if the send fails.

## Semantics

- **Sweep, not amount.** There is no `amount` parameter. Whatever is held is what gets delivered,
  including dust left over from a prior flow.
- **`min` is a floor on what arrived**, not swap slippage. The contract knows nothing about how the
  balance got there.
- **Stateless and permissionless.** No owner, no storage, no allowlist, no pause. Anyone may call
  either function, and the caller chooses the recipient. Safety comes from the caller binding
  `(token, recipient, min)` upstream. The corollary: a balance sitting in this contract is
  unconditionally claimable by the next caller, for a recipient of that caller's choosing. Never park
  funds here.
- **No events.** The ERC-20 `Transfer` log already carries recipient and amount.

## Decisions and their consequences

These were chosen deliberately. Each is pinned by a test so it cannot regress into a surprise.

1. **`min` is checked against the held balance pre-transfer.** For a fee-on-transfer, rebasing, or
   otherwise under-delivering token, the check can pass while the recipient receives strictly less
   than `min`, and the call still succeeds. Callers who need a guarantee on the *received* amount must
   enforce it themselves. Pinned by `test_Hole_FeeOnTransferTokenCanDeliverLessThanMin`.
2. **`address(0)` is a native-ETH sentinel, not a rejected input.** A caller with an uninitialized
   `token` field would normally get a harmless revert. Here it sweeps the contract's entire ETH
   balance to whatever `recipient` that buggy caller supplied. Pinned by
   `test_Hazard_UninitializedTokenSweepsEthInsteadOfReverting`.
3. **Zero balance with `min == 0` succeeds as a no-op**, matching the reference implementation, on
   both the ERC-20 path (a transfer of 0) and the native path (a 0-value call).
4. **The native send fails closed.** A recipient that reverts on receive takes the whole delivery
   down; a failed send is never swallowed.
5. **Reentrancy is unguarded because there is nothing to guard.** The transfer is the last action and
   no storage is written. A re-entrant token hook or native recipient finds a zero balance, so it
   either no-ops (`min == 0`) or reverts (`min > 0`); it cannot be paid twice. A token whose hook
   fires *before* its own balance update can make the outer transfer fail — the transaction then
   unwinds atomically and nothing moves.

## Layout

```
src/Deliver.sol                       the contract
test/Deliver.t.sol                    ERC-20 path: sweep, min boundaries, dust, permissionless, stateless, fuzz
test/DeliverNative.t.sol              native path: same coverage, plus fail-closed on a rejecting recipient
test/DeliverSentinels.t.sol           both native sentinels route to the native path; the address(0) hazard
test/DeliverNonStandardTokens.t.sol   USDT-style no-return, false-returning, and fee-on-transfer tokens
test/DeliverReentrancy.t.sol          hook-token and native recipient re-entry
test/mocks/                           token and recipient mocks
```

## Commands

```bash
forge build
forge test -vv
forge fmt          # `forge fmt --check` to verify only
forge coverage
```

`foundry.toml` pins solc 0.8.28 and `evm_version = "paris"` so the same bytecode deploys on L2s that
lag the EVM spec, with 4096 fuzz runs.

## Status

Not audited and not deployed. Nothing in this repo claims otherwise.
