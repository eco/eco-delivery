#!/usr/bin/env bash
#
# verifyAll.sh — publish the Deliver source on every chain's block explorer.
#
# `Deliver` takes no constructor arguments and is built with `bytecode_hash = "none"`, so
# verification is fully determined by foundry.toml. There is nothing to pass but the address.
#
# Three verifiers are needed for thirteen chains:
#
#   etherscan-v2  11 chains, one key. Etherscan's unified V2 API takes a `chainid` and covers
#                 60+ chains, so a single ETHERSCAN_API_KEY does almost everything.
#   routescan      9745 (plasma). Reachable through the V2 proxy for *submission*, but the proxy's
#                 `getsourcecode` never reflects the result — it keeps reporting the contract as
#                 unverified even after a successful submit. Check Routescan directly instead.
#   blockscout    57073 (ink). Not in Etherscan V2's chain list at all. Needs no API key.
#
# Required:
#   ETHERSCAN_API_KEY   an Etherscan V2 key (etherscan.io, "API Keys" — one key, all chains)
#
# Optional:
#   ONLY                comma-separated chain ids, e.g. ONLY=1,8453
#
# Usage:
#   ETHERSCAN_API_KEY=... ./script/verifyAll.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ADDRESS=0xAd8a3c3745633280FaFb0f44D0C2cc2c48475673
TARGET=src/Deliver.sol:Deliver
ONLY="${ONLY:-}"

fail() { echo "error: $*" >&2; exit 1; }
[ -n "${ETHERSCAN_API_KEY:-}" ] || fail "ETHERSCAN_API_KEY is not set"

ETHERSCAN_CHAINS="1 10 56 130 137 143 146 999 8453 42161 42220"
BLOCKSCOUT_URL_57073=https://explorer.inkonchain.com/api/

want() { [ -z "$ONLY" ] || echo ",$ONLY," | grep -q ",$1,"; }

for id in $ETHERSCAN_CHAINS; do
    want "$id" || continue
    printf '%-7s ' "$id"
    if forge verify-contract "$ADDRESS" "$TARGET" --chain-id "$id" \
         --etherscan-api-key "$ETHERSCAN_API_KEY" --watch >/dev/null 2>&1; then
        echo "submitted"
    else
        echo "FAILED"
    fi
done

if want 9745; then
    printf '%-7s ' 9745
    forge verify-contract "$ADDRESS" "$TARGET" --chain-id 9745 \
        --etherscan-api-key "$ETHERSCAN_API_KEY" --watch >/dev/null 2>&1 || true
    echo "submitted (confirm on Routescan, NOT the Etherscan V2 proxy)"
fi

if want 57073; then
    printf '%-7s ' 57073
    if forge verify-contract "$ADDRESS" "$TARGET" --chain-id 57073 \
         --verifier blockscout --verifier-url "$BLOCKSCOUT_URL_57073" --watch >/dev/null 2>&1; then
        echo "submitted"
    else
        echo "FAILED"
    fi
fi

echo
echo "Submission is not proof. Confirm published source independently:"
echo "  etherscan  https://api.etherscan.io/v2/api?chainid=<id>&module=contract&action=getsourcecode&address=$ADDRESS&apikey=\$ETHERSCAN_API_KEY"
echo "  plasma     https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan/api?module=contract&action=getsourcecode&address=$ADDRESS"
echo "  ink        https://explorer.inkonchain.com/api?module=contract&action=getsourcecode&address=$ADDRESS"
