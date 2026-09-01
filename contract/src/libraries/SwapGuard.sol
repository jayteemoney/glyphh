// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  SwapGuard
/// @notice Transient storage for state that has to survive from `beforeSwap` to `afterSwap`.
///
/// @dev    v1 kept this in a persistent mapping keyed on `(poolId, tx.origin)`, which had two
///         problems. It paid a cold SSTORE and a delete on every single swap for data whose
///         entire lifetime is one call frame; and, worse, a multi-hop route touching the same
///         pool twice in one transaction collided on that key, so the second leg read the
///         first leg's fee.
///
///         EIP-1153 transient storage is exactly the right primitive: written and read within
///         one transaction, discarded automatically at the end of it, no refund mechanics and
///         no cross-transaction leakage. The remaining collision — the same swapper hitting the
///         same pool twice in one transaction — is closed by folding a per-transaction sequence
///         number into the slot, so each leg gets its own.
///
///         Note this is deliberately *not* the mechanism used for sandwich detection. A
///         sandwich's legs are separate transactions in the same block, and transient storage
///         cannot see across them; that state has to be persistent. See `GlyphHook`.
library SwapGuard {
    /// @dev Namespaced so a slot can never alias another library's transient storage.
    bytes32 private constant PENDING_SEED = keccak256("glyph.v2.swapguard.pending");
    bytes32 private constant DEPTH_SLOT = keccak256("glyph.v2.swapguard.depth");

    /// @notice Fee and detection state carried across one swap's two callbacks.
    struct Pending {
        uint24 fee; // the LP fee quoted in beforeSwap
        uint16 divergenceBps; // measured pool-vs-oracle divergence
        bool toxic; // whether this swap tripped the toxicity threshold
        bool sandwichClose; // whether this is the closing leg of a sandwich
        address victim; // who to credit, when sandwichClose is set
    }

    /// @notice Increment and return the current leg index within this transaction.
    /// @dev    Makes each leg of a multi-hop route address a distinct slot.
    function nextLeg() internal returns (uint256 leg) {
        bytes32 slot = DEPTH_SLOT;
        assembly ("memory-safe") {
            leg := add(tload(slot), 1)
            tstore(slot, leg)
        }
    }

    /// @notice The leg index most recently allocated in this transaction.
    /// @dev    `afterSwap` runs inside the same call frame as its `beforeSwap`, so the current
    ///         value is always the leg being settled.
    function currentLeg() internal view returns (uint256 leg) {
        bytes32 slot = DEPTH_SLOT;
        assembly ("memory-safe") {
            leg := tload(slot)
        }
    }

    function store(uint256 leg, Pending memory p) internal {
        (bytes32 slotA, bytes32 slotB) = _slots(leg);
        uint256 packed = uint256(p.fee) | (uint256(p.divergenceBps) << 24) | (uint256(p.toxic ? 1 : 0) << 40)
            | (uint256(p.sandwichClose ? 1 : 0) << 41);
        uint256 victim = uint256(uint160(p.victim));
        assembly ("memory-safe") {
            tstore(slotA, packed)
            tstore(slotB, victim)
        }
    }

    function load(uint256 leg) internal view returns (Pending memory p) {
        (bytes32 slotA, bytes32 slotB) = _slots(leg);
        uint256 packed;
        uint256 victim;
        assembly ("memory-safe") {
            packed := tload(slotA)
            victim := tload(slotB)
        }
        // Safe: fee occupies bits 0-23 of the packed word by construction in store().
        // forge-lint: disable-next-line(unsafe-typecast)
        p.fee = uint24(packed);
        // Safe: divergenceBps occupies bits 24-39 of the packed word by construction in store().
        // forge-lint: disable-next-line(unsafe-typecast)
        p.divergenceBps = uint16(packed >> 24);
        p.toxic = ((packed >> 40) & 1) == 1;
        p.sandwichClose = ((packed >> 41) & 1) == 1;
        // Safe: victim was stored as a whole word holding a 160-bit address.
        // forge-lint: disable-next-line(unsafe-typecast)
        p.victim = address(uint160(victim));
    }

    function _slots(uint256 leg) private pure returns (bytes32 slotA, bytes32 slotB) {
        slotA = keccak256(abi.encode(PENDING_SEED, leg));
        slotB = bytes32(uint256(slotA) + 1);
    }
}
