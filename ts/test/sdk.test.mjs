// Verifies the SDK against values derived independently of it:
//   selectors      -> `cast sig "deliverToken(address,address,uint256)"`
//   discriminators -> sha256("global:<name>")[..8]
// Run against the built dist so the packaged entry points are what gets tested.

import {test} from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";

import {
  minForTarget,
  receivedFor,
  shortfallIfMinEqualsTarget,
  NATIVE_SENTINEL,
  ZERO_ADDRESS,
} from "../dist/index.js";
import {
  encodeDeliverToken,
  encodeDeliverNative,
  deliverTokenCall,
  decodeDeliverError,
  isNativeSentinel,
} from "../dist/evm.js";
import {
  deliverTokenIx,
  deliverSolIx,
  vaultAuthority,
  vaultTokenAccount,
  DELIVER_PROGRAM,
} from "../dist/svm.js";
import {PublicKey} from "@solana/web3.js";
import {encodeErrorResult} from "viem";
import {deliverAbi} from "../dist/index.js";

const A = "0x1111111111111111111111111111111111111111";
const B = "0x2222222222222222222222222222222222222222";

test("minForTarget divides rather than subtracts", () => {
  // 1% fee, want the recipient to end up with 1000.
  assert.equal(minForTarget(1000n, 100), 1011n);
  // and it is genuinely minimal: one less falls short.
  assert.ok(receivedFor(1011n, 100) >= 1000n);
  assert.ok(receivedFor(1010n, 100) < 1000n);
  // the naive answer under-delivers, which is the whole point
  assert.equal(receivedFor(1000n, 100), 990n);
  assert.equal(shortfallIfMinEqualsTarget(1000n, 100), 10n);
});

test("minForTarget is identity at zero fee and rejects bad input", () => {
  assert.equal(minForTarget(12345n, 0), 12345n);
  assert.throws(() => minForTarget(1n, 10_000), RangeError);
  assert.throws(() => minForTarget(1n, -1), RangeError);
  assert.throws(() => minForTarget(1n, 1.5), TypeError);
  assert.throws(() => minForTarget(-1n, 0), RangeError);
});

test("EVM selectors match `cast sig`", () => {
  assert.equal(encodeDeliverToken({token: A, recipient: B, min: 1n}).slice(0, 10), "0x44a2d58c");
  assert.equal(encodeDeliverNative({recipient: B, min: 1n}).slice(0, 10), "0x66599bc3");
});

test("deliverTokenCall never attaches value", () => {
  const call = deliverTokenCall(A, {token: B, recipient: B, min: 5n});
  assert.equal(call.to, A);
  assert.equal(call.value, 0n);
});

test("both native sentinels are recognised, including mixed case", () => {
  assert.ok(isNativeSentinel(ZERO_ADDRESS));
  assert.ok(isNativeSentinel(NATIVE_SENTINEL));
  assert.ok(isNativeSentinel(NATIVE_SENTINEL.toLowerCase()));
  assert.ok(!isNativeSentinel(A));
});

test("decodeDeliverError round-trips BalanceBelowMin", () => {
  const data = encodeErrorResult({
    abi: deliverAbi,
    errorName: "BalanceBelowMin",
    args: [7n, 9n],
  });
  assert.deepEqual(decodeDeliverError(data), {name: "BalanceBelowMin", balance: 7n, min: 9n});
  assert.equal(decodeDeliverError("0xdeadbeef"), null);
});

test("Anchor discriminators match sha256(global:<name>)", () => {
  const disc = (n) => [...createHash("sha256").update(`global:${n}`).digest().subarray(0, 8)];
  const payer = PublicKey.unique();
  const mint = PublicKey.unique();
  const recipient = PublicKey.unique();

  const tokenIx = deliverTokenIx({payer, mint, recipient, min: 1n});
  assert.deepEqual([...tokenIx.data.subarray(0, 8)], disc("deliver_token"));

  const solIx = deliverSolIx({caller: payer, recipient, min: 1n});
  assert.deepEqual([...solIx.data.subarray(0, 8)], disc("deliver_sol"));
});

test("instruction data is discriminator + little-endian u64", () => {
  const ix = deliverSolIx({
    caller: PublicKey.unique(),
    recipient: PublicKey.unique(),
    min: 0x0102030405060708n,
  });
  assert.equal(ix.data.length, 16);
  assert.deepEqual([...ix.data.subarray(8)], [8, 7, 6, 5, 4, 3, 2, 1]);
  assert.throws(() => deliverSolIx({
    caller: PublicKey.unique(), recipient: PublicKey.unique(), min: 1n << 64n,
  }), RangeError);
});

test("account order and flags match the IDL", () => {
  const payer = PublicKey.unique();
  const mint = PublicKey.unique();
  const recipient = PublicKey.unique();
  const ix = deliverTokenIx({payer, mint, recipient, min: 0n});

  assert.equal(ix.keys.length, 9);
  assert.deepEqual(
    ix.keys.map((k) => [k.isSigner, k.isWritable]),
    [[true, true], [false, false], [false, false], [false, true],
     [false, false], [false, true], [false, false], [false, false], [false, false]],
  );
  assert.ok(ix.keys[1].pubkey.equals(vaultAuthority()));
  assert.ok(ix.keys[3].pubkey.equals(vaultTokenAccount(mint)));
  assert.ok(ix.programId.equals(DELIVER_PROGRAM));
});

test("vault authority is the [b'vault'] PDA and is off-curve", () => {
  const [expected] = PublicKey.findProgramAddressSync([Buffer.from("vault")], DELIVER_PROGRAM);
  assert.ok(vaultAuthority().equals(expected));
  assert.ok(!PublicKey.isOnCurve(vaultAuthority().toBytes()));
});
