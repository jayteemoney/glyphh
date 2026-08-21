/* eslint-disable @typescript-eslint/no-explicit-any */

/**
 * Range-limited log reader for the public Unichain Sepolia RPC.
 *
 * The node caps `eth_getLogs` somewhere between 10k and 50k blocks per call, and — this is
 * the part that costs you an afternoon — a request over the cap returns HTTP 400 rather
 * than a truncated result. A hook that wraps its backfill in try/catch therefore renders a
 * blank panel and looks like "no activity yet" instead of "the query was rejected".
 *
 * That is not academic here. Unichain produces a block a second, so 10k blocks is under
 * three hours; anything demoed yesterday is already out of reach of a single call. This
 * walks backward in accepted-size chunks instead, stopping as soon as it has enough rows
 * to fill the UI so a quiet chain does not cost dozens of round trips.
 */

/** Comfortably under the observed cap, with headroom for a stricter provider. */
export const CHUNK_BLOCKS = BigInt(9_000);

/** How far back to look in total, in blocks. ~24h of one-second blocks. */
export const LOOKBACK_BLOCKS = BigInt(
  process.env.NEXT_PUBLIC_BACKFILL_BLOCKS ?? "86400",
);

export type ChunkedLogsArgs = {
  client: any;
  address: `0x${string}`;
  event: any;
  /** Stop early once this many logs have been collected. */
  enough?: number;
  lookback?: bigint;
};

/**
 * Fetch logs by walking backward from the chain head in RPC-sized chunks.
 * Returns newest-last (chain order), matching what `getLogs` gives for a single range.
 */
export async function getLogsChunked({
  client,
  address,
  event,
  enough = 100,
  lookback = LOOKBACK_BLOCKS,
}: ChunkedLogsArgs): Promise<any[]> {
  const latest: bigint = await client.getBlockNumber();
  const floor = latest > lookback ? latest - lookback : BigInt(0);

  const collected: any[] = [];
  let toBlock = latest;

  while (toBlock > floor && collected.length < enough) {
    const fromBlock = toBlock > floor + CHUNK_BLOCKS ? toBlock - CHUNK_BLOCKS : floor;
    try {
      const logs = await client.getLogs({ address, event, fromBlock, toBlock });
      // Prepend: we are walking backward, so earlier chunks belong earlier in the array.
      collected.unshift(...logs);
    } catch {
      // One rejected chunk should not abandon the whole backfill — the node is
      // load-balanced and individual replicas disagree about what they will serve.
    }
    if (fromBlock === floor) break;
    toBlock = fromBlock - BigInt(1);
  }

  return collected;
}
