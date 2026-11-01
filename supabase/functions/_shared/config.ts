// Environment configuration. Every value is an Edge Function secret
// (`supabase secrets set NAME=value`); nothing secret lives in code.
// Each function reads only what it needs, when it needs it, so a missing
// secret fails loudly in the one function that uses it.

export function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

export function envOr(name: string, fallback: string): string {
  return Deno.env.get(name) || fallback;
}

/** Names of every secret the functions use (see SOP.md, "Edge Functions"). */
export const SECRETS = {
  agentDbUrl: "DENTPILOT_AGENT_DB_URL",      // postgres://dentpilot_agent.<ref>:<pw>@<pooler>:6543/postgres
  waAccessToken: "WA_ACCESS_TOKEN",           // system-user token for the Cloud API
  waAppSecret: "WA_APP_SECRET",               // signs webhooks and Flow requests (X-Hub-Signature-256)
  waVerifyToken: "WA_VERIFY_TOKEN",           // random string; webhook subscription handshake
  waGraphVersion: "WA_GRAPH_VERSION",         // e.g. "v23.0" — pin to the version you tested
  flowPrivateKey: "FLOW_PRIVATE_KEY",         // RSA private key, PKCS#8 PEM, unencrypted
  flowIdAz: "WA_FLOW_ID_AZ",                  // published booking Flow, Azerbaijani labels
  flowIdRu: "WA_FLOW_ID_RU",                  // published booking Flow, Russian labels
  cronSecret: "DENTPILOT_CRON_SECRET",        // same value as Vault 'dentpilot_cron_secret'
  vapidPublic: "VAPID_PUBLIC_KEY",
  vapidPrivate: "VAPID_PRIVATE_KEY",
  vapidSubject: "VAPID_SUBJECT",              // mailto:ops@your-domain
} as const;
