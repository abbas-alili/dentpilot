// Load data, refresh it every `intervalMs` and when the tab regains focus.
// (Live updates via Supabase Realtime are Step 3.)
import { useCallback, useEffect, useRef, useState } from "react";

export interface Loaded<T> {
  data: T | null;
  error: unknown;
  loading: boolean;
  reload: () => Promise<void>;
}

export function usePolling<T>(load: () => Promise<T>, deps: unknown[], intervalMs = 20_000): Loaded<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [loading, setLoading] = useState(true);
  const loadRef = useRef(load);
  loadRef.current = load;

  const reload = useCallback(async () => {
    try {
      setData(await loadRef.current());
      setError(null);
    } catch (e) {
      setError(e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    setLoading(true);
    void reload();
    const timer = setInterval(() => void reload(), intervalMs);
    const onFocus = () => void reload();
    window.addEventListener("focus", onFocus);
    return () => {
      clearInterval(timer);
      window.removeEventListener("focus", onFocus);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return { data, error, loading, reload };
}
