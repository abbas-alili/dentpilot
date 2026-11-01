// The Supabase client: the app talks to the database as the signed-in staff
// member (role "authenticated"), so row-level security applies to everything.
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const supabaseConfigured = Boolean(url && anonKey);

export const supabase: SupabaseClient = createClient(url ?? "http://localhost", anonKey ?? "missing", {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

export const functionsUrl = `${url ?? ""}/functions/v1`;
