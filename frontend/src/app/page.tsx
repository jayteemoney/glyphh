import { WalletCTA } from "@/components/WalletCTA";

const STEPS = [
  {
    n: "01",
    title: "Watch",
    body: "Every swap in a Glyph pool is observed as it lands. The detector studies how each wallet actually trades: how fast, how large, how one-sided.",
  },
  {
    n: "02",
    title: "Score",
    body: "Behaviour becomes a number. A wallet that trades like a person scores near zero. A wallet that trades like a sandwich bot climbs fast, and the score lives on chain where anyone can read it.",
  },
  {
    n: "03",
    title: "Reprice",
    body: "The pool reads that score before quoting a fee. Honest flow keeps paying 0.30%. Flagged flow pays up to 10%, enough to turn most extraction into a losing trade.",
  },
  {
    n: "04",
    title: "Repay",
    body: "Everything charged above the base fee goes to the liquidity providers in the very same transaction. The people who were being drained are now the ones collecting the premium.",
  },
];

const PILLARS = [
  {
    title: "One pool learns, every pool knows",
    body: "All Glyph pools write to a single shared registry, and a reactive contract pushes new flags back out to all of them within seconds. A bot caught in one pool walks into the next one already paying the penalty rate. Pool hopping stops working.",
  },
  {
    title: "A price, never a blacklist",
    body: "Scores fade to zero over seven days, automatically. Nobody files an appeal and nobody holds a grudge. Trade cleanly for a week and the pool treats you like everyone else again. Punishment that expires is punishment that stays fair.",
  },
  {
    title: "Proof over promises",
    body: "Score updates arrive as signed attestations the contract verifies itself, pools can only report what actually happened in them, and historical behaviour can be proven with zero knowledge proofs rather than taken on faith.",
  },
];

const FAQS = [
  {
    q: "Can a bot just switch wallets?",
    a: "It can, and it costs them. Fresh wallets start with no history, which is itself a signal the model watches, and rebuilding approvals, balances and infrastructure on every rotation eats into margins that were thin to begin with. Glyph does not need rotation to be impossible. It needs extraction to pay worse than honest trading, and a 17x fee gap does that.",
  },
  {
    q: "Do honest traders ever get caught in this?",
    a: "The fee only moves for wallets whose recent trading looks like extraction: tight bursts, one direction, again and again. Ordinary trading patterns score zero, and we verified that live. Even a false flag is temporary by design, because every score decays back to zero within days.",
  },
  {
    q: "What does an LP have to do to benefit?",
    a: "Nothing. Provide liquidity to a pool that uses the Glyph hook and the protection is already on. The premium lands as fee growth on in range positions, the same way ordinary fees do.",
  },
  {
    q: "Why has nobody priced the trader before?",
    a: "Until v4 hooks, an AMM had no way to ask who is swapping before setting a fee. The data was always public. The plumbing to act on it is new, and Glyph is built directly on it.",
  },
];

