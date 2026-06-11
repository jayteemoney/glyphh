import Link from "next/link";

const REPO = "https://github.com/jayteemoney/glyphh";

const COLUMNS: { heading: string; links: { label: string; href: string; external?: boolean }[] }[] = [
  {
    heading: "Product",
    links: [
      { label: "Live dashboard", href: "/dashboard" },
      { label: "Pools", href: "/pools" },
      { label: "Source code", href: REPO, external: true },
    ],
  },
  {
    heading: "Learn",
    links: [
      { label: "User guide", href: `${REPO}/blob/main/docs/06-USER-GUIDE.md`, external: true },
      { label: "The problem", href: `${REPO}/blob/main/docs/01-PROBLEM.md`, external: true },
      { label: "How Glyph works", href: `${REPO}/blob/main/docs/02-SOLUTION.md`, external: true },
      { label: "Where it fits", href: `${REPO}/blob/main/docs/03-ECOSYSTEM-GAP.md`, external: true },
    ],
  },
  {
    heading: "Build",
    links: [
      { label: "Contract guide", href: `${REPO}/blob/main/docs/CONTRACT_GUIDE.md`, external: true },
      { label: "Deployments", href: `${REPO}/blob/main/docs/DEPLOYMENT.md`, external: true },
      { label: "Run the demo", href: `${REPO}/blob/main/docs/DEMO_SCRIPT.md`, external: true },
    ],
  },
];

export function Footer() {
  return (
    <footer className="border-t border-white/10">
      <div className="mx-auto w-full max-w-6xl px-4 py-12 sm:px-6 sm:py-16">
        <div className="grid gap-10 sm:grid-cols-2 lg:grid-cols-5">
          {/* Brand */}
          <div className="lg:col-span-2">
            <Link href="/" className="flex items-center gap-2 font-semibold tracking-tight">
              <span className="grid h-7 w-7 place-items-center rounded-lg bg-foreground text-sm text-background">
                G
              </span>
              Glyph
            </Link>
            <p className="mt-4 max-w-xs text-sm leading-relaxed text-zinc-500">
              Liquidity that remembers. Every wallet earns a reputation, every swap is priced
              by it, and the people providing liquidity keep the difference.
            </p>
            <div className="mt-5 flex items-center gap-3">
              <SocialLink href={REPO} label="GitHub">
                <svg viewBox="0 0 24 24" fill="currentColor" className="h-4.5 w-4.5" aria-hidden>
                  <path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.11.79-.25.79-.55v-2.17c-3.2.7-3.87-1.36-3.87-1.36-.52-1.33-1.28-1.68-1.28-1.68-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.19 1.76 1.19 1.03 1.75 2.69 1.25 3.34.95.1-.74.4-1.25.72-1.54-2.55-.29-5.23-1.28-5.23-5.68 0-1.26.45-2.28 1.19-3.09-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11.1 11.1 0 0 1 5.8 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.19 1.83 1.19 3.09 0 4.41-2.69 5.38-5.25 5.66.41.36.77 1.05.77 2.13v3.16c0 .3.21.67.8.55A11.51 11.51 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5Z" />
                </svg>
              </SocialLink>
              <SocialLink href="https://x.com/jayteemoney" label="X (Twitter)">
                <svg viewBox="0 0 24 24" fill="currentColor" className="h-4 w-4" aria-hidden>
                  <path d="M18.9 1.15h3.68l-8.04 9.19L24 22.85h-7.41l-5.8-7.58-6.64 7.58H.46l8.6-9.83L0 1.15h7.59l5.24 6.93 6.07-6.93Zm-1.29 19.5h2.04L6.49 3.24H4.3l13.31 17.4Z" />
                </svg>
              </SocialLink>
            </div>
          </div>

          {/* Link columns */}
          {COLUMNS.map((col) => (
            <div key={col.heading}>
              <h3 className="text-xs font-semibold uppercase tracking-wider text-zinc-400">
                {col.heading}
              </h3>
              <ul className="mt-4 space-y-2.5">
                {col.links.map((l) => (
                  <li key={l.label}>
                    {l.external ? (
                      <a
                        href={l.href}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-sm text-zinc-500 transition-colors hover:text-foreground"
                      >
                        {l.label}
                      </a>
                    ) : (
                      <Link
                        href={l.href}
                        className="text-sm text-zinc-500 transition-colors hover:text-foreground"
                      >
                        {l.label}
                      </Link>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="mt-12 flex flex-col items-start justify-between gap-3 border-t border-white/5 pt-6 text-xs text-zinc-400 sm:flex-row sm:items-center">
          <p>© {new Date().getFullYear()} Glyph. Open source under the MIT license.</p>
          <p className="flex items-center gap-2">
            <span className="relative flex h-2 w-2">
              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75" />
              <span className="relative inline-flex h-2 w-2 rounded-full bg-emerald-500" />
            </span>
            Contracts live and watching
          </p>
        </div>
      </div>
    </footer>
  );
}

function SocialLink({
  href,
  label,
  children,
}: {
  href: string;
  label: string;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={label}
      className="grid h-9 w-9 place-items-center rounded-full border border-white/15 text-zinc-500 transition-colors hover:border-emerald-500/50 hover:text-foreground"
    >
      {children}
    </a>
  );
}
