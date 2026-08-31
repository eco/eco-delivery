#!/usr/bin/env bash
#
# deploy.sh — deploy the `deliver` program and make it IMMUTABLE.
#
# Immutability is the default and the point. The EVM contract has no upgrade path, so an upgradeable
# Solana program would mean integrators must trust whoever holds the upgrade authority on one chain
# and nobody on the other — an asymmetry in a repo whose whole claim is that the two are one
# primitive in two encodings.
#
# Deliberately NOT `solana program deploy --final`, which finalises in the same breath as the upload.
# This does it in three steps:
#
#   1. deploy upgradeable
#   2. verify the on-chain bytes match the local .so
#   3. only then set the upgrade authority to none, irreversibly
#
# The reason is the failure mode: `--final` on a bad or truncated upload leaves a permanently wrong
# program at that id, unfixable, and the vanity id is spent. Verifying between the two makes the
# irreversible step conditional on the reversible one having worked.
#
# Required:
#   SOLANA_RPC_URL       cluster endpoint
#   DEPLOYER_KEYPAIR     path to the payer / upgrade-authority keypair
#
# Optional:
#   FINALIZE=false       stop after verification, leaving the program upgradeable
#
# Usage:
#   SOLANA_RPC_URL=... DEPLOYER_KEYPAIR=~/deployer.json ./script/deploy.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { echo "error: $*" >&2; exit 1; }

[ -n "${SOLANA_RPC_URL:-}" ]   || fail "SOLANA_RPC_URL is not set"
[ -n "${DEPLOYER_KEYPAIR:-}" ] || fail "DEPLOYER_KEYPAIR is not set"
[ -f "$DEPLOYER_KEYPAIR" ]     || fail "keypair not found: $DEPLOYER_KEYPAIR"
FINALIZE="${FINALIZE:-true}"

PROGRAM_KEYPAIR=target/deploy/deliver-keypair.json
SO=target/deploy/deliver.so

echo "== build =="
anchor build
[ -f "$SO" ] || fail "no artifact at $SO"
[ -f "$PROGRAM_KEYPAIR" ] || fail "program keypair missing: $PROGRAM_KEYPAIR"

PROGRAM_ID=$(solana-keygen pubkey "$PROGRAM_KEYPAIR")
DECLARED=$(python3 -c "import json;print(json.load(open('target/idl/deliver.json'))['address'])")
[ "$PROGRAM_ID" = "$DECLARED" ] || fail "declare_id! ($DECLARED) does not match the program keypair ($PROGRAM_ID)"

echo "  program id : $PROGRAM_ID"
echo "  size       : $(stat -f%z "$SO" 2>/dev/null || stat -c%s "$SO") bytes"

echo
echo "== 1/3 deploy (upgradeable for now) =="
solana program deploy "$SO" \
    --program-id "$PROGRAM_KEYPAIR" \
    --keypair "$DEPLOYER_KEYPAIR" \
    --upgrade-authority "$DEPLOYER_KEYPAIR" \
    --url "$SOLANA_RPC_URL"

echo
echo "== 2/3 verify on-chain bytes match the local build =="
DUMP=$(mktemp -t deliver-onchain).so
solana program dump "$PROGRAM_ID" "$DUMP" --url "$SOLANA_RPC_URL" >/dev/null
# `dump` right-pads to the allocated account size, so compare only the first N bytes.
LOCAL_LEN=$(stat -f%z "$SO" 2>/dev/null || stat -c%s "$SO")
if ! cmp -n "$LOCAL_LEN" -s "$SO" "$DUMP"; then
    rm -f "$DUMP"
    fail "on-chain bytes do NOT match the local build — refusing to finalise. The program is still upgradeable; redeploy."
fi
rm -f "$DUMP"
echo "  match: first $LOCAL_LEN bytes identical"

if [ "$FINALIZE" != "true" ]; then
    echo
    echo "FINALIZE=false — leaving the program UPGRADEABLE."
    echo "Finalise later with:"
    echo "  solana program set-upgrade-authority $PROGRAM_ID --final --keypair $DEPLOYER_KEYPAIR --url \$SOLANA_RPC_URL"
    exit 0
fi

echo
echo "== 3/3 make immutable (IRREVERSIBLE) =="
solana program set-upgrade-authority "$PROGRAM_ID" \
    --final \
    --keypair "$DEPLOYER_KEYPAIR" \
    --url "$SOLANA_RPC_URL"

echo
echo "== confirm =="
OUT=$(solana program show "$PROGRAM_ID" --url "$SOLANA_RPC_URL")
echo "$OUT" | grep -E 'Program Id|Authority|Data Length' || true
if echo "$OUT" | grep -qi 'Authority: none'; then
    echo
    echo "IMMUTABLE — upgrade authority is none. This cannot be undone."
else
    fail "expected 'Authority: none' after finalising; got otherwise. Check the program state."
fi
