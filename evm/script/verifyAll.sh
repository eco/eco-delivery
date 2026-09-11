#!/usr/bin/env bash
#
# verifyAll.sh — publish the Deliver source on every chain's block explorer.
#
# The address and the chain list are read from ../deployments.json, so this script cannot drift
# from what is actually deployed. A redeploy that moves the address needs no edit here.
#
# `Deliver` takes no constructor arguments and is built with `bytecode_hash = "none"`, so
# verification is fully determined by foundry.toml. There is nothing to pass but the address.
#
# Three verifiers are needed. Which chain needs which is a property of the explorer ecosystem
# rather than of our deployment, so that routing lives here and not in deployments.json:
#
#   etherscan-v2  most chains, one key. Etherscan's unified V2 API takes a `chainid` and covers
#                 60+ chains, so a single ETHERSCAN_API_KEY does almost everything.
#   routescan     9745 (plasma). Reachable through the V2 proxy for *submission*, but the proxy's
#                 `getsourcecode` never reflects the result — it keeps reporting the contract as
#                 unverified even after a successful submit. Check Routescan directly instead.
#   blockscout    57073 (ink). Not in Etherscan V2's chain list at all. Needs no API key.
#
# Required:
#   ETHERSCAN_API_KEY   an Etherscan V2 key (etherscan.io, "API Keys" — one key, all chains)
#
# Optional:
#   ONLY                comma-separated chain ids, e.g. ONLY=1,8453
#   ADDRESS             override the address from deployments.json
#   DEPLOYMENTS         path to deployments.json
#
# Usage:
#   ETHERSCAN_API_KEY=... ./script/verifyAll.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEPLOYMENTS="${DEPLOYMENTS:-../deployments.json}"
TARGET=src/Deliver.sol:Deliver
ONLY="${ONLY:-}"

fail() { echo "error: $*" >&2; exit 1; }
[ -n "${ETHERSCAN_API_KEY:-}" ] || fail "ETHERSCAN_API_KEY is not set"
[ -f "$DEPLOYMENTS" ] || fail "deployments file not found: $DEPLOYMENTS"

ADDRESS="${ADDRESS:-$(python3 -c "import json;print(json.load(open('$DEPLOYMENTS'))['evm']['address'])")}"
ALL_CHAINS=$(python3 -c "import json;print(' '.join(str(c) for c in json.load(open('$DEPLOYMENTS'))['evm']['chains']))")

# Chains whose verifier is not Etherscan V2.
ROUTESCAN_CHAINS="9745"
BLOCKSCOUT_URL_57073=https://explorer.inkonchain.com/api/

echo "address: $ADDRESS"
echo "chains:  $(echo "$ALL_CHAINS" | wc -w | tr -d ' ') (from $DEPLOYMENTS)"
echo

want() { [ -z "$ONLY" ] || echo ",$ONLY," | grep -q ",$1,"; }
has()  { echo " $2 " | grep -q " $1 "; }

for id in $ALL_CHAINS; do
    want "$id" || continue
    printf '%-7s ' "$id"

    if [ "$id" = "57073" ]; then
        if forge verify-contract "$ADDRESS" "$TARGET" --chain-id "$id" \
             --verifier blockscout --verifier-url "$BLOCKSCOUT_URL_57073" --watch >/dev/null 2>&1; then
            echo "submitted (blockscout)"
        else
            echo "FAILED (blockscout)"
        fi
        continue
    fi

    forge verify-contract "$ADDRESS" "$TARGET" --chain-id "$id" \
        --etherscan-api-key "$ETHERSCAN_API_KEY" --watch >/dev/null 2>&1 && rc=0 || rc=1

    if has "$id" "$ROUTESCAN_CHAINS"; then
        # forge reports `Pass - Verified` here regardless; do not believe it.
        echo "submitted (confirm on Routescan, NOT the Etherscan V2 proxy)"
    elif [ $rc -eq 0 ]; then
        echo "submitted"
    else
        echo "FAILED"
    fi
done

echo
echo "Submission is not proof. Confirm published source independently:"
echo "  etherscan  https://api.etherscan.io/v2/api?chainid=<id>&module=contract&action=getsourcecode&address=$ADDRESS&apikey=\$ETHERSCAN_API_KEY"
echo "  plasma     https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan/api?module=contract&action=getsourcecode&address=$ADDRESS"
echo "  ink        https://explorer.inkonchain.com/api?module=contract&action=getsourcecode&address=$ADDRESS"
