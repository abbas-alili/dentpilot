// Database access. Every function connects as `dentpilot_agent` — never as
// service_role — through the Supavisor pooler in transaction mode.
//
//   withClinic(clinicId, tx => ...)   work for ONE clinic: sets app.clinic_id
//                                     and app.actor for this transaction, so
//                                     RLS limits every query to that clinic.
//   withoutClinic(tx => ...)          only for the tenant resolvers and the
//                                     job queue, which are SECURITY DEFINER
//                                     functions returning ids, not data.
//
// Never hold a transaction open across an HTTP call (WhatsApp, push, LLM):
// read → commit → call out → open a new transaction to record the result.

import postgres from "npm:postgres@3.4.5";
import { env, SECRETS } from "./config.ts";

export type Sql = postgres.Sql;
export type Tx = postgres.TransactionSql;

let sql: Sql | null = null;

/** Lazily-created pool. `prepare: false` is required in pooler transaction mode. */
export function db(): Sql {
  sql ??= postgres(env(SECRETS.agentDbUrl), {
    prepare: false,
    max: 3,
    idle_timeout: 20,
    connect_timeout: 10,
  });
  return sql;
}

/** For tests: use a given connection instead of the environment's. */
export function setDb(instance: Sql): void {
  sql = instance;
}

export type Actor = "assistant" | "system";

export async function withClinic<T>(
  clinicId: string,
  fn: (tx: Tx) => Promise<T>,
  actor: Actor = "assistant",
): Promise<T> {
  return await db().begin(async (tx) => {
    await tx`select set_config('app.clinic_id', ${clinicId}, true),
                    set_config('app.actor', ${actor}, true)`;
    return await fn(tx);
  }) as T;
}

export async function withoutClinic<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
  return await db().begin(async (tx) => await fn(tx)) as T;
}

/** Clinic id for a Meta phone_number_id, or null if unknown. */
export async function clinicForPhoneNumber(phoneNumberId: string): Promise<string | null> {
  const [row] = await withoutClinic((tx) =>
    tx`select core.clinic_for_phone_number(${phoneNumberId}) as id`
  );
  return row?.id ?? null;
}

/** Clinic id for a Flow token, or null if unknown/expired. */
export async function clinicForFlowToken(token: string): Promise<string | null> {
  const [row] = await withoutClinic((tx) =>
    tx`select core.clinic_for_flow_token(${token}) as id`
  );
  return row?.id ?? null;
}

/** Postgres SQLSTATE of an error thrown by postgres.js, if any. */
export function sqlState(error: unknown): string | undefined {
  return (error as { code?: string })?.code;
}