export default function Home() {
  return (
    <main className="flex-1 overflow-hidden">
      {/* ── Hero ─────────────────────────────────────────────────────────── */}
      <section className="relative">
        <div aria-hidden className="dot-grid pointer-events-none absolute inset-0" />
        <div
          aria-hidden
          className="glow-drift pointer-events-none absolute -top-40 left-1/2 h-130 w-130 -translate-x-1/2 rounded-full bg-emerald-500/10 blur-3xl"
        />
        <div className="relative mx-auto w-full max-w-6xl px-4 pt-16 pb-12 sm:px-6 sm:pt-24 sm:pb-20">
          <p className="reveal text-xs font-medium uppercase tracking-[0.2em] text-emerald-600 dark:text-emerald-400">
            The pool that remembers
          </p>

          <h1 className="reveal-1 mt-4 max-w-3xl text-4xl font-semibold leading-[1.08] tracking-tight sm:text-6xl">
            Swaps priced by <span className="text-emerald-500">who</span> is trading.
            <br className="hidden sm:block" /> Not just what.
          </h1>

          <p className="reveal-2 mt-6 max-w-xl text-base leading-relaxed text-zinc-500 sm:text-lg">
            Glyph gives every wallet a reputation built from how it actually trades. People pay
            the normal fee. Bots that drain liquidity pay up to 33 times more, and that premium
            goes straight back to the LPs they were draining.
          </p>

          <div className="reveal-3 mt-8 flex flex-wrap items-center gap-3">
            <WalletCTA connectedLabel="See it live" disconnectedLabel="Connect wallet" />
            <a
              href="https://github.com/jayteemoney/glyphh/blob/main/docs/02-SOLUTION.md"
              target="_blank"
              rel="noopener noreferrer"
              className="rounded-full border border-white/15 px-6 py-3 text-sm font-medium transition-colors hover:border-emerald-500/50 hover:text-emerald-400"
            >
              How it works
            </a>
          </div>

          {/* Hero visual: same pool, two prices */}
          <div className="card reveal-3 mt-14 max-w-2xl rounded-3xl p-5 sm:p-7">
            <p className="text-xs font-medium uppercase tracking-wider text-zinc-400">
              Same pool. Same minute. Different price.
            </p>

            <div className="mt-5 space-y-5">
              <FeeRow
                who="Everyday trader"
                detail="a few balanced swaps"
                fee="0.30%"
                tone="good"
                width="6%"
                anim="bar-grow"
              />
              <FeeRow
                who="Sandwich bot"
                detail="caught mid burst, flagged in seconds"
                fee="5.20%"
                tone="bad"
                width="78%"
                anim="bar-grow-late"
              />
            </div>

            <p className="mt-5 text-xs leading-relaxed text-zinc-400">
              Measured on our live deployment. The detector flagged the bot four swaps into its
              burst with no human involved, and every swap after that paid the premium to LPs.
            </p>
          </div>
        </div>
      </section>

      {/* ── Problem ──────────────────────────────────────────────────────── */}
      <section className="border-t border-white/5">
        <div className="scroll-reveal mx-auto w-full max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
          <h2 className="max-w-2xl text-2xl font-semibold tracking-tight sm:text-4xl">
            Every pool today has amnesia.
          </h2>
          <p className="mt-4 max-w-2xl text-base leading-relaxed text-zinc-500">
            A bot can sandwich the same pool a thousand times and still pay the same fee as a
            first time user on swap one thousand and one. The pool simply cannot tell them
            apart, so liquidity providers quietly fund the extraction.
          </p>

          <div className="mt-10 grid gap-4 sm:grid-cols-3">
            <ProblemCard
              stat="Every block"
              body="Arbitrage and sandwich bots trade against LPs only when LPs are guaranteed to lose. On volatile pairs, fees often do not even cover the bleed."
            />
            <ProblemCard
              stat="Zero memory"
              body="Existing defenses react to price moves or volatility spikes. They punish the weather, not the burglar, and they forget everything between swaps."
            />
            <ProblemCard
              stat="Infinite retries"
              body="Get detected in one pool and there is always another. No defense deployed today shares what it learned with the pool next door."
            />
          </div>
        </div>
      </section>

      {/* ── How it works ─────────────────────────────────────────────────── */}
      <section className="border-t border-white/5">
        <div className="scroll-reveal mx-auto w-full max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
          <h2 className="text-2xl font-semibold tracking-tight sm:text-4xl">
            Memory, in four moves.
          </h2>

          <div className="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {STEPS.map((s) => (
              <div
                key={s.n}
                className="card card-hover rounded-2xl p-5"
              >
                <span className="font-mono text-xs text-emerald-500">{s.n}</span>
                <h3 className="mt-2 text-lg font-semibold">{s.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-zinc-500">{s.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── Pillars ──────────────────────────────────────────────────────── */}
      <section className="border-t border-white/5">
        <div className="scroll-reveal mx-auto w-full max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
          <h2 className="max-w-2xl text-2xl font-semibold tracking-tight sm:text-4xl">
            Built to be tough on bots and fair to people.
          </h2>

          <div className="mt-10 grid gap-4 lg:grid-cols-3">
            {PILLARS.map((p) => (
              <div
                key={p.title}
                className="card card-hover rounded-2xl p-6"
              >
                <h3 className="text-lg font-semibold">{p.title}</h3>
                <p className="mt-3 text-sm leading-relaxed text-zinc-500">{p.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── LP yield ─────────────────────────────────────────────────────── */}
      <section className="border-t border-white/5">
        <div className="scroll-reveal mx-auto grid w-full max-w-6xl gap-10 px-4 py-16 sm:px-6 sm:py-24 lg:grid-cols-2 lg:items-center">
          <div>
            <h2 className="text-2xl font-semibold tracking-tight sm:text-4xl">
              Toxic flow used to be a tax on LPs.
              <br />
              <span className="text-emerald-500">Now it pays them.</span>
            </h2>
            <p className="mt-5 max-w-lg text-base leading-relaxed text-zinc-500">
              Glyph never blocks a trade. The bots are welcome to keep swapping, they just do it
              at a price that reflects what they take. Every basis point charged above the normal
              fee lands on in range liquidity in the same transaction. No claims process, no
              token, no waiting.
            </p>
          </div>

          <div className="card rounded-3xl p-6 sm:p-8">
            <div className="space-y-4 font-mono text-sm">
              <Ledger label="Bot swap, flagged wallet" value="fee 5.20%" />
              <Ledger label="Base fee kept by pool" value="0.30%" />
              <div className="border-t border-dashed border-white/10 pt-4">
                <Ledger label="Premium to LPs, same block" value="4.90%" accent />
              </div>
            </div>
            <p className="mt-6 text-xs leading-relaxed text-zinc-400">
              The dashboard keeps a running total of these payouts as they happen, swap by swap.
            </p>
          </div>
        </div>
      </section>

      {/* ── FAQ ──────────────────────────────────────────────────────────── */}
      <section className="border-t border-white/5">
        <div className="scroll-reveal mx-auto w-full max-w-3xl px-4 py-16 sm:px-6 sm:py-24">
          <h2 className="text-2xl font-semibold tracking-tight sm:text-4xl">
            The questions everyone asks.
          </h2>
          <div className="mt-8 divide-y divide-white/5">
            {FAQS.map((f) => (
              <details key={f.q} className="group py-4">
                <summary className="flex cursor-pointer list-none items-center justify-between gap-4 text-base font-medium">
                  {f.q}
                  <span className="shrink-0 text-zinc-400 transition-transform group-open:rotate-45">
                    +
                  </span>
                </summary>
                <p className="mt-3 text-sm leading-relaxed text-zinc-500">{f.a}</p>
              </details>
            ))}
          </div>
        </div>
      </section>

      {/* ── CTA ──────────────────────────────────────────────────────────── */}
      <section className="border-t border-white/5">
        <div className="mx-auto w-full max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
          <div className="relative overflow-hidden rounded-3xl border border-emerald-500/20 bg-emerald-500/5 px-6 py-12 text-center sm:px-12 sm:py-16">
            <div
              aria-hidden
              className="pointer-events-none absolute -top-24 left-1/2 h-64 w-64 -translate-x-1/2 rounded-full bg-emerald-500/15 blur-3xl"
            />
            <h2 className="relative text-2xl font-semibold tracking-tight sm:text-4xl">
              Watch a pool defend itself in real time.
            </h2>
            <p className="relative mx-auto mt-4 max-w-xl text-base text-zinc-500">
              Scores climbing, fees adjusting, LPs getting paid. It is all on chain and the
              dashboard streams it as it happens.
            </p>
            <div className="relative mt-8">
              <WalletCTA
                connectedLabel="Open the live dashboard"
                disconnectedLabel="Connect wallet to enter"
              />
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}

/* ── Local pieces ─────────────────────────────────────────────────────────── */

function FeeRow({
  who,
  detail,
  fee,
  tone,
  width,
  anim,
}: {
  who: string;
  detail: string;
  fee: string;
  tone: "good" | "bad";
  width: string;
  anim: string;
}) {
  const barColor = tone === "good" ? "bg-emerald-500" : "bg-red-500";
  const feeColor =
    tone === "good"
      ? "text-emerald-600 dark:text-emerald-400"
      : "text-red-600 dark:text-red-400";
  return (
    <div>
      <div className="flex items-baseline justify-between gap-3">
        <p className="min-w-0 truncate text-sm font-medium">
          {who} <span className="hidden text-xs font-normal text-zinc-400 sm:inline">· {detail}</span>
        </p>
        <span className={`shrink-0 font-mono text-sm font-semibold tabular-nums ${feeColor}`}>
          {fee}
        </span>
      </div>
      <div className="mt-2 h-2 overflow-hidden rounded-full bg-white/10">
        <div className={`h-full rounded-full ${barColor} ${anim}`} style={{ width }} />
      </div>
    </div>
  );
}

function ProblemCard({ stat, body }: { stat: string; body: string }) {
  return (
    <div className="card card-hover rounded-2xl p-6">
      <p className="text-xl font-semibold tracking-tight text-red-500">{stat}</p>
      <p className="mt-3 text-sm leading-relaxed text-zinc-500">{body}</p>
    </div>
  );
}

function Ledger({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="min-w-0 truncate text-zinc-500">{label}</span>
      <span
        className={`shrink-0 tabular-nums ${
          accent ? "font-semibold text-emerald-600 dark:text-emerald-400" : ""
        }`}
      >
        {value}
      </span>
    </div>
  );
}
