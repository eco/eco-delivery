/**
 * Choosing `min` for assets that take a cut in transit.
 *
 * EcoDelivery checks `min` against the balance it holds **before** the transfer, never
 * against what the recipient ends up with. For a fee-taking asset that means subtracting
 * the fee from your target is wrong — you have to divide by what survives it.
 *
 * All amounts are in the asset's smallest unit (wei, or the mint's base units).
 */

const BPS = 10_000n;

function assertFeeBps(feeBps: number, max: number): void {
  if (!Number.isInteger(feeBps)) {
    throw new TypeError(`feeBps must be an integer, got ${feeBps}`);
  }
  if (feeBps < 0 || feeBps > max) {
    throw new RangeError(`feeBps must be between 0 and ${max}, got ${feeBps}`);
  }
}

function assertNonNegative(name: string, value: bigint): void {
  if (value < 0n) throw new RangeError(`${name} must be non-negative, got ${value}`);
}

/**
 * The `min` to pass so the recipient ends up with **at least** `target`, on an asset that
 * takes `feeBps` on transfer. Rounds up, because rounding down can land a wei short.
 *
 * ```ts
 * minForTarget(1_000n, 100) // 1% fee -> 1011n, not 990n
 * ```
 *
 * @param target the amount the recipient must actually receive
 * @param feeBps the transfer fee in basis points (100 = 1%), 0–9999
 */
export function minForTarget(target: bigint, feeBps: number): bigint {
  assertNonNegative("target", target);
  assertFeeBps(feeBps, 9_999);
  if (feeBps === 0) return target;
  const denominator = BPS - BigInt(feeBps);
  return (target * BPS + denominator - 1n) / denominator; // ceil
}

/**
 * What a recipient actually receives when `held` is swept through an asset taking
 * `feeBps`. Rounds down, matching how fee-taking implementations truncate.
 *
 * @param feeBps 0–10000; 10000 means the whole amount is taken
 */
export function receivedFor(held: bigint, feeBps: number): bigint {
  assertNonNegative("held", held);
  assertFeeBps(feeBps, 10_000);
  return (held * (BPS - BigInt(feeBps))) / BPS;
}

/**
 * How far short the recipient lands if you make the classic mistake of passing your
 * target as `min` on a fee-taking asset. Useful in tests and in logs.
 */
export function shortfallIfMinEqualsTarget(target: bigint, feeBps: number): bigint {
  return target - receivedFor(target, feeBps);
}
