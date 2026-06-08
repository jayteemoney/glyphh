import type { ScoreRow } from "@/hooks/useGlyphEvents";
import { feePct, riskOf, riskRing, riskBar, shortAddr, timeAgo } from "@/lib/format";

export function ScoreTable({ scores }: { scores: ScoreRow[] }) {
  return (
    <section className="rounded-2xl border border-black/10 bg-white/60 p-5 shadow-sm backdrop-blur dark:border-white/10 dark:bg-white/[0.03]">
      <header className="mb-4 flex items-center justify-between">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-zinc-500">
          Wallet reputation
        </h2>
        <span className="text-xs text-zinc-400">{scores.length} wallets</span>
      </header>

      {scores.length === 0 ? (
        <Empty label="No reputation updates yet. Run the detector or the attacker bot to populate this." />
      ) : (
        <div className="overflow-hidden rounded-xl border border-black/5 dark:border-white/5">
          <table className="w-full text-left text-sm">
            <thead className="bg-black/[0.03] text-xs uppercase tracking-wider text-zinc-500 dark:bg-white/[0.03]">
              <tr>
                <th className="px-3 py-2 font-medium">Wallet</th>
                <th className="px-3 py-2 font-medium">Score</th>
                <th className="px-3 py-2 font-medium">Fee</th>
                <th className="px-3 py-2 font-medium">Risk</th>
                <th className="px-3 py-2 text-right font-medium">Updated</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-black/5 dark:divide-white/5">
              {scores.map((s) => {
                const risk = riskOf(s.score);
                return (
                  <tr key={s.wallet} className="transition-colors hover:bg-black/[0.02] dark:hover:bg-white/[0.02]">
                    <td className="px-3 py-2.5 font-mono text-xs">{shortAddr(s.wallet)}</td>
                    <td className="px-3 py-2.5">
                      <div className="flex items-center gap-2">
                        <div className="h-1.5 w-20 overflow-hidden rounded-full bg-black/10 dark:bg-white/10">
                          <div
                            className={`h-full ${riskBar[risk]}`}
                            style={{ width: `${Math.min(100, (s.score / 10000) * 100)}%` }}
                          />
                        </div>
                        <span className="tabular-nums text-xs text-zinc-500">{s.score}</span>
                      </div>
                    </td>
                    <td className="px-3 py-2.5 font-medium tabular-nums">{feePct(s.score)}</td>
                    <td className="px-3 py-2.5">
                      <span className={`rounded-full px-2 py-0.5 text-xs font-medium capitalize ring-1 ${riskRing[risk]}`}>
                        {risk}
                      </span>
                    </td>
                    <td className="px-3 py-2.5 text-right text-xs text-zinc-400">{timeAgo(s.updatedAt)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function Empty({ label }: { label: string }) {
  return (
    <div className="rounded-xl border border-dashed border-black/10 px-4 py-10 text-center text-sm text-zinc-400 dark:border-white/10">
      {label}
    </div>
  );
}
