"use client";

import { useSyncExternalStore } from "react";

const emptySubscribe = () => () => {};

/**
 * True once the component has hydrated on the client, false during SSR.
 *
 * The obvious way to write this is `useState(false)` plus a `useEffect` that sets it true,
 * and that is what this codebase did. It works, but it sets state synchronously inside an
 * effect, which schedules a second render pass on every mount and is flagged by
 * `react-hooks/set-state-in-effect`.
 *
 * `useSyncExternalStore` expresses the same idea without the extra pass: the server
 * snapshot is `false`, the client snapshot is `true`, and nothing ever changes afterward,
 * so the subscribe function has nothing to subscribe to.
 */
export function useMounted(): boolean {
  return useSyncExternalStore(
    emptySubscribe,
    () => true,
    () => false,
  );
}
