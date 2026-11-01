// google-oauth — connect a dentist's Google Calendar (one-way sync target).
// Connects to the database as dentpilot_agent.
//
//   POST /google-oauth/start      { professional_id }  + staff app JWT
//        → checks the user is an admin or that dentist → returns Google's consent URL
//   GET  /google-oauth/callback   ?code&state          (Google redirects here)
//        → verifies the signed state → exchanges the code → refresh token into
//          Vault (ops.save_google_link) → redirects back to the staff app
//
// Scope: calendar.events (create/update/delete events) + email (to show which
// Google account is connected). access_type=offline + prompt=consent so Google
// always returns a refresh token.

import { withoutClinic } from "../_shared/db.ts";
import { constantTimeEqual, hmacSha256Hex } from "../_shared/crypto.ts";
import type { GoogleCalendarClient } from "../_shared/gcal.ts";
import { log } from "../_shared/log.ts";

export interface OAuthDeps {
  google: GoogleCalendarClient;
  clientId: string;
  redirectUri: string;            // https://<ref>.supabase.co/functions/v1/google-oauth/callback
  stateSecret: string;
  staffAppUrl: string;            // where to send the user afterwards
  /** Supabase Auth user id for a staff JWT, or null. */
  verifyUser: (jwt: string) => Promise<string | null>;
}

const SCOPES = "https://www.googleapis.com/auth/calendar.events openid email";
const STATE_TTL_MS = 10 * 60 * 1000;

export function createOAuthHandler(deps: OAuthDeps) {
  const cors = {
    "Access-Control-Allow-Origin": new URL(deps.staffAppUrl).origin,
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };

  return async (req: Request): Promise<Response> => {
    const path = new URL(req.url).pathname;
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (req.method === "POST" && path.endsWith("/start")) return await start(req, deps, cors);
    if (req.method === "GET" && path.endsWith("/callback")) return await callback(req, deps);
    return new Response("not found", { status: 404 });
  };
}

async function start(req: Request, deps: OAuthDeps, cors: Record<string, string>): Promise<Response> {
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
  const userId = jwt ? await deps.verifyUser(jwt) : null;
  if (!userId) return Response.json({ error: "not signed in" }, { status: 401, headers: cors });

  const { professional_id: professionalId } = await req.json().catch(() => ({}));
  if (typeof professionalId !== "string") return Response.json({ error: "professional_id required" }, { status: 400, headers: cors });

  const [allowed] = await withoutClinic((tx) =>
    tx`select ops.can_connect_calendar(${userId}, ${professionalId}::uuid) as ok`
  ).catch(() => [{ ok: false }]);
  if (!allowed.ok) return Response.json({ error: "not allowed" }, { status: 403, headers: cors });

  const state = await signState(deps.stateSecret, { p: professionalId, u: userId, exp: Date.now() + STATE_TTL_MS });
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.search = new URLSearchParams({
    client_id: deps.clientId, redirect_uri: deps.redirectUri, response_type: "code",
    scope: SCOPES, access_type: "offline", prompt: "consent", include_granted_scopes: "true", state,
  }).toString();
  return Response.json({ url: url.toString() }, { headers: cors });
}

async function callback(req: Request, deps: OAuthDeps): Promise<Response> {
  const params = new URL(req.url).searchParams;
  const back = (status: string) => Response.redirect(`${deps.staffAppUrl}/settings/calendar?status=${status}`, 302);

  if (params.get("error")) return back("cancelled");
  const state = await verifyState(deps.stateSecret, params.get("state") ?? "");
  const code = params.get("code");
  if (!state || !code) return back("invalid");

  try {
    const { refreshToken, email } = await deps.google.exchangeCode(code, deps.redirectUri);
    await withoutClinic((tx) => tx`select ops.save_google_link(${state.p}, ${email}, ${refreshToken}, ${state.u})`);
    log.info("gcal.connected", { professionalId: state.p });
    return back("connected");
  } catch (error) {
    log.error("gcal.connect_failed", { error: String(error) });
    return back("failed");
  }
}

// ---------------------------------------------------------------- signed state
interface State { p: string; u: string; exp: number }

export async function signState(secret: string, state: State): Promise<string> {
  const body = btoa(JSON.stringify(state)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${body}.${await hmacSha256Hex(secret, body)}`;
}

export async function verifyState(secret: string, value: string): Promise<State | null> {
  const [body, mac] = value.split(".");
  if (!body || !mac || !constantTimeEqual(mac, await hmacSha256Hex(secret, body))) return null;
  try {
    const state = JSON.parse(atob(body.replace(/-/g, "+").replace(/_/g, "/"))) as State;
    return state.exp > Date.now() ? state : null;
  } catch {
    return null;
  }
}
