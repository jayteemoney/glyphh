"use client";

// Backwards-compatible alias. The live toxic-trade stream is part of the unified
// useGlyphEvents() hook, which watches score updates, toxic trades, and LP donations
// from the single ReputationRegistry (every pool at once).
export { useGlyphEvents } from "./useGlyphEvents";
export type { ToxicTrade } from "./useGlyphEvents";
