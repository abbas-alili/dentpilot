// Keep work running after the HTTP response has been sent.
// Supabase Edge Runtime provides EdgeRuntime.waitUntil; elsewhere (tests,
// local Deno) the promise just runs and errors are logged.

import { log } from "./log.ts";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

export function runInBackground(work: Promise<unknown>): void {
  const guarded = work.catch((error) => log.error("background.failed", { error: String(error) }));
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(guarded);
}
