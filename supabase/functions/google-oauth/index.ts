// Entry point. Deploy with JWT verification off: Google's redirect to /callback
// carries no Supabase JWT. /start checks the staff JWT itself (Supabase Auth),
// /callback checks the HMAC-signed state.
import { env } from "../_shared/config.ts";
import { GoogleCalendarClient } from "../_shared/gcal.ts";
import { createOAuthHandler } from "./handler.ts";

const supabaseUrl = env("SUPABASE_URL");          // provided by Supabase
const anonKey = env("SUPABASE_ANON_KEY");         // provided by Supabase

Deno.serve(createOAuthHandler({
  google: new GoogleCalendarClient(),
  clientId: env("GOOGLE_CLIENT_ID"),
  redirectUri: env("GOOGLE_REDIRECT_URI"),
  stateSecret: env("OAUTH_STATE_SECRET"),
  staffAppUrl: env("STAFF_APP_URL"),
  verifyUser: async (jwt) => {
    const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${jwt}`, apikey: anonKey },
    });
    if (!response.ok) return null;
    return (await response.json())?.id ?? null;
  },
}));
