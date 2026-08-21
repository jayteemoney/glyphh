"use client";
/* eslint-disable @typescript-eslint/no-explicit-any */

import { useEffect, useRef, useState } from "react";
import { usePublicClient, useWatchContractEvent } from "wagmi";
import { parseAbiItem } from "viem";
import { REGISTRY_ADDRESS, HOOK_ADDRESS, registryAbi, hookAbi } from "@/config/contracts";
import { getLogsChunked } from "@/lib/logs";

export type ScoreRow = {
  wallet: `0x${string}`;
  score: number;       // current effective (decay-adjusted) toxicity
  trust: number;       // current effective (decay-adjusted) earned trust
  nonce: number;
  updatedAt: number;
};

export type ToxicTrade = {
  wallet: `0x${string}`;
  /** v2: the real PoolId. v1 put the hook's own address here, so pools were
   *  indistinguishable and "cross-pool" could not actually be counted. */
  poolId: `0x${string}`;
  severity: number;
  timestamp: number;
  txHash?: string;
  /** "pool" = on-chain ToxicSwapReported; "detector" = high ScoreUpdated attestation */
  source: "pool" | "detector";
};

export type Sandwich = {
  attacker: `0x${string}`;
  victim: `0x${string}`;
  currency: `0x${string}`;
  rebate: bigint;
  txHash?: string;
};

const registryReady = Boolean(REGISTRY_ADDRESS);
const hookReady = Boolean(HOOK_ADDRESS);

// A ScoreUpdated at/above this value is surfaced in the toxic-activity feed as a
// detector flag (matches the keeper's submit threshold).
const DETECTOR_FLAG_THRESHOLD = 2_500;

const scoreUpdatedEvent = parseAbiItem(
  "event ScoreUpdated(address indexed wallet, uint16 value, uint32 nonce)",
);
const toxicSwapEvent = parseAbiItem(
  "event ToxicSwapReported(address indexed wallet, bytes32 indexed poolId, uint16 severity, uint256 timestamp)",
);
const sandwichEvent = parseAbiItem(
  "event SandwichDetected(bytes32 indexed poolId, address indexed attacker, address indexed victim, address currency, uint256 rebate)",
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
  const [sandwiches, setSandwiches] = useState<Sandwich[]>([]);
  const seen = useRef<Set<string>>(new Set());
  const client = usePublicClient();

  /** Read the live decayed score + metadata for a wallet and upsert its row. */
  async function refreshWallet(wallet: `0x${string}`) {
    if (!client || !registryReady) return;
    try {
      const [score, trust, data] = await Promise.all([
        client.readContract({
          address: REGISTRY_ADDRESS as `0x${string}`,
          abi: registryAbi,
          functionName: "scoreOf",
          args: [wallet],
        }),
        client.readContract({
          address: REGISTRY_ADDRESS as `0x${string}`,
          abi: registryAbi,
          functionName: "trustOf",
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
          trust: Number(trust),
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
      const blockTs = new Map<bigint, number>();
      const tsOf = async (bn: bigint) => {
        if (!blockTs.has(bn)) {
          const b = await client.getBlock({ blockNumber: bn });
          blockTs.set(bn, Number(b.timestamp));
        }
        return blockTs.get(bn)!;
      };

      try {
        const [scoreLogs, toxicLogs, sandwichLogs] = await Promise.all([
          getLogsChunked({
            client,
            address: REGISTRY_ADDRESS as `0x${string}`,
            event: scoreUpdatedEvent,
            enough: 50,
          }),
          getLogsChunked({
            client,
            address: REGISTRY_ADDRESS as `0x${string}`,
            event: toxicSwapEvent,
            enough: 50,
          }),
          hookReady
            ? getLogsChunked({
                client,
                address: HOOK_ADDRESS as `0x${string}`,
                event: sandwichEvent,
                enough: 50,
              })
            : Promise.resolve([] as any[]),
        ]);
        if (cancelled) return;

        // Current decayed score per wallet (not the stale event value)
        const wallets = new Set<string>(scoreLogs.map((l) => String(l.args.wallet)));
        await Promise.all([...wallets].map((w) => refreshWallet(w as `0x${string}`)));

        for (const l of toxicLogs) {
          pushFlag(
            {
              wallet: l.args.wallet as `0x${string}`,
              poolId: l.args.poolId as `0x${string}`,
              severity: Number(l.args.severity),
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
              poolId: ("0x" + "0".repeat(64)) as `0x${string}`,
              severity: value,
              timestamp: await tsOf(l.blockNumber),
              txHash: l.transactionHash,
              source: "detector",
            },
            logKey(l),
          );
        }

        const backfilled: Sandwich[] = [];
        for (const l of sandwichLogs) {
          const key = logKey(l);
          if (seen.current.has(key)) continue;
          seen.current.add(key);
          backfilled.push({
            attacker: l.args.attacker as `0x${string}`,
            victim: l.args.victim as `0x${string}`,
            currency: l.args.currency as `0x${string}`,
            rebate: l.args.rebate as bigint,
            txHash: l.transactionHash,
          });
        }
        if (backfilled.length) setSandwiches((prev) => [...backfilled, ...prev].slice(0, 100));
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
              poolId: ("0x" + "0".repeat(64)) as `0x${string}`,
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
    eventName: "ToxicSwapReported",
    enabled: registryReady,
    poll: true,
    pollingInterval: 4_000,
    onLogs(logs: any[]) {
      for (const l of logs) {
        pushFlag(
          {
            wallet: l.args.wallet,
            poolId: l.args.poolId,
            severity: Number(l.args.severity),
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
    eventName: "SandwichDetected",
    enabled: hookReady,
    poll: true,
    pollingInterval: 4_000,
    onLogs(logs: any[]) {
      const fresh = logs.filter((l) => !seen.current.has(logKey(l)));
      for (const l of fresh) seen.current.add(logKey(l));
      if (!fresh.length) return;
      const mapped: Sandwich[] = fresh.map((l) => ({
        attacker: l.args.attacker as `0x${string}`,
        victim: l.args.victim as `0x${string}`,
        currency: l.args.currency as `0x${string}`,
        rebate: l.args.rebate as bigint,
        txHash: l.transactionHash,
      }));
      setSandwiches((prev) => [...mapped, ...prev].slice(0, 100));
    },
  });

  // Distinct pools a wallet has been flagged in. This is the cross-pool claim made
  // countable: the RSC only propagates a wallet seen in two or more pools, and this is
  // the same figure rendered for a reader.
  const poolsByWallet: Record<string, number> = {};
  for (const t of toxicTrades) {
    if (t.source !== "pool") continue;
    const w = t.wallet.toLowerCase();
    (poolsByWallet[w] ??= 0);
  }
  const distinct: Record<string, Set<string>> = {};
  for (const t of toxicTrades) {
    if (t.source !== "pool") continue;
    const w = t.wallet.toLowerCase();
    (distinct[w] ??= new Set()).add(t.poolId);
  }
  for (const w of Object.keys(distinct)) poolsByWallet[w] = distinct[w].size;

  return {
    scores: Object.values(scores).sort((a, b) => b.score - a.score),
    toxicTrades,
    sandwiches,
    poolsByWallet,
    configured: registryReady,
  };
}
