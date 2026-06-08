/**
 * clean_trader.ts — the honest-flow side of the Glyph demo.
 *
 * Makes a handful of small, well-spaced, alternating-direction swaps — the footprint of
 * ordinary order flow. The hook sees nothing toxic, the wallet's Glyph score stays at 0,
 * and every swap keeps quoting the base fee. Run this side-by-side with attacker_bot.ts
 * to show the whole point of Glyph: the same pool charges the toxic wallet ~10x more while
 * leaving the clean trader untouched.
 *
 * Run:  CLEAN_PRIVATE_KEY=0x... npm run clean
 */

import {
  walletFor,
  poolKeyFromEnv,
  readScore,
  logScore,
  doSwap,
  ensureApprovals,
  preflight,
  env,
  sleep,
} from "./lib/glyph.js";

async function main() {
  const { account, client } = walletFor("CLEAN_PRIVATE_KEY");
  console.log(`\n🧑‍🌾 Clean trader — ${account.address}\n`);

  const before = await readScore(account.address);
  logScore("start", before);

  const pf = preflight();
  if (!pf.ready) {
    console.log(
      `\n⚠️  ${pf.reason}. Showing score only — fill demo/.env to run live swaps.\n`,
    );
    return;
  }

  const key = poolKeyFromEnv();
  const amount = BigInt(env("SWAP_AMOUNT", "1000000000000000"));
  const count = Number(env("CLEAN_SWAPS", "4"));
  const interval = Number(env("CLEAN_INTERVAL_MS", "8000"));

  await ensureApprovals(client, account, key);

  console.log(`\n  making ${count} paced, alternating-direction swaps...\n`);
  for (let i = 0; i < count; i++) {
    try {
      const hash = await doSwap({
        client,
        account,
        key,
        zeroForOne: i % 2 === 0, // alternate = balanced = non-toxic
        amount,
      });
      const score = await readScore(account.address);
      console.log(`  swap ${i + 1}/${count}  ${hash.slice(0, 10)}…`);
      logScore(`after #${i + 1}`, score);
    } catch (err) {
      console.error(`  swap ${i + 1} reverted: ${(err as Error).message.split("\n")[0]}`);
    }
    if (i < count - 1) await sleep(interval); // honest cadence, not a burst
  }

  const after = await readScore(account.address);
  console.log("\n  ── result ──");
  logScore("start", before);
  logScore("end", after);
  console.log(
    `\n  ✅ score stayed ${after}. Honest flow keeps the base fee — exactly as intended.\n`,
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
