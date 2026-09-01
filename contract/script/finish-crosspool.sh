#!/usr/bin/env bash
# Finish the cross-pool proof once Reactive Lasna is producing blocks again.
#
# Background: GlyphReactive propagates a wallet only after it has been reported toxic in two
# distinct pools. The origin side is already done and on chain (see docs/DEPLOYMENT.md) -- two
# pools, two ToxicSwapReported events, one wallet. What is missing is the reactive hop, and it is
# missing because Lasna halted at block 5,699,232 on 1 September 2026.
#
# This script is idempotent and safe to re-run. It checks before it sends, and it stops with a
# clear reason rather than broadcasting into a network that cannot mine.
#
#   usage: ./script/finish-crosspool.sh          from contract/, with .env populated
#
set -uo pipefail
cd "$(dirname "$0")/.."

set -a; . ./.env; set +a
[ -f ../demo/.env ] && { set -a; . ../demo/.env; set +a; }
# .env must win: demo/.env carries its own copies of these and has gone stale before.
set -a; . ./.env; set +a

LASNA=${LASNA_RPC_URL:-https://lasna-omni-rpc.rnk.dev/}
RSC=${REACTIVE_RSC_ADDRESS:-0xCAF1E314726f650481B634Cc79D4B846cb0c3Aa7}
ADAPTER=${CALLBACK_ADAPTER_ADDRESS:-0xd683F42F686CF4b729d5599f6964A0C36e461495}
REGISTRY_LC=$(echo "$REGISTRY_ADDRESS" | tr 'A-Z' 'a-z')
STALL_BLOCK=5699232

say(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
rpc(){ curl -s -m 30 -X POST "$1" -H 'Content-Type: application/json' -d "$2"; }

# ── 1. is Lasna alive? ────────────────────────────────────────────────────────
say "1/5  Is Reactive Lasna producing blocks?"
h1=$(rpc "$LASNA" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
     | python3 -c 'import json,sys;d=json.load(sys.stdin);print(int(d["result"],16))' 2>/dev/null)
[ -z "${h1:-}" ] && { echo "  Lasna RPC unreachable. Stopping."; exit 1; }
echo "  head: $h1"
if [ "$h1" -le "$STALL_BLOCK" ]; then
  echo "  Still at or below the stall block ($STALL_BLOCK). Nothing to do yet."
  exit 2
fi
echo "  Lasna has advanced past the stall. Continuing."

# ── 2. is our subscription active? ───────────────────────────────────────────
say "2/5  Subscription state on Reactive"
check_filter(){
  rpc "$LASNA" '{"jsonrpc":"2.0","method":"rnk_getFilters","params":[],"id":1}' | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('UNKNOWN'); raise SystemExit
tf=(d.get('result') or {}).get('TopicFilters') or []
for f in tf:
    if str(f.get('Contract','')).lower()=='$REGISTRY_LC':
        for c in f.get('Configs',[]):
            if str(c.get('Contract','')).lower()=='$(echo $RSC | tr 'A-Z' 'a-z')':
                print('ACTIVE' if c.get('Active') else 'INACTIVE'); raise SystemExit
print('MISSING')
"
}
state=$(check_filter); echo "  filter: $state"

if [ "$state" != "ACTIVE" ]; then
  say "     -> calling subscribe() on the RSC"
  # cast has defaulted the priority fee to 1 wei here before, which is why the first attempt
  # sat unmined for hours. Set both fields explicitly.
  cast send "$RSC" "subscribe()" \
    --private-key "$REACTIVE_PRIVATE_KEY" --rpc-url "$LASNA" \
    --priority-gas-price 5gwei --gas-price 400gwei --gas-limit 200000 2>&1 | tail -3
  for i in $(seq 1 10); do
    sleep 15; state=$(check_filter)
    echo "  [$i] filter: $state"
    [ "$state" = "ACTIVE" ] && break
  done
fi

[ "$state" != "ACTIVE" ] && { echo "  Subscription did not become active. Stopping before spending origin gas."; exit 3; }

# ── 3. emit two fresh toxic reports ──────────────────────────────────────────
# Reactive processes events forward from an active subscription, so the reports already on chain
# will not be replayed -- they have to be emitted again now that the filter is live.
say "3/5  Re-emitting two toxic reports across two distinct pools"
FROM_BLOCK=$(cast block-number --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")
ETHERSCAN_API_KEY="" forge script script/CrossPoolDemo.s.sol \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" --broadcast --slow 2>&1 \
  | grep -E "toxic swap|pool [AB]|ONCHAIN" || true

# ── 4. wait for the callback to land on the destination chain ────────────────
say "4/5  Waiting for CrossPoolScoreApplied on the adapter"
TOPIC=$(cast keccak "CrossPoolScoreApplied(address,uint16)")
found=""
for i in $(seq 1 20); do
  logs=$(cast logs --from-block "$FROM_BLOCK" --address "$ADAPTER" "$TOPIC" \
         --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" 2>/dev/null)
  if [ -n "$logs" ]; then found="$logs"; break; fi
  echo "  [$i] no callback yet…"; sleep 20
done

# ── 5. report ────────────────────────────────────────────────────────────────
say "5/5  Result"
if [ -n "$found" ]; then
  echo "$found"
  echo ""
  echo "  attacker score on the registry: $(cast call "$REGISTRY_ADDRESS" 'scoreOf(address)(uint16)' "$ATTACKER_ADDRESS" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL")"
  echo ""
  echo "  CROSS-POOL PATH FIRED END TO END."
  echo "  Record the transaction hash above in docs/DEPLOYMENT.md and drop the disclosed gap"
  echo "  from README.md and slide 12 of the deck."
  exit 0
else
  echo "  Subscription is active and both reports landed, but no callback arrived within ~7 min."
  echo "  Check the RSC's REACT balance and debt before assuming a defect:"
  echo "    cast balance $RSC --rpc-url $LASNA --ether"
  echo "    cast call 0x0000000000000000000000000000000000fffFfF 'debt(address)(uint256)' $RSC --rpc-url $LASNA"
  exit 4
fi
