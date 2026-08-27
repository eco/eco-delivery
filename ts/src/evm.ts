/**
 * EVM call builders. Requires `viem` as a peer dependency.
 */

import {
  decodeErrorResult,
  encodeFunctionData,
  type Address,
  type Hex,
} from "viem";
import {deliverAbi} from "./generated/abi.js";
import {NATIVE_SENTINEL, ZERO_ADDRESS} from "./constants.js";

export {deliverAbi};

/**
 * Does this token address route into the native path?
 *
 * Both `address(0)` and `0xEeee…` do. Call this before handing a user-supplied or
 * config-supplied token to {@link encodeDeliverToken}: a zero address here is not an
 * error the contract will catch for you, it is a live instruction to sweep ETH.
 */
export function isNativeSentinel(token: Address): boolean {
  const t = token.toLowerCase();
  return t === ZERO_ADDRESS || t === NATIVE_SENTINEL.toLowerCase();
}

export interface DeliverTokenArgs {
  /** The ERC-20 to sweep, or a native sentinel to sweep ETH. */
  token: Address;
  /** Never validated by the contract — bind it upstream. */
  recipient: Address;
  /** Floor on the held balance, in the token's smallest unit. */
  min: bigint;
}

export interface DeliverNativeArgs {
  recipient: Address;
  min: bigint;
}

/** Calldata for `deliverToken(address,address,uint256)`. */
export function encodeDeliverToken({token, recipient, min}: DeliverTokenArgs): Hex {
  return encodeFunctionData({
    abi: deliverAbi,
    functionName: "deliverToken",
    args: [token, recipient, min],
  });
}

/** Calldata for `deliverNative(address,uint256)`. */
export function encodeDeliverNative({recipient, min}: DeliverNativeArgs): Hex {
  return encodeFunctionData({
    abi: deliverAbi,
    functionName: "deliverNative",
    args: [recipient, min],
  });
}

export interface DeliverCall {
  to: Address;
  data: Hex;
  /** Always zero: the contract is funded before the call, never by it. */
  value: bigint;
}

/**
 * A ready-to-append call for your settlement contract or multicall.
 *
 * Append this to the route in the **same transaction** that produces the output. Splitting
 * it into a second transaction hands the balance to whoever calls first.
 */
export function deliverTokenCall(deliver: Address, args: DeliverTokenArgs): DeliverCall {
  return {to: deliver, data: encodeDeliverToken(args), value: 0n};
}

/** As {@link deliverTokenCall}, for the direct native entry point. */
export function deliverNativeCall(deliver: Address, args: DeliverNativeArgs): DeliverCall {
  return {to: deliver, data: encodeDeliverNative(args), value: 0n};
}

export type DeliverError =
  | {name: "BalanceBelowMin"; balance: bigint; min: bigint}
  | {name: "NativeTransferFailed"; recipient: Address; amount: bigint}
  | {name: "SafeERC20FailedOperation"; token: Address};

/**
 * Decode a revert returned by the contract, or `null` if the data is not one of its errors.
 *
 * `BalanceBelowMin` carries the balance the contract actually held. A `balance` of zero
 * almost always means the funds were never deposited, or were already swept by someone
 * else because the flow was not atomic — not that the route under-delivered.
 */
export function decodeDeliverError(data: Hex): DeliverError | null {
  try {
    const decoded = decodeErrorResult({abi: deliverAbi, data});
    switch (decoded.errorName) {
      case "BalanceBelowMin": {
        const [balance, min] = decoded.args as readonly [bigint, bigint];
        return {name: "BalanceBelowMin", balance, min};
      }
      case "NativeTransferFailed": {
        const [recipient, amount] = decoded.args as readonly [Address, bigint];
        return {name: "NativeTransferFailed", recipient, amount};
      }
      case "SafeERC20FailedOperation": {
        const [token] = decoded.args as readonly [Address];
        return {name: "SafeERC20FailedOperation", token};
      }
      default:
        return null;
    }
  } catch {
    return null;
  }
}
