import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Link from "next/link";
import "./globals.css";
import { Providers } from "./providers";
import { Footer } from "@/components/Footer";
import { ConnectButton } from "@/components/ConnectButton";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Glyph — liquidity that remembers",
  description:
    "Glyph prices every swap by the wallet behind it. Honest traders pay the normal fee, extractive bots pay up to 33x more, and liquidity providers keep the difference.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={`dark ${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="flex min-h-full flex-col">
        <Providers>
          <header className="sticky top-0 z-10 border-b border-white/10 bg-background/80 backdrop-blur">
            <div className="mx-auto flex w-full max-w-6xl items-center justify-between px-4 py-3 sm:px-6">
              <Link href="/" className="flex items-center gap-2 font-semibold tracking-tight">
                <span className="grid h-6 w-6 place-items-center rounded-md bg-foreground text-xs text-background">G</span>
                Glyph
              </Link>
              <nav className="flex items-center gap-3 text-sm text-zinc-500 sm:gap-5">
                <Link href="/dashboard" className="transition-colors hover:text-foreground">
                  Dashboard
                </Link>
                <Link href="/pools" className="hidden transition-colors hover:text-foreground sm:inline">
                  Pools
                </Link>
                <ConnectButton />
              </nav>
            </div>
          </header>
          {children}
          <Footer />
        </Providers>
      </body>
    </html>
  );
}
