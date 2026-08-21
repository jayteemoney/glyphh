"use client";
/* eslint-disable @typescript-eslint/no-explicit-any */

import { useEffect, useRef, useState } from "react";
import { usePublicClient, useWatchContractEvent } from "wagmi";
import { parseAbiItem } from "viem";
import { HOOK_ADDRESS, hookAbi } from "@/config/contracts";
import { getLogsChunked } from "@/lib/logs";

/** One fee quote, with every term the hook charged, in Uniswap pips (1_000_000 = 100%). */
export type FeeQuote = {
  poolId: `0x${string}`;
  swapper: `0x${string}`;
  base: number;
  arb: number;
  unproven: number;
  toxic: number;
  trustDiscount: number;
  final: number;
  blockNumber: number;
  txHash?: string;
};

const hookReady = Boolean(HOOK_ADDRESS);

const MAX_QUOTES = 100;

const feeQuotedEvent = parseAbiItem(
  "event FeeQuoted(bytes32 indexed poolId, address indexed swapper, uint24 baseFee, uint24 arbPremium, uint24 unprovenPremium, uint24 toxicPremium, uint24 trustDiscount, uint24 finalFee)",
);

const logKey = (l: any) => `${l.transactionHash}:${l.logIndex}`;

function toQuote(log: any): FeeQuote {
  const a = log.args ?? {};
  return {
    poolId: a.poolId,
    swapper: a.swapper,
    base: Number(a.baseFee ?? 0),
    arb: Number(a.arbPremium ?? 0),
    unproven: Number(a.unprovenPremium ?? 0),
    toxic: Number(a.toxicPremium ?? 0),
    trustDiscount: Number(a.trustDiscount ?? 0),
    final: Number(a.finalFee ?? 0),
    blockNumber: Number(log.blockNumber ?? 0),
    txHash: log.transactionHash,
  };
}

/**
 * Streams the hook's `FeeQuoted` events — the decomposed price of every swap.
 *
 * This is the dashboard's most useful signal and it exists because the hook emits each
 * term separately rather than a single number. It lets the UI answer the only question a
 * trader actually has when a fee is not the one they expected: *which layer charged me?*
 *
 * It is also how the demo shows the thesis without narration. Two swaps in the same pool
 * at the same divergence, one closing the gap and one widening it, produce visibly
 * different rows — the arb premium is present in one and zero in the other.
 */
export function useFeeQuotes() {
  const [quotes, setQuotes] = useState<FeeQuote[]>([]);
  const seen = useRef<Set<string>>(new Set());
  const publicClient = usePublicClient();

  const push = (incoming: FeeQuote[]) => {
    if (incoming.length === 0) return;
    setQuotes((prev) => [...incoming, ...prev].slice(0, MAX_QUOTES));
  };

  // Backfill recent history so the page is populated before the next swap lands.
  useEffect(() => {
    if (!hookReady || !publicClient) return;
    let cancelled = false;

    (async () => {
      try {
        const logs = await getLogsChunked({
          client: publicClient,
          address: HOOK_ADDRESS as `0x${string}`,
          event: feeQuotedEvent,
          enough: MAX_QUOTES,
        });
        if (cancelled) return;

        const fresh: FeeQuote[] = [];
        for (const log of logs) {
          const k = logKey(log);
          if (seen.current.has(k)) continue;
          seen.current.add(k);
          fresh.push(toQuote(log));
        }
        // Newest first.
        fresh.sort((a, b) => b.blockNumber - a.blockNumber);
        push(fresh);
      } catch {
        // A backfill failure is not fatal — the live watcher below still populates the
        // feed from the next swap onward.
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [publicClient]);

  useWatchContractEvent({
    address: hookReady ? (HOOK_ADDRESS as `0x${string}`) : undefined,
    abi: hookAbi,
    eventName: "FeeQuoted",
    enabled: hookReady,
    onLogs: (logs) => {
      const fresh: FeeQuote[] = [];
      for (const log of logs as any[]) {
        const k = logKey(log);
        if (seen.current.has(k)) continue;
        seen.current.add(k);
        fresh.push(toQuote(log));
      }
      push(fresh);
    },
  });

  return { quotes, configured: hookReady };
}
