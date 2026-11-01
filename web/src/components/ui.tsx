// Small shared UI pieces.
import { type ReactNode, useState } from "react";
import { AppError } from "../lib/api";
import { type TextKey, useI18n } from "../lib/i18n";

/** Error message in the staff member's language. */
export function errorText(error: unknown, t: (k: TextKey) => string): string {
  if (error instanceof AppError) {
    const keys: Record<string, TextKey> = {
      window_closed: "err_window_closed", overlap: "err_overlap", stale: "err_stale", network: "err_network",
    };
    if (keys[error.kind]) return t(keys[error.kind]);
  }
  return t("error_generic");
}

export function ErrorBox({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const { t } = useI18n();
  return (
    <div className="notice notice-error" role="alert">
      {errorText(error, t)}
      {onRetry && <button className="link" onClick={onRetry}>{t("retry")}</button>}
    </div>
  );
}

export function Loading() {
  const { t } = useI18n();
  return <p className="muted" aria-busy="true">{t("loading")}</p>;
}

export function Empty({ children }: { children: ReactNode }) {
  return <p className="empty">{children}</p>;
}

/** A transient success/error line after an action. */
export function useNotice() {
  const [notice, setNotice] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const view = notice && (
    <div className={`notice notice-${notice.kind}`} role={notice.kind === "error" ? "alert" : "status"}>{notice.text}</div>
  );
  return { notice: view, ok: (text: string) => setNotice({ kind: "ok", text }), fail: (text: string) => setNotice({ kind: "error", text }) };
}

/** Runs an action once at a time; returns [busy, run]. */
export function useBusy(): [boolean, (fn: () => Promise<void>) => Promise<void>] {
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<void>) => {
    if (busy) return;
    setBusy(true);
    try { await fn(); } finally { setBusy(false); }
  };
  return [busy, run];
}

export function PatientLine({ name, waId }: { name: string | null; waId: string }) {
  return (
    <div className="patient">
      <strong>{name || `+${waId}`}</strong>
      {name && <a className="muted phone" href={`tel:+${waId}`}>+{waId}</a>}
    </div>
  );
}
