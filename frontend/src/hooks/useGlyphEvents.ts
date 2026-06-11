"use client";
/* eslint-disable @typescript-eslint/no-explicit-any */

import { useEffect, useRef, useState } from "react";
import { usePublicClient, useWatchContractEvent } from "wagmi";
import { parseAbiItem } from "viem";
import { REGISTRY_ADDRESS, HOOK_ADDRESS, registryAbi, hookAbi } from "@/config/contracts";

export type ScoreRow = {
  wallet: `0x${string}`;
  score: number;       // current effective (decay-adjusted) score
  nonce: number;
  updatedAt: number;
};

export type ToxicTrade = {
  wallet: `0x${string}`;
  pool: `0x${string}`;
  severity: number;
  timestamp: number;
  txHash?: string;
  /** "pool" = on-chain ToxicTradeReported; "detector" = high ScoreUpdated attestation */
  source: "pool" | "detector";
};

export type Donation = { amount0: bigint; amount1: bigint; txHash?: string };

const registryReady = Boolean(REGISTRY_ADDRESS);
const hookReady = Boolean(HOOK_ADDRESS);

// A ScoreUpdated at/above this value is surfaced in the toxic-activity feed as a
// detector flag (matches the keeper's submit threshold).
const DETECTOR_FLAG_THRESHOLD = 2_500;

// How far back the initial backfill scans. ~1 week of Unichain's 1s blocks; the
// public RPC serves address-filtered ranges this large in one call.
const BACKFILL_BLOCKS = BigInt(process.env.NEXT_PUBLIC_BACKFILL_BLOCKS ?? "600000");

const scoreUpdatedEvent = parseAbiItem(
  "event ScoreUpdated(address indexed wallet, uint16 value, uint32 nonce)",
);
const toxicTradeEvent = parseAbiItem(
  "event ToxicTradeReported(address indexed wallet, address indexed pool, uint16 localSeverity, uint256 timestamp)",
);
const lpDonationEvent = parseAbiItem(
  "event LPDonation(bytes32 indexed poolId, uint256 amount0, uint256 amount1)",
);

const logKey = (l: any) => `${l.transactionHash}:${l.logIndex}`;

