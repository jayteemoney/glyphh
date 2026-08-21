"use client";

import { useAccount } from "wagmi";
import { useMounted } from "@/hooks/useMounted";
import { useGlyphEvents } from "@/hooks/useGlyphEvents";
import { useFeeQuotes } from "@/hooks/useFeeQuotes";
import { useReputationScore } from "@/hooks/useReputationScore";
import { ScoreTable } from "@/components/dashboard/ScoreTable";
import { ToxicTradesFeed } from "@/components/dashboard/ToxicTradesFeed";
import { PoolStats } from "@/components/dashboard/PoolStats";
import { FeeBreakdown } from "@/components/dashboard/FeeBreakdown";
import { RebateCard } from "@/components/dashboard/RebateCard";
import { ConnectButton } from "@/components/ConnectButton";
import { quoteFeePct, riskOf, riskRing, shortAddr } from "@/lib/format";

export default function DashboardPage() {
  const mounted = useMounted();

  const { address, isConnected } = useAccount();
  const { scores, toxicTrades, sandwiches, poolsByWallet, configured } = useGlyphEvents();
  const { quotes } = useFeeQuotes();
  const crossPoolCount = Object.values(poolsByWallet).filter((n) => n >= 2).length;

  // The dashboard opens with a connected wallet. Until then, the door.
  if (mounted && !isConnected) {
    return (
      <main className="mx-auto flex w-full max-w-6xl flex-1 items-center justify-center px-4 py-16 sm:px-6">
        <div className="card reveal w-full max-w-md rounded-3xl p-8 text-center">
          <span className="mx-auto grid h-12 w-12 place-items-center rounded-2xl bg-foreground text-lg font-semibold text-background">
            G
          </span>
          <h1 className="mt-5 text-xl font-semibold tracking-tight">
            Connect to see the pool&apos;s memory
          </h1>
          <p className="mt-2 text-sm leading-relaxed text-zinc-500">
            The dashboard streams live scores, flags and LP payouts straight from the chain.
            Connect a wallet and you&apos;ll also see your own reputation, and the exact fee any
            Glyph pool would quote you right now.
          </p>
          <div className="mt-6 flex justify-center">
            <ConnectButton size="lg" />
          </div>
        </div>
      </main>
    );
  }

  return (
    <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-8 sm:px-6 sm:py-10">
      <div className="mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold tracking-tight sm:text-2xl">Live reputation dashboard</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Glyph prices a swap by what it does to the pool, not by who sent it. Below is every
            fee the hook quoted, broken into the terms that produced it.
          </p>
        </div>
        <span className="flex items-center gap-2 rounded-full border border-white/10 px-3 py-1 text-xs text-zinc-500">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-emerald-500" />
          </span>
          streaming on chain
        </span>
      </div>

      {!configured && (
        <div className="mb-6 rounded-2xl border border-amber-500/30 bg-amber-500/5 px-4 py-3 text-sm break-words text-amber-700 dark:text-amber-300">
          Not connected yet. Set <code className="font-mono">NEXT_PUBLIC_REGISTRY_ADDRESS</code> and{" "}
          <code className="font-mono">NEXT_PUBLIC_HOOK_ADDRESS</code> in{" "}
          <code className="font-mono">frontend/.env.local</code> and this page comes alive on its own.
        </div>
      )}

      {mounted && address && <YourWallet address={address} />}

      <div className="mb-6">
        <RebateCard />
      </div>

      <PoolStats
        sandwiches={sandwiches}
        toxicCount={toxicTrades.length}
        crossPoolCount={crossPoolCount}
      />

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <FeeBreakdown quotes={quotes} />
        </div>
        <div className="lg:col-span-1">
          <ToxicTradesFeed trades={toxicTrades} />
        </div>
      </div>

      <div className="mt-6">
        <ScoreTable scores={scores} poolsByWallet={poolsByWallet} />
      </div>
    </main>
  );
}

/** The connected visitor's own standing: their live score and the fee they'd pay. */
function YourWallet({ address }: { address: `0x${string}` }) {
  const { score, trust, isLoading } = useReputationScore(address);
  const s = score ?? 0;
  const t = trust ?? 0;
  const risk = riskOf(s);

  return (
    <section className="mb-6 flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-emerald-500/20 bg-emerald-500/5 px-5 py-4">
      <div className="min-w-0">
        <p className="text-xs font-medium uppercase tracking-wider text-zinc-400">Your wallet</p>
        <p className="mt-1 truncate font-mono text-sm">{shortAddr(address)}</p>
      </div>
      <div className="flex flex-wrap items-center gap-x-6 gap-y-2">
        <div>
          <p className="text-xs text-zinc-400">Reputation</p>
          <p className="text-lg font-semibold tabular-nums">
            {isLoading ? "…" : `${s} / 10,000`}
          </p>
        </div>
        <div>
          <p className="text-xs text-zinc-400">Earned trust</p>
          <p className="text-lg font-semibold tabular-nums">
            {isLoading ? "…" : `${t} / 10,000`}
          </p>
        </div>
        <div>
          <p className="text-xs text-zinc-400">Fee on an ordinary swap</p>
          <p className="text-lg font-semibold tabular-nums text-emerald-600 dark:text-emerald-400">
            {isLoading ? "…" : quoteFeePct(s, t)}
          </p>
        </div>
        <span className={`rounded-full px-2.5 py-1 text-xs font-medium capitalize ring-1 ${riskRing[risk]}`}>
          {risk}
        </span>
      </div>
    </section>
  );
}
