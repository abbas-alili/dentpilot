// Minimal assertions (keeps tests dependency-free; same names as @std/assert).

export function assert(condition: unknown, message = "assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

export function assertEquals(actual: unknown, expected: unknown, message = ""): void {
  const a = JSON.stringify(normalize(actual));
  const e = JSON.stringify(normalize(expected));
  if (a !== e) throw new Error(`${message ? message + ": " : ""}expected ${e}\n   actual ${a}`);
}

export async function assertRejects(fn: () => Promise<unknown>, _type: unknown, includes: string): Promise<void> {
  try {
    await fn();
  } catch (error) {
    if (!String((error as Error).message).includes(includes)) throw new Error(`wrong error: ${error}`);
    return;
  }
  throw new Error("expected rejection");
}

function normalize(value: unknown): unknown {
  if (value instanceof Uint8Array) return Array.from(value);
  if (value instanceof Date) return value.toISOString();
  return value;
}
