import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Link from "next/link";
import "./globals.css";
import { Providers } from "./providers";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Glyph — reputation-priced swaps",
  description: "The first Uniswap v4 hook that prices each swap by who is trading, not just what.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="flex min-h-full flex-col">
        <Providers>
          <header className="sticky top-0 z-10 border-b border-black/10 bg-background/80 backdrop-blur dark:border-white/10">
            <div className="mx-auto flex w-full max-w-6xl items-center justify-between px-6 py-3">
              <Link href="/" className="flex items-center gap-2 font-semibold tracking-tight">
                <span className="grid h-6 w-6 place-items-center rounded-md bg-foreground text-xs text-background">G</span>
                Glyph
              </Link>
              <nav className="flex items-center gap-5 text-sm text-zinc-500">
                <Link href="/dashboard" className="transition-colors hover:text-foreground">
                  Dashboard
                </Link>
                <Link href="/pools" className="transition-colors hover:text-foreground">
                  Pools
                </Link>
              </nav>
            </div>
          </header>
          {children}
        </Providers>
      </body>
    </html>
  );
}