/// Streams Glyph's three live signals — score updates, toxic-trade reports, and LP
/// donations — into React state. On mount it backfills recent history from the chain,
/// then keeps watching. Watching the single ReputationRegistry captures every pool at
/// once (all hooks report to it), which is exactly the cross-pool property Glyph is
/// built around. Scores shown are re-read from `scoreOf` so the 7-day decay is live.
export function useGlyphEvents() {
  const [scores, setScores] = useState<Record<string, ScoreRow>>({});
  const [toxicTrades, setToxicTrades] = useState<ToxicTrade[]>([]);
  const [donations, setDonations] = useState<Donation[]>([]);
  const seen = useRef<Set<string>>(new Set());
  const client = usePublicClient();

  /** Read the live decayed score + metadata for a wallet and upsert its row. */
  async function refreshWallet(wallet: `0x${string}`) {
    if (!client || !registryReady) return;
    try {
      const [score, data] = await Promise.all([
        client.readContract({
          address: REGISTRY_ADDRESS as `0x${string}`,
          abi: registryAbi,
          functionName: "scoreOf",
          args: [wallet],
        }),
        client.readContract({
          address: REGISTRY_ADDRESS as `0x${string}`,
          abi: registryAbi,
          functionName: "scoreDataOf",
          args: [wallet],
        }),
      ]);
      setScores((prev) => ({
        ...prev,
        [wallet.toLowerCase()]: {
          wallet,
          score: Number(score),
          nonce: Number((data as any).nonce),
          updatedAt: Number((data as any).updatedAt),
        },
      }));
    } catch {
      // transient RPC failure — the next poll/refresh will catch up
    }
  }

  function pushFlag(trade: ToxicTrade, key: string) {
    if (seen.current.has(key)) return;
    seen.current.add(key);
    setToxicTrades((prev) =>
      [trade, ...prev].sort((a, b) => b.timestamp - a.timestamp).slice(0, 50),
    );
  }

  // ── Initial backfill ──────────────────────────────────────────────────────
  useEffect(() => {
    if (!client || !registryReady) return;
    let cancelled = false;

    (async () => {
      const latest = await client.getBlockNumber();
      const fromBlock = latest > BACKFILL_BLOCKS ? latest - BACKFILL_BLOCKS : BigInt(0);
      const blockTs = new Map<bigint, number>();
      const tsOf = async (bn: bigint) => {
        if (!blockTs.has(bn)) {
          const b = await client.getBlock({ blockNumber: bn });
          blockTs.set(bn, Number(b.timestamp));
        }
        return blockTs.get(bn)!;
      };

      try {
        const [scoreLogs, toxicLogs, donationLogs] = await Promise.all([
          client.getLogs({
            address: REGISTRY_ADDRESS as `0x${string}`,
            event: scoreUpdatedEvent,
            fromBlock,
            toBlock: latest,
          }),
          client.getLogs({
            address: REGISTRY_ADDRESS as `0x${string}`,
            event: toxicTradeEvent,
            fromBlock,
            toBlock: latest,
          }),
          hookReady
            ? client.getLogs({
                address: HOOK_ADDRESS as `0x${string}`,
                event: lpDonationEvent,
                fromBlock,
                toBlock: latest,
              })
            : Promise.resolve([]),
        ]);
        if (cancelled) return;

        // Current decayed score per wallet (not the stale event value)
        const wallets = new Set<string>(scoreLogs.map((l) => String(l.args.wallet)));
        await Promise.all([...wallets].map((w) => refreshWallet(w as `0x${string}`)));

        for (const l of toxicLogs) {
          pushFlag(
            {
              wallet: l.args.wallet as `0x${string}`,
              pool: l.args.pool as `0x${string}`,
              severity: Number(l.args.localSeverity),
              timestamp: Number(l.args.timestamp),
              txHash: l.transactionHash,
              source: "pool",
            },
            logKey(l),
          );
        }
        for (const l of scoreLogs) {
          const value = Number(l.args.value);
          if (value < DETECTOR_FLAG_THRESHOLD) continue;
          pushFlag(
            {
              wallet: l.args.wallet as `0x${string}`,
              pool: REGISTRY_ADDRESS as `0x${string}`,
              severity: value,
              timestamp: await tsOf(l.blockNumber),
              txHash: l.transactionHash,
              source: "detector",
            },
            logKey(l),
          );
        }

        const backfilled: Donation[] = [];
        for (const l of donationLogs) {
          const key = logKey(l);
          if (seen.current.has(key)) continue;
          seen.current.add(key);
          backfilled.push({
            amount0: l.args.amount0 as bigint,
            amount1: l.args.amount1 as bigint,
            txHash: l.transactionHash,
          });
        }
        if (backfilled.length) setDonations((prev) => [...backfilled, ...prev].slice(0, 100));
      } catch {
        // backfill is best-effort; the live watchers below still stream new events
      }
    })();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client]);

  // ── Live decay: periodically re-read scoreOf for known wallets ───────────
  useEffect(() => {
    if (!registryReady) return;
    const id = setInterval(() => {
      for (const row of Object.values(scores)) refreshWallet(row.wallet);
    }, 30_000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [Object.keys(scores).join(",")]);

  // ── Live watchers ─────────────────────────────────────────────────────────
  useWatchContractEvent({
    address: registryReady ? (REGISTRY_ADDRESS as `0x${string}`) : undefined,
    abi: registryAbi,
    eventName: "ScoreUpdated",
    enabled: registryReady,
    poll: true,
    pollingInterval: 4_000,
    onLogs(logs: any[]) {
      for (const l of logs) {
        const wallet = String(l.args.wallet) as `0x${string}`;
        refreshWallet(wallet);
        const value = Number(l.args.value);
        if (value >= DETECTOR_FLAG_THRESHOLD) {
          pushFlag(
            {
              wallet,
              pool: REGISTRY_ADDRESS as `0x${string}`,
              severity: value,
              timestamp: Math.floor(Date.now() / 1000),
              txHash: l.transactionHash,
              source: "detector",
            },
            logKey(l),
          );
        }
      }
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
      for (const l of logs) {
        pushFlag(
          {
            wallet: l.args.wallet,
            pool: l.args.pool,
            severity: Number(l.args.localSeverity),
            timestamp: Number(l.args.timestamp),
            txHash: l.transactionHash,
            source: "pool",
          },
          logKey(l),
        );
      }
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
      const fresh = logs.filter((l) => !seen.current.has(logKey(l)));
      for (const l of fresh) seen.current.add(logKey(l));
      if (!fresh.length) return;
      const mapped: Donation[] = fresh.map((l) => ({
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
