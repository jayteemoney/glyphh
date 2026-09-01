#!/usr/bin/env bash
# The victim withdraws what the attacker was charged.
#
#   ./script/demo-claim.sh
#
# The dashboard has a Claim button and that is the better thing to show — a judge can connect a
# wallet and be paid. This is the fallback for when the browser is being slow, and it makes the
# same point: the balance that goes up belongs to the trader who was sandwiched.
source "$(dirname "$0")/demo-lib.sh"

[ -n "${CLEAN_PRIVATE_KEY:-}" ] || die "CLEAN_PRIVATE_KEY not set (it lives in demo/.env)"

before=$(cast call "$CURRENCY0" "balanceOf(address)(uint256)" "$CLEAN_ADDRESS" --rpc-url "$RPC" | awk '{print $1}')
owed=$(cast call "$VAULT_ADDRESS" "claimable(address,address)(uint256)" "$CLEAN_ADDRESS" "$CURRENCY0" --rpc-url "$RPC" | awk '{print $1}')
[ "${owed:-0}" != "0" ] || die "nothing owed — run ./script/demo-sandwich.sh first"

printf '%s\n' "${DIM}claiming as the victim…${OFF}"
send_retry cast send "$VAULT_ADDRESS" "claim(address)" "$CURRENCY0" \
  --private-key "$CLEAN_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null || die "claim failed"

after=$(cast call "$CURRENCY0" "balanceOf(address)(uint256)" "$CLEAN_ADDRESS" --rpc-url "$RPC" | awk '{print $1}')
left=$(cast call "$VAULT_ADDRESS" "claimable(address,address)(uint256)" "$CLEAN_ADDRESS" "$CURRENCY0" --rpc-url "$RPC" | awk '{print $1}')

BEFORE="$before" AFTER="$after" LEFT="$left" BOLD="$BOLD" DIM="$DIM" OFF="$OFF" TEAL="$TEAL" python3 -c '
import os
b, a, l = (int(os.environ[k]) for k in ("BEFORE", "AFTER", "LEFT"))
B, D, O, T = (os.environ[k] for k in ("BOLD", "DIM", "OFF", "TEAL"))
print()
print(f"    {D}victim balance before{O}   {b/1e18:>14.6f}")
print(f"    {B}{T}victim balance after    {a/1e18:>14.6f}{O}")
print(f"    {D}still claimable{O}         {l/1e18:>14.6f}")
print()
print(f"    {B}{(a-b)/1e18:.6f}{O} token0 moved from the attacker to the trader they sandwiched.")
print()
'
