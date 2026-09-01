#!/usr/bin/env bash
# Shared helpers for the recorded demo. Sourced by demo-reset.sh and demo-swap.sh.
#
# Everything here uses `cast`, never `forge script`. That is deliberate: forge script makes
# dozens of RPC calls to simulate and decode, and foundry.toml declares an [etherscan] block
# whose explorer returns HTML rather than JSON — so a single swap took 143 seconds and filled
# the terminal with markup. The same swap through `cast send` takes about three, and prints
# one line. On camera that is the whole difference.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; . ./.env; set +a
# CLEAN_PRIVATE_KEY lives in demo/.env; .env is re-sourced after so it always wins.
[ -f ../demo/.env ] && { set -a; . ../demo/.env; set +a; set -a; . ./.env; set +a; }

# The demo can use a different endpoint from the deploy scripts, and should.
#
# Measured on the day: sepolia.unichain.org answered eth_blockNumber in 5.8s average and
# dropped one call in five, which turned a three-second swap into forty. publicnode averaged
# 2.4s with 5/5 success. On camera that is the difference between a beat and a stall.
RPC="${DEMO_RPC_URL:-${UNICHAIN_SEPOLIA_RPC_URL}}"

# v4 constants
DYNAMIC_FEE=8388608                 # 0x800000, LPFeeLibrary.DYNAMIC_FEE_FLAG
TICK_SPACING=60
MIN_SQRT_PLUS1=4295128740
MAX_SQRT_MINUS1=1461446703485210103287273052203988822378723970341
POOLS_SLOT=6                        # PoolManager._pools

DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
AMBER=$'\033[38;5;173m'; TEAL=$'\033[38;5;73m'; RED=$'\033[38;5;167m'

POOL_KEY="($CURRENCY0,$CURRENCY1,$DYNAMIC_FEE,$TICK_SPACING,$HOOK_ADDRESS)"

die(){ printf '%s%s%s\n' "$RED" "$*" "$OFF" >&2; exit 1; }

# Live pool price, scaled 1e18, read straight from the PoolManager's packed slot0.
pool_price(){
  local slot raw
  slot=$(cast keccak "$(cast abi-encode 'f(bytes32,uint256)' "$POOL_ID" "$POOLS_SLOT")") || return 1
  raw=$(cast call "$POOL_MANAGER" "extsload(bytes32)(bytes32)" "$slot" --rpc-url "$RPC") || return 1
  python3 -c "
raw = int('$raw', 16)
sqrt = raw & ((1 << 160) - 1)
if sqrt == 0: raise SystemExit('pool not initialized')
print((sqrt * sqrt >> 96) * 10**18 >> 96)
"
}

# Send a transaction, surviving the failures this public RPC actually produces.
#
# It is load-balanced across replicas that disagree about the head, so `cast` intermittently
# sees a stale nonce, a block the next replica has not indexed, or a plain upstream error.
# Untreated, roughly one send in five dies — an unacceptable rate to carry into a recording.
#
# Retrying naively is worse than not retrying: a timeout can mean the transaction *did* land
# and only the response was lost, so a blind retry would send a second swap and put a phantom
# row on screen. So before each retry this checks whether the sender's nonce advanced. If it
# did, the transaction is already on chain and we stop.
DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY" 2>/dev/null || echo "")

_nonce(){ cast nonce "$DEPLOYER_ADDR" --rpc-url "$RPC" 2>/dev/null || echo ""; }

send_retry(){
  local out rc before after
  before=$(_nonce)
  for attempt in 1 2 3 4; do
    out=$("$@" 2>&1); rc=$?
    [ $rc -eq 0 ] && { printf '%s' "$out"; return 0; }

    after=$(_nonce)
    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" != "$before" ]; then
      printf '%s\n' "${DIM}  send reported an error but the nonce advanced — it landed${OFF}" >&2
      printf '%s' "$out"; return 0
    fi

    printf '%s\n' "${DIM}  rpc hiccup, retrying (${attempt}/4)…${OFF}" >&2
    sleep 3
  done
  printf '%s' "$out"; return 1
}
