// Who is signed in: the Supabase session, the staff profile, and the badge
// counts shared by the navigation and the screens.
import { createContext, type ReactNode, useContext, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { api, type Counts, type Profile } from "../lib/api";
import { supabase } from "../lib/supabase";
import { usePolling } from "../lib/usePolling";

interface StaffSession {
  profile: Profile;
  counts: Counts | null;
  refreshCounts: () => Promise<void>;
  signOut: () => Promise<void>;
}

const SessionContext = createContext<StaffSession | null>(null);

export function useStaff(): StaffSession {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error("useStaff outside StaffProvider");
  return ctx;
}

/** For tests and previews: provide a session directly. */
export function StaffProvider({ value, children }: { value: StaffSession; children: ReactNode }) {
  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

/** Supabase session state, including the password-recovery flow. */
export function useAuthSession(): { session: Session | null; ready: boolean; recovery: boolean } {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [recovery, setRecovery] = useState(false);

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data } = supabase.auth.onAuthStateChange((event, next) => {
      setSession(next);
      if (event === "PASSWORD_RECOVERY") setRecovery(true);
      if (event === "USER_UPDATED") setRecovery(false);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  return { session, ready, recovery };
}

/** Loads the profile once signed in; renders `noAccess` if the user isn't staff. */
export function StaffGate({ children, loading, noAccess }: { children: ReactNode; loading: ReactNode; noAccess: ReactNode }) {
  const [profile, setProfile] = useState<Profile | null | undefined>(undefined);

  useEffect(() => {
    api.profile().then((rows) => setProfile(rows[0] ?? null)).catch(() => setProfile(null));
  }, []);
  const counts = usePolling(() => api.counts(), [profile?.clinic_id], 20_000);

  if (profile === undefined) return <>{loading}</>;
  if (profile === null) return <>{noAccess}</>;

  return (
    <StaffProvider value={{
      profile,
      counts: counts.data,
      refreshCounts: counts.reload,
      signOut: async () => { await supabase.auth.signOut(); },
    }}>
      {children}
    </StaffProvider>
  );
}
