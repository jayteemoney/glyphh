"""Show what a sandwich cost its attacker and paid its victim.

Reads a `cast send --json` receipt. The rebate is taken from the hook's own SandwichDetected
event rather than by reading the vault before and after: this RPC is load-balanced across
replicas that disagree about the head, and a before/after pair sampled from two different
replicas produced a negative rebate on a real run. The event is in the receipt, so there is
nothing to race.

The point of the L2 layer is *where the money goes*, so that is what this prints.
"""

import json
import os
import sys

# keccak256("SandwichDetected(bytes32,address,address,address,uint256)")
TOPIC0 = "0x6fb3ee650b9e257f5a2d66fd606f091cae15d28270343dd7521a4f6309c5b5d9"

receipt = json.load(sys.stdin)
if receipt.get("status") not in ("0x1", 1, "1"):
    sys.exit(f"  sandwich transaction did not succeed (status {receipt.get('status')})")

hook = os.environ.get("HOOK", "").lower()
rows = [
    lg for lg in receipt.get("logs", [])
    if lg["topics"] and lg["topics"][0].lower() == TOPIC0
    and (not hook or lg["address"].lower() == hook)
]

rebate = None
victim = None
if rows:
    lg = rows[-1]
    victim = "0x" + lg["topics"][3][-40:]
    rebate = int(lg["data"][2:][64:128], 16)

B = os.environ.get("BOLD", "")
D = os.environ.get("DIM", "")
O = os.environ.get("OFF", "")
AM = os.environ.get("AMBER", "")
TL = os.environ.get("TEAL", "")
score = os.environ.get("SCORE", "?")
owed = os.environ.get("OWED", "")

if rebate is None:
    sys.exit("  the transaction landed but the hook emitted no SandwichDetected — "
             "was the attacker already at MAX_FEE?")

print()
print(f"    {D}attacker flagged, toxicity{O}   {AM}{score:>12}{O}")
print(f"    {D}victim{O}                       {victim}")
print()
print(f"    {B}{TL}credited to the victim       {rebate / 1e18:>12.6f}{O} token0")
if owed:
    print(f"    {D}now claimable in the vault   {int(owed) / 1e18:>12.6f}{O}")
print()
print(f"    {D}taken from the attacker's closing leg, not from the LPs{O}")
print()
