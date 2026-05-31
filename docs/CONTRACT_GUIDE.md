# Contract Implementation Guide

Your single reference for everything you need to implement in `contract/src/`.

---

## 1. File ownership (solo — you own all of it)

| File | Purpose |
|---|---|
| `src/GlyphHook.sol` | Per-swap fee decision, Pyth local toxicity, LP donation |
| `src/libraries/ToxicityScoring.sol` | Pure fee curve: score → fee |
| `src/ReputationRegistry.sol` | Score storage, EIP-712 attestation verify, hook auth |
| `src/reactive/GlyphReactive.sol` | Reactive RSC: cross-pool score propagation |
| `src/interfaces/IReputationRegistry.sol` | Frozen seam between hook ↔ registry |
| `test/GlyphHook.t.sol` | Hook unit + integration tests |
| `test/ReputationRegistry.t.sol` | Registry unit + invariant tests |
| `test/ToxicityScoring.t.sol` | Library fuzz tests |
| `test/utils/HookMiner.sol` | CREATE2 address miner utility |
| `script/DeployGlyph.s.sol` | Unichain Sepolia deploy script |

---

## 2. Implementation order

Follow this sequence. Each step builds on the previous.

### Step 1 — ToxicityScoring library  
**File:** `src/libraries/ToxicityScoring.sol`  
**Why first:** everything else depends on the fee curve.

- Implement `scoreToFee(uint16 score) → uint24 fee`
  - score = 0 → `DEFAULT_BASE_FEE` (3000 = 0.30%)
  - score = 10_000 → `MAX_FEE` (100_000 = 10.00%)
  - Curve shape: your choice — linear is fine for hackathon. Exponential is more defensible.
  - Formula for linear: `fee = DEFAULT_BASE_FEE + (MAX_FEE - DEFAULT_BASE_FEE) * score / MAX_SCORE`
  - Wrap arithmetic in `uint256` before dividing to avoid overflow: `uint16 * uint24` overflows at ~1.6M.
  - Cast back to `uint24` only after all math is done.

- Implement `computeSeverity(uint16 impactBps, uint16 reputationScore) → uint16`
  - Produces a 0..10_000 severity value stored in `ToxicTradeReported.localSeverity`.
  - Simple approach: `severity = min(impactBps + reputationScore, MAX_SCORE) / 2`

### Step 2 — ReputationRegistry  
**File:** `src/ReputationRegistry.sol`

#### `updateScore(Attestation calldata attestation)`
1. `require(block.timestamp <= attestation.deadline, ExpiredDeadline())` — max 10 min future.
2. `bytes32 digest = _buildDigest(attestation)` — uses OZ `_hashTypedDataV4`.
3. `address signer = digest.recover(attestation.signature)` — OZ ECDSA.
4. `require(_authorizedAttestors[signer], InvalidSignature())`.
5. `require(attestation.nonce == _scores[attestation.wallet].nonce + 1, NonceTooLow())` — strictly monotonic.
6. `require(attestation.value <= 10_000, ScoreOutOfRange())`.
7. Write: `_scores[attestation.wallet] = Score({ value: attestation.value, updatedAt: uint64(block.timestamp), nonce: attestation.nonce })`.
8. `emit ScoreUpdated(attestation.wallet, attestation.value, attestation.nonce)`.

#### `reportToxicTrade(address wallet, address pool, uint16 localSeverity)`
1. `require(_authorizedHooks[msg.sender], Unauthorized())`.
2. Bump the score: decay old score then add severity.
   - Simple: `newScore = min(_scores[wallet].value + localSeverity / 2, 10_000)`.
   - Keep nonce unchanged (this is not an attestor-signed update).
3. `emit ToxicTradeReported(wallet, pool, localSeverity, block.timestamp)`.

#### `updateScoreFromReactive(address wallet, uint16 aggregateScore)`
1. `require(msg.sender == reactiveProxy, Unauthorized())`.
2. Take the max of the current score and the aggregate score (cross-pool data only goes up).
3. Update `_scores[wallet].value` and `updatedAt`. Don't touch nonce.

