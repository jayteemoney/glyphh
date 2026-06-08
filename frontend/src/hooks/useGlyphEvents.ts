"use client";
/* eslint-disable @typescript-eslint/no-explicit-any */

import { useState } from "react";
import { useWatchContractEvent } from "wagmi";
import { REGISTRY_ADDRESS, HOOK_ADDRESS, registryAbi, hookAbi } from "@/config/contracts";

export type ScoreRow = {
  wallet: `0x${string}`;
  score: number;
  nonce: number;
  updatedAt: number;
};

export type ToxicTrade = {
  wallet: `0x${string}`;
  pool: `0x${string}`;
  severity: number;
  timestamp: number;
  txHash?: string;
};

export type Donation = { amount0: bigint; amount1: bigint; txHash?: string };

const registryReady = Boolean(REGISTRY_ADDRESS);
const hookReady = Boolean(HOOK_ADDRESS);

/// Streams Glyph's three live signals — score updates, toxic-trade reports, and LP
/// donations — into React state. Watching the single ReputationRegistry captures every
/// pool at once (all hooks report to it), which is exactly the cross-pool property Glyph
/// is built around.
export function useGlyphEvents() {
  const [scores, setScores] = useState<Record<string, ScoreRow>>({});
  const [toxicTrades, setToxicTrades] = useState<ToxicTrade[]>([]);
  const [donations, setDonations] = useState<Donation[]>([]);

  useWatchContractEvent({
    address: registryReady ? (REGISTRY_ADDRESS as `0x${string}`) : undefined,
    abi: registryAbi,
    eventName: "ScoreUpdated",
    enabled: registryReady,
    poll: true,
    pollingInterval: 4_000,
    onLogs(logs: any[]) {
      setScores((prev) => {
        const next = { ...prev };
        for (const l of logs) {
          const w = String(l.args.wallet);
          next[w.toLowerCase()] = {
            wallet: w as `0x${string}`,
            score: Number(l.args.value),
            nonce: Number(l.args.nonce),
            updatedAt: Math.floor(Date.now() / 1000),
          };
        }
        return next;
      });
    },
  });

  useWatchContractEvent({
    address: registryReady ? (REGISTRY_ADDRESS as `0x${string}`) : undefined,
    abi: registryAbi,
    eventName: "ToxicTradeReported",
    enabled: registryReady,
    poll: true,
    pollingInterval: 4_000,
    onLogs(logs: any[]) {
      const mapped: ToxicTrade[] = logs.map((l) => ({
        wallet: l.args.wallet,
        pool: l.args.pool,
        severity: Number(l.args.localSeverity),
        timestamp: Number(l.args.timestamp),
        txHash: l.transactionHash,
      }));
      setToxicTrades((prev) => [...mapped.reverse(), ...prev].slice(0, 50));
    },
  });

  useWatchContractEvent({
    address: hookReady ? (HOOK_ADDRESS as `0x${string}`) : undefined,
    abi: hookAbi,
    eventName: "LPDonation",
    enabled: hookReady,
    poll: true,
    pollingInterval: 4_000,
    onLogs(logs: any[]) {
      const mapped: Donation[] = logs.map((l) => ({
        amount0: l.args.amount0 as bigint,
        amount1: l.args.amount1 as bigint,
        txHash: l.transactionHash,
      }));
      setDonations((prev) => [...mapped, ...prev].slice(0, 100));
    },
  });

  return {
    scores: Object.values(scores).sort((a, b) => b.score - a.score),
    toxicTrades,
    donations,
    configured: registryReady,
  };
}
