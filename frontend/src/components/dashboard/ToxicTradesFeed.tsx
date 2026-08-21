import type { ToxicTrade } from "@/hooks/useGlyphEvents";
import { shortAddr, timeAgo } from "@/lib/format";

export function ToxicTradesFeed({ trades }: { trades: ToxicTrade[] }) {
  return (
    <section className="card flex h-full flex-col rounded-2xl p-4 sm:p-5">
      <header className="mb-4 flex items-center justify-between">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-zinc-500">Live toxic activity</h2>
        <span className="flex items-center gap-1.5 text-xs text-zinc-400">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-400 opacity-75" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-red-500" />
          </span>
          live
        </span>
      </header>

      {trades.length === 0 ? (
        <div className="flex flex-1 items-center justify-center rounded-xl border border-dashed border-white/10 px-4 py-10 text-center text-sm text-zinc-400">
          Quiet for now. Flags land here the moment the detector catches someone.
        </div>
      ) : (
        <ul className="flex-1 space-y-2 overflow-y-auto">
          {trades.map((t, i) => (
            <li
              key={`${t.txHash ?? "x"}-${i}`}
              className="flex items-center justify-between gap-2 rounded-xl border border-white/5 bg-white/[0.02] px-3 py-2.5 transition-colors hover:bg-white/[0.04]"
            >
              <div className="min-w-0">
                <p className="truncate font-mono text-xs text-zinc-700 dark:text-zinc-200">{shortAddr(t.wallet)}</p>
                <p className="truncate text-[11px] text-zinc-400">
                  {t.source === "detector" ? "detector flag" : `pool ${shortAddr(t.poolId)}`} · {timeAgo(t.timestamp)}
                </p>
              </div>
              <span
                className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-semibold ring-1 ${
                  t.source === "detector"
                    ? "bg-amber-500/10 text-amber-600 ring-amber-500/30 dark:text-amber-400"
                    : "bg-red-500/10 text-red-500 ring-red-500/30"
                }`}
              >
                {t.source === "detector" ? `→ ${t.severity}` : `+${t.severity}`}
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