### Step 3 — GlyphHook: `_beforeSwap`  
**File:** `src/GlyphHook.sol`

1. Read score: `uint16 score = registry.scoreOf(tx.origin)`.
2. Compute fee: `uint24 fee = _computeFee(score)` → delegates to `ToxicityScoring.scoreToFee`.
3. Try Pyth: `uint16 impactBps = _estimatePriceImpactBps(key, params)`.
   - If `impactBps >= LOCAL_IMPACT_BP_THRESHOLD`, override to max fee immediately.
4. Store pending fee for `_afterSwap`:
   `_pendingFee[keccak256(abi.encode(key.toId(), tx.origin))] = fee`.
5. Return: `(BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG)`.
   - **Critical:** must OR with `OVERRIDE_FEE_FLAG`. Without it, PoolManager ignores the fee.

### Step 4 — GlyphHook: `_afterSwap`  
**File:** `src/GlyphHook.sol`

1. Recover fee: `uint24 chargedFee = _pendingFee[keccak256(abi.encode(key.toId(), tx.origin))]`.
2. Delete the pending entry to prevent stale reads.
3. If `chargedFee > DEFAULT_BASE_FEE`:
   - Compute excess token amounts from `BalanceDelta`.
   - Call `poolManager.donate(key, excessAmount0, excessAmount1, "")`.
   - Emit `LPDonation(key.toId(), excessAmount0, excessAmount1)`.
4. If locally toxic (stored flag or impactBps > threshold):
   - `uint16 severity = ToxicityScoring.computeSeverity(impactBps, score)`.
   - `registry.reportToxicTrade(tx.origin, address(key.hooks), severity)`.
5. Return `(BaseHook.afterSwap.selector, 0)`.

### Step 5 — `_estimatePriceImpactBps`  
**File:** `src/GlyphHook.sol`

```
1. Load feedIds for the pool: baseFeedId[poolId], quoteFeedId[poolId].
   If either is 0, return 0 (unconfigured pool → skip local check).

2. Call pyth.getPriceNoOlderThan(baseFeedId, MAX_PYTH_STALENESS) → PythStructs.Price base
   Call pyth.getPriceNoOlderThan(quoteFeedId, MAX_PYTH_STALENESS) → PythStructs.Price quote
   Wrap in try/catch — if either reverts (missing update), return 0.

3. Confidence check: if base.conf * 100 > uint64(base.price) → low confidence, return 0.

4. Oracle mid-price (normalize for expo):
   Both prices carry an exponent (base.expo, often negative like -8).
   oraclePrice = base.price * 10^(quote.expo) / (quote.price * 10^(base.expo))
   Use FullMath.mulDiv to avoid overflow.

5. Effective swap price from sqrtPriceX96 (passed via params or fetched from slot0):
   effectivePrice = sqrtPriceX96^2 / 2^192  (for token0/token1 ratio)
   Use FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 192).

6. impactBps = abs(effectivePrice - oraclePrice) * 10_000 / oraclePrice
   Cap at uint16 max.
```

### Step 6 — GlyphHook: CREATE2 address mining  
**File:** `script/DeployGlyph.s.sol` + `test/utils/HookMiner.sol`

- Required flag bits for `beforeSwap + afterSwap`: `Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG`
- Verify: `cast call <addr> "getHookPermissions()"` must show both true.
- The HookMiner iterates salts until the low 14 bits of the CREATE2 address match the flags.

---

## 3. Storage layout rules

**Never reorder storage variables** — any reorder breaks deployed contracts.

```
GlyphHook storage (declared order):
  mapping(PoolId => bytes32) baseFeedId       slot 0
  mapping(PoolId => bytes32) quoteFeedId      slot 1
  mapping(bytes32 => uint24) _pendingFee      slot 2

ReputationRegistry storage:
  mapping(address => Score) _scores            slot 0
  mapping(address => bool)  _authorizedHooks   slot 1
  mapping(address => bool)  _authorizedAttestors slot 2
  address reactiveProxy                        slot 3
```

