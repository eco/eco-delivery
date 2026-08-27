// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Deliver
/// @notice An outcome verifier: it forwards the entire balance it is *already holding* of a given
///         asset to a recipient, and reverts unless that balance meets a caller-supplied floor.
///
/// @dev ## Why this exists
///
///      This is the **last step of a swap route**. A route is a chain of components nobody here
///      wrote — an aggregator, a bridge, an AMM hop, an RFQ filler — each with its own notion of
///      slippage, its own `minOut` semantics, and sometimes no guarantee at all. Rather than trust
///      each provider's promise, every route ends by depositing its output into this contract, and
///      the floor is enforced once, at the end, on the amount that actually arrived.
///
///      That is why it knows nothing about swaps: the guarantee has to hold *regardless* of what
///      ran in front of it. Adding or reordering providers changes nothing about how delivery is
///      enforced. And because the check happens once on the real output, the intermediate hops'
///      own slippage settings stop being a safety property — if the route under-delivers, this
///      step reverts and the user keeps their input.
///
///      **The guarantee, stated exactly:** if the call does not revert, the recipient was sent the
///      entire balance this contract held of that asset, and that balance was at least `min`. The
///      two WARNINGs below are what that does not cover.
///
///      ## What this contract is
///
///      This is a pass-through, not a vault, not a router, not a swapper. The intended flow is:
///
///        1. Some upstream system (a bridge, a filler, a swap, a plain transfer) moves funds *into*
///           this contract.
///        2. Someone calls {deliverToken} / {deliverNative} with `(asset, recipient, min)`.
///        3. The contract reads its own balance, asserts `balance >= min`, and sends the whole
///           balance to `recipient`.
///
///      Verification is therefore *post-hoc*: the contract never pulls funds in, never calls
///      `transferFrom`, and knows nothing about how the balance got there. It only asserts a lower
///      bound on what arrived and forwards it.
///
///      ## Sweep, not amount
///
///      There is deliberately no `amount` parameter. Whatever arrived is what gets delivered — the
///      full balance, including any dust left over from a prior flow. That is the point of the
///      primitive, not an oversight. A consequence worth stating plainly: **any balance sitting in
///      this contract is unconditionally claimable by the next caller.** Never park funds here.
///
///      ## `min` is a floor on what arrived
///
///      This contract performs no swap and cannot tell slippage from a bridge fee; `min` is purely
///      a lower bound on the balance held at call time. In the route, though, `min` *is* the
///      route's final `minOut` — enforced once, at the end, on the real output.
///
///      ## Permissionless by design
///
///      No owner, no storage, no allowlist, no pause. Anyone may call either function. Safety comes
///      entirely from the *caller* binding `(asset, recipient, min)` — typically an intent or
///      settlement system upstream that commits to those three values before funding this contract.
///      Access control here would not add safety; it would only move the trust assumption. If a
///      caller passes a wrong `recipient`, that is the caller's bug, and this contract will happily
///      execute it.
///
///      **Consequence — fund and deliver in ONE transaction.** A balance sitting here between
///      transactions does not merely sit at risk; it *belongs* to whoever calls next, for a
///      recipient of their choosing, and calling `deliverToken(token, self, 0)` against it is a
///      valid in-spec use of this contract by anyone. If a route deposits output in one
///      transaction and delivers in another, the funds are gone in between. Pinned by
///      `test_AnyoneCanDivertAStrandedBalance`. See `docs/INTEGRATING.md`.
///
///      ## WARNING — fee-on-transfer, rebasing, and hook tokens can under-deliver
///
///      `min` is checked against the **held balance before the transfer**, not against the amount
///      the recipient actually ends up with. This is the cheap form and it is a deliberate choice.
///
///      For a token that takes a fee on transfer, rebases downward mid-transfer, or otherwise moves
///      less than the requested amount, **the check can pass while the recipient receives strictly
///      less than `min`.** The call will succeed. Nothing here detects it. Integrators who need a
///      hard guarantee on *received* amount for such tokens must enforce it themselves — measure the
///      recipient's balance delta in the calling contract — or must not route those tokens through
///      this contract at all.
///
///      ## WARNING — `address(0)` is a native-ETH sentinel, not a rejected input
///
///      Both `address(0)` and `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` are accepted by
///      {deliverToken} as sentinels meaning "native ETH", and route to the native path.
///
///      Accepting `address(0)` has a specific, accepted hazard: the classic uninitialized-variable
///      caller bug — a caller that forgets to set its `token` field and passes a zero address —
///      normally reverts harmlessly. **Here it does not revert. It sweeps this contract's entire
///      native ETH balance to the caller-supplied `recipient`.** A bug that would otherwise be a
///      revert becomes an ETH transfer. This was chosen knowingly; callers must treat a zero token
///      address as a live, funds-moving input and validate it upstream.
///
///      ## Reentrancy
///
///      There is no state to corrupt and the transfer is the last action. A token transfer hook or a
///      native recipient that re-enters will find a zero balance, so a re-entrant call either
///      no-ops (when its `min` is 0) or reverts (when its `min` is greater than 0). Neither can
///      double-deliver. A token whose hook fires *before* its own balance update can force the outer
///      transfer to fail; the whole transaction then reverts atomically and no funds move.
///
///      ## Events
///
///      None are emitted. The ERC-20 `Transfer` log already carries `(recipient, amount)`, which is
///      the outcome an indexer needs; a second event would be redundant and cost gas.
contract Deliver {
    using SafeERC20 for IERC20;

    /// @notice Sentinel token address meaning "native ETH", the widely used `0xEeee...EEeE` form.
    /// @dev See the contract-level WARNING: `address(0)` is *also* treated as this sentinel.
    address public constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice The balance held at call time was below the caller-supplied floor. Nothing was moved.
    /// @param balance The balance this contract held when the check ran.
    /// @param min The floor the caller required.
    error BalanceBelowMin(uint256 balance, uint256 min);

    /// @notice The native ETH send failed; the delivery reverts rather than stranding value.
    /// @param recipient The address the send was attempted to.
    /// @param amount The amount that was attempted.
    error NativeTransferFailed(address recipient, uint256 amount);

    /// @notice Deliver this contract's entire balance of `token` to `recipient`, requiring at least
    ///         `min`.
    /// @dev Reverts with {BalanceBelowMin} if the held balance is below `min`. A held balance of 0
    ///      with `min == 0` succeeds as a no-op transfer of 0 — that is intentional and tested.
    ///
    ///      If `token` is `address(0)` or {NATIVE_SENTINEL}, this dispatches to the native path and
    ///      sweeps ETH instead. Read the contract-level `address(0)` WARNING before relying on that.
    ///
    ///      The `min` check is on the *held* balance, pre-transfer. See the fee-on-transfer WARNING:
    ///      a fee-taking or rebasing token can pass this check and still deliver less than `min`.
    /// @param token The ERC-20 to sweep, or a native sentinel to sweep ETH.
    /// @param recipient The address that receives the entire balance. Not validated — the caller
    ///        owns this choice, including passing `address(0)` and burning the funds.
    /// @param min The minimum balance that must be held for the delivery to be considered valid.
    function deliverToken(
        IERC20 token,
        address recipient,
        uint256 min
    ) external {
        if (address(token) == address(0) || address(token) == NATIVE_SENTINEL) {
            _deliverNative(recipient, min);
            return;
        }

        uint256 balance = token.balanceOf(address(this));
        if (balance < min) revert BalanceBelowMin(balance, min);

        token.safeTransfer(recipient, balance);
    }

    /// @notice Deliver this contract's entire native ETH balance to `recipient`, requiring at least
    ///         `min`.
    /// @dev The direct native entry point; {deliverToken} routes here for the two native sentinels.
    ///      Reverts with {BalanceBelowMin} if the held balance is below `min`, and with
    ///      {NativeTransferFailed} if the send fails — it fails closed, it never swallows a failed
    ///      send. A balance of 0 with `min == 0` succeeds as a no-op 0-value call, mirroring the
    ///      ERC-20 path.
    /// @param recipient The address that receives the entire ETH balance. All remaining gas is
    ///        forwarded, so a contract recipient may execute arbitrary logic, including re-entering
    ///        this contract — where it will find a zero balance.
    /// @param min The minimum ETH balance that must be held for the delivery to be considered valid.
    function deliverNative(
        address recipient,
        uint256 min
    ) external {
        _deliverNative(recipient, min);
    }

    /// @dev Shared native sweep. Checks the floor against `address(this).balance`, then forwards the
    ///      whole balance with all available gas. Reverting on a failed send is deliberate: a silent
    ///      failure would report a delivery that did not happen.
    function _deliverNative(
        address recipient,
        uint256 min
    ) internal {
        uint256 balance = address(this).balance;
        if (balance < min) revert BalanceBelowMin(balance, min);

        (bool ok,) = recipient.call{value: balance}("");
        if (!ok) revert NativeTransferFailed(recipient, balance);
    }

    /// @notice Accepts native ETH so the contract can be funded ahead of a delivery.
    /// @dev Empty on purpose: funding is step one of the flow, delivery is a separate explicit call.
    receive() external payable {}
}
