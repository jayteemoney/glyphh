// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  FlowRisk
/// @notice The Glyph v2 fee model: pure functions that price a swap by how extractive it is,
///         then discount it by how well the swapper has behaved.
///
/// @dev    Glyph v1 priced swaps on reputation alone, which had a structural flaw: the clean
///         state was the *default*, so it was free, and an attacker reset the game by rotating
///         to a fresh EOA. v2 fixes this by layering three defences, deliberately ordered from
///         identity-free to identity-dependent:
///
///           L1  arbPremium       — identity-free. Prices LVR capture directly, from the pool's
///                                  divergence against an oracle and the swap's direction. A
///                                  brand-new wallet pays this on its very first trade.
///           L2  (sandwich)       — identity-free within a block; lives in GlyphHook, not here.
///           L3a unprovenPremium  — what an unknown identity pays for an extractive-*shaped*
///                                  swap. Small swaps pay nothing, so retail is untouched.
///           L3b toxicPremium     — what a known-toxic identity pays, on the v1 score curve.
///           L3c trustDiscount    — what proven-benign history *earns*: the fee falls below
///                                  base, down to FLOOR_FEE.
///
///         The security property this buys: reputation is now only ever a discount. Rotating
///         wallets no longer returns an attacker to "free" — it returns them to "unproven",
///         and it discards trust that took real volume to accumulate. Even if the identity
///         layer is sybilled completely, L1 and L2 still fire.
library FlowRisk {
    // ── Fee bounds (hundredths of a bip: 3_000 = 0.30%) ───────────────────────

    /// @notice The floor a maximally-trusted swapper reaches. This is the headline of the
    ///         model: a 0.30% pool that quotes 0.05% to flow that has proven it is benign,
    ///         funded by what extractive flow pays.
    uint24 internal constant FLOOR_FEE = 500; // 0.05%
    uint24 internal constant BASE_FEE = 3_000; // 0.30%
    uint24 internal constant MAX_FEE = 100_000; // 10.00%

    uint16 internal constant MAX_SCORE = 10_000;

    // ── L1: directional arbitrage premium ─────────────────────────────────────

    /// @notice Divergence below this is never surcharged.
    /// @dev    Set from evidence, not from intuition. The obvious reading of this constant is
    ///         "oracle noise", which argues for something small — v2 shipped 10 bps on exactly
    ///         that reasoning. Replaying 30 days of real ETH/USD through the model
    ///         (`ai/backtest/lvr.py`) showed why that is wrong.
    ///
    ///         A pool's no-arbitrage band is set by its *base fee*: below 30 bps of divergence
    ///         no rational arbitrageur trades at all, because the gap does not cover the fee.
    ///         So a tolerance inside that band cannot catch arbitrage — there is none to catch
    ///         — and lands solely on uninformed swaps that happen to move toward the reference,
    ///         which is roughly half of them. Measured: at 10 bps, **44% of uninformed swaps**
    ///         paid a premium. At 40 bps, 1.6% do, and the pool still keeps 82% of gross
    ///         arbitrage instead of 90%.
    ///
    ///         40 = BASE_FEE (30 bps) + a 10 bp cushion, because the arbitrageur's own trade
    ///         leaves the price sitting on the band edge and uninformed flow jitters it across.
    ///         See `docs/BACKTEST.md` for the sweep this came from.
    uint256 internal constant ARB_TOLERANCE_BPS = 40; // 0.40% = base fee + cushion

    /// @notice Share of the arbitrage the pool claws back, in percent. At 60, a swap closing
    ///         a 50 bp gap is charged 0.60 * 40 bp = 24 bp on top of base.
    uint256 internal constant ARB_CAPTURE_PCT = 60;

    /// @notice Ceiling on L1 alone, so an extreme or broken oracle reading cannot by itself
    ///         price a pool out of existence.
    uint24 internal constant ARB_PREMIUM_CAP = 50_000; // 5.00%

    /// @notice Price the LVR this swap is capturing.
    /// @param  divergenceBps  |pool - oracle| / oracle in bps, measured *before* the swap.
    /// @param  closesGap      Whether the swap moves the pool toward the oracle price.
    /// @return premium        Fee units to add on top of base.
    ///
    /// @dev    Direction is the whole point. A swap that moves the pool *toward* the oracle is
    ///         capturing the divergence — that is the textbook definition of the arbitrage LPs
    ///         lose to. A swap that moves the pool *away* is uninformed flow, which is the
    ///         order flow LPs actually want, and it is never surcharged here no matter how
    ///         large it is or who sends it.
    function arbPremium(uint256 divergenceBps, bool closesGap) internal pure returns (uint24 premium) {
        if (!closesGap) return 0;
        if (divergenceBps <= ARB_TOLERANCE_BPS) return 0;

        unchecked {
            uint256 excessBps = divergenceBps - ARB_TOLERANCE_BPS;
            // 1 bp == 100 fee units; charging ARB_CAPTURE_PCT percent of the excess gives
            // excessBps * 100 * pct / 100 == excessBps * pct.
            uint256 raw = excessBps * ARB_CAPTURE_PCT;
            // Safe: raw is clamped to ARB_PREMIUM_CAP, which fits uint24.
            // forge-lint: disable-next-line(unsafe-typecast)
            premium = raw > ARB_PREMIUM_CAP ? ARB_PREMIUM_CAP : uint24(raw);
        }
    }

    // ── L3a: unproven-identity premium ────────────────────────────────────────

    /// @notice Swaps at or below this share of in-range liquidity are free for everyone,
    ///         proven or not. This is the retail carve-out: it is what stops the inversion
    ///         from becoming a tax on ordinary traders.
    uint256 internal constant UNPROVEN_FREE_SIZE_BPS = 50; // 0.50% of in-range liquidity

    /// @notice Fee units charged per bp of size above the free band.
    uint256 internal constant UNPROVEN_SLOPE = 40;

    /// @notice Ceiling on L3a alone.
    uint24 internal constant UNPROVEN_CAP = 20_000; // 2.00%

    /// @notice What an identity with no established record pays for a large swap.
    /// @param  sizeBps Swap notional as bps of the pool's in-range liquidity.
    ///
    /// @dev    Scaling on size is what keeps this honest. The burden of proof rises with how
    ///         much the swap could extract: a 0.1 ETH swap from a wallet seen for the first
    ///         time pays nothing extra, while a swap worth 5% of in-range liquidity from that
    ///         same wallet pays close to the cap. An attacker cannot rotate away from this,
    ///         because rotating *is* the condition that triggers it.
    function unprovenPremium(uint256 sizeBps) internal pure returns (uint24 premium) {
        if (sizeBps <= UNPROVEN_FREE_SIZE_BPS) return 0;

        unchecked {
            uint256 raw = (sizeBps - UNPROVEN_FREE_SIZE_BPS) * UNPROVEN_SLOPE;
            // Safe: raw is clamped to UNPROVEN_CAP, which fits uint24.
            // forge-lint: disable-next-line(unsafe-typecast)
            premium = raw > UNPROVEN_CAP ? UNPROVEN_CAP : uint24(raw);
        }
    }

    // ── L3b: toxicity premium (the v1 curve, re-expressed as a premium) ───────

    /// @notice Premium owed by a wallet carrying toxicity score `score`.
    /// @dev    Deliberately the same three-segment curve Glyph v1 shipped and tested, so the
    ///         reputation path's behaviour is unchanged; only its role has changed. It is now
    ///         one term in a sum rather than the entire fee.
    function toxicPremium(uint16 score) internal pure returns (uint24 premium) {
        if (score == 0) return 0;
        if (score >= MAX_SCORE) return MAX_FEE - BASE_FEE;

        uint256 s = score;
        uint256 f;
        if (s < 2_500) {
            f = 3_000 + (s * 7_000) / 2_500;
        } else if (s < 7_500) {
            f = 10_000 + ((s - 2_500) * 30_000) / 5_000;
        } else {
            f = 40_000 + ((s - 7_500) * 60_000) / 2_500;
        }
        // Safe: f peaks at 100_000 on the branch above, so f - BASE_FEE fits uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        premium = uint24(f - BASE_FEE);
    }

    // ── L3c: earned trust discount ────────────────────────────────────────────

    /// @notice How far proven-benign history buys the fee down from base toward the floor.
    /// @param  trust 0..MAX_SCORE, attested by the detector from settled benign volume.
    /// @dev    Linear, and capped by construction at BASE_FEE - FLOOR_FEE so trust alone can
    ///         never drive the fee below the floor.
    function trustDiscount(uint16 trust) internal pure returns (uint24 discount) {
        if (trust == 0) return 0;
        if (trust >= MAX_SCORE) return BASE_FEE - FLOOR_FEE;
        return uint24((uint256(trust) * (BASE_FEE - FLOOR_FEE)) / MAX_SCORE);
    }

    // ── Assembly ──────────────────────────────────────────────────────────────

    /// @notice Everything the model needs to price one swap.
    struct Inputs {
        uint256 divergenceBps; // pool vs oracle, before the swap (0 if no oracle available)
        bool closesGap; // does this swap move the pool toward the oracle?
        uint256 sizeBps; // swap notional as bps of in-range liquidity
        uint16 score; // toxicity, 0..10_000
        uint16 trust; // proven-benign, 0..10_000
    }

    /// @notice Assemble the final LP fee for a swap.
    /// @dev    Sum the premiums, subtract the earned discount, clamp to [FLOOR_FEE, MAX_FEE].
    ///         The unproven premium applies only to identities with no established trust —
    ///         once a wallet has earned any trust at all it has, by definition, a record.
    function assembleFee(Inputs memory i) internal pure returns (uint24 fee) {
        uint256 f = BASE_FEE;

        f += arbPremium(i.divergenceBps, i.closesGap);
        if (i.trust == 0) f += unprovenPremium(i.sizeBps);
        f += toxicPremium(i.score);

        uint256 d = trustDiscount(i.trust);
        f = f > d ? f - d : FLOOR_FEE;

        if (f < FLOOR_FEE) return FLOOR_FEE;
        if (f > MAX_FEE) return MAX_FEE;
        // Safe: f is clamped to [FLOOR_FEE, MAX_FEE] by the two checks above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(f);
    }
}