`Score` struct (packed into one 32-byte slot):
```solidity
struct Score {
    uint16 value;      // bytes 0-1
    uint64 updatedAt;  // bytes 2-9
    uint32 nonce;      // bytes 10-13
    // 18 bytes unused — do not add fields without checking slot usage
}
```

---

## 4. Gas budget

Target: **< 50k overhead** over a vanilla Uniswap v4 swap.

| Operation | Estimated gas |
|---|---|
| `registry.scoreOf()` (warm) | ~2,100 (SLOAD) |
| `ToxicityScoring.scoreToFee()` | ~100 (pure math) |
| Pyth `getPriceNoOlderThan()` | ~10,000–20,000 (external call + SLOAD) |
| Fee override return | ~200 |
| `_pendingFee` SSTORE (beforeSwap) | ~20,000 (cold) / ~2,900 (warm) |
| `_pendingFee` SLOAD + SSTORE=0 (afterSwap) | ~2,900 + ~2,900 |
| `poolManager.donate()` | ~15,000 (conditional) |

Use `forge snapshot` after each step. Commit `.gas-snapshot`. CI fails if beforeSwap grows > 5%.

---

## 5. Security checklist

Before shipping each file, verify:

- [ ] No `tx.origin` used for authorization (only for identity lookup — disclose in deck).
- [ ] EIP-712 nonces are strictly monotonic (`nonce == stored + 1`, not `>=`).
- [ ] Signature deadlines enforced (`<= 10 min` in the future).
- [ ] All signatures verified against `_authorizedAttestors` set, not a single hardcoded key.
- [ ] `uint16 score * uint24 fee` — both cast to `uint256` before multiplication.
- [ ] `PoolManager.donate()` call guarded: only fires when `excessFee > 0`.
- [ ] Pyth oracle missing/stale → graceful skip, never revert user's swap.
- [ ] `setFeedConfig` and `setHook` protected by `onlyOwner`.
- [ ] `updateScoreFromReactive` only callable by `reactiveProxy` address.
- [ ] No external calls to user-supplied addresses inside hook callbacks.

---

## 6. Testing requirements

Minimum test coverage before submission:

| Contract | Required tests |
|---|---|
| ToxicityScoring | `scoreToFee` at 0, max, and fuzz monotonicity; `computeSeverity` bounds |
| ReputationRegistry | EIP-712 happy path, nonce replay revert, expired deadline, unauthorized hook revert, reactive proxy path |
| GlyphHook | Base fee at score=0, elevated fee at score=10k, Pyth mock at 2% deviation, donate event on excess fee, no donate on base fee, toxic trade report, gas snapshot |

Run before every PR:
```bash
forge test -vv
forge test --fuzz-runs 10000 --match-contract ToxicityScoringTest
forge snapshot --check
forge coverage  # target ≥ 80% on src/
```

---

## 7. Deployment sequence (Day 4)

```bash
# 1. Load env
source .env

# 2. Deploy (outputs REGISTRY_ADDRESS and HOOK_ADDRESS)
forge script script/DeployGlyph.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast \
  --verify

# 3. Update .env with printed addresses

# 4. Initialize two pools (write LocalDemo.s.sol for this)
forge script script/LocalDemo.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast

# 5. Off-chain: set REGISTRY_ADDRESS in ai/detector/.env and test
python -m detector.run --wallet <your-test-wallet> --submit
```

---

## 8. Key external references

| Resource | URL |
|---|---|
| Uniswap v4 Hook docs | https://docs.uniswap.org/contracts/v4/overview |
| BaseHook source | lib/v4-periphery/src/base/hooks/BaseHook.sol |
| LPFeeLibrary | lib/v4-core/src/libraries/LPFeeLibrary.sol |
| FullMath | lib/v4-core/src/libraries/FullMath.sol |
| Pyth EVM pull integration | https://docs.pyth.network/price-feeds/use-real-time-data/evm |
| Reactive Network docs | https://docs.reactive.network/ |
| Brevis App SDK | https://coprocessor-docs.brevis.network/ |
| DetoxHook reference | https://github.com/hamiha70/detox-hook |
