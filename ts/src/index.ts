/**
 * `@eco-foundation/delivery` — EcoDelivery, the outcome verifier at the end of a swap route.
 *
 * This entry point has **no runtime dependencies**. Import the chain-specific builders from
 * the subpaths, so an EVM-only consumer never pulls in the Solana packages:
 *
 * ```ts
 * import {minForTarget}        from "@eco-foundation/delivery";
 * import {encodeDeliverToken}  from "@eco-foundation/delivery/evm";  // needs viem
 * import {deliverTokenIx}      from "@eco-foundation/delivery/svm";  // needs @solana/*
 * ```
 *
 * The one rule the SDK cannot enforce for you: **fund and deliver in the same transaction.**
 * A balance left in the contract between transactions belongs to whoever calls next.
 */

export * from "./constants.js";
export * from "./min.js";
export {deliverAbi, type DeliverAbi} from "./generated/abi.js";
export {deliverIdl, type DeliverIdl, DELIVER_PROGRAM_ID} from "./generated/idl.js";
