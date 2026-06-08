/**
 * attacker_bot.ts — the toxic-flow side of the Glyph demo.
 *
 * Fires a tight *burst* of large swaps in the same direction (classic MEV / sandwich
 * footprint). The hook flags each as toxic, the off-chain detector + Reactive aggregate
 * push the wallet's Glyph score up, and every subsequent swap quotes a higher dynamic
 * fee — which the hook donates back to LPs. The bot prints the score climbing in real
 * time so you can watch the wallet price itself out of the pool.
 *
 * Run:  ATTACKER_PRIVATE_KEY=0x... npm run attacker
 *       npm run score        # read-only: just print the current score
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
  const scoreOnly =
    process.argv.includes("--score-only") || process.argv.includes("--score");

  const { account, client } = walletFor("ATTACKER_PRIVATE_KEY");
  console.log(`\n🦹 Attacker bot — ${account.address}\n`);

  const before = await readScore(account.address);
  logScore("start", before);

  if (scoreOnly) return;

  const pf = preflight();
  if (!pf.ready) {
    console.log(
      `\n⚠️  ${pf.reason}. Showing score only — fill demo/.env to run live swaps.\n`,
    );
    return;
  }

  const key = poolKeyFromEnv();
  const amount = BigInt(env("SWAP_AMOUNT", "1000000000000000"));
  const burst = Number(env("ATTACKER_BURST", "6"));

  await ensureApprovals(client, account, key);

  console.log(`\n  firing a burst of ${burst} same-direction swaps...\n`);
  for (let i = 0; i < burst; i++) {
    try {
      const hash = await doSwap({
        client,
        account,
        key,
        zeroForOne: true, // all one direction = directional pressure = toxic
        amount,
      });
      const score = await readScore(account.address);
      console.log(`  swap ${i + 1}/${burst}  ${hash.slice(0, 10)}…`);
      logScore(`after #${i + 1}`, score);
    } catch (err) {
      console.error(`  swap ${i + 1} reverted: ${(err as Error).message.split("\n")[0]}`);
    }
    await sleep(1500); // brief gap so the detector/Reactive loop can score
  }

  // Give the off-chain detector + Reactive callback a moment to settle the final score.
  await sleep(4000);
  const after = await readScore(account.address);
  console.log("\n  ── result ──");
  logScore("start", before);
  logScore("end", after);
  console.log(
    `\n  📈 score moved ${before} → ${after}. Toxic flow now pays the premium; LPs keep it.\n`,
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
