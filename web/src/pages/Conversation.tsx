// One conversation: the full thread, a reply box (free text only inside
// WhatsApp's 24-hour window), and "hand back to bot" / "close".
import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { api, type Message } from "../lib/api";
import { formatStamp } from "../lib/format";
import { type TextKey, useI18n } from "../lib/i18n";
import { usePolling } from "../lib/usePolling";
import { ErrorBox, errorText, Loading, PatientLine, useBusy, useNotice } from "../components/ui";
import { useStaff } from "../components/session";
import { statusKey } from "./Conversations";

export function ConversationPage() {
  const { id = "" } = useParams();
  const { t } = useI18n();
  const { refreshCounts } = useStaff();
  const info = usePolling(() => api.conversationInfo(id), [id], 15_000);
  const messages = usePolling(() => api.messages(id), [id], 15_000);
  const [reply, setReply] = useState("");
  const [busy, run] = useBusy();
  const { notice, fail } = useNotice();

  const reloadAll = () => Promise.all([info.reload(), messages.reload(), refreshCounts()]).then(() => undefined);

  const send = () => run(async () => {
    try { await api.sendReply(id, reply.trim()); setReply(""); await reloadAll(); }
    catch (e) { fail(errorText(e, t)); await reloadAll(); }
  });
  const setStatus = (status: "assistant" | "closed") => run(async () => {
    try { await api.setConversationStatus(id, status); await reloadAll(); }
    catch (e) { fail(errorText(e, t)); await reloadAll(); }
  });

  const c = info.data;
  return (
    <section className="thread">
      <Link to="/conversations" className="link">← {t("back")}</Link>
      {info.error ? <ErrorBox error={info.error} onRetry={info.reload} /> : null}
      {!c && info.loading && <Loading />}
      {c && (
        <div className="thread-head">
          <PatientLine name={c.patient_name} waId={c.wa_id} />
          <span className={`status status-${c.status}`}>{t(statusKey(c.status))}</span>
          {c.status_reason && <span className="muted small">{c.status_reason}</span>}
        </div>
      )}
      {notice}
      <ol className="bubbles">
        {messages.data?.map((m) => <Bubble key={m.message_id} m={m} />)}
      </ol>
      {c && c.status !== "closed" && (
        <>
          {c.window_open ? (
            <div className="composer">
              <textarea aria-label={t("conv_reply_placeholder")} placeholder={t("conv_reply_placeholder")}
                value={reply} onChange={(e) => setReply(e.target.value)} rows={3} disabled={busy} />
              <button className="primary" onClick={send} disabled={busy || !reply.trim()}>{t("conv_send")}</button>
            </div>
          ) : (
            <p className="notice notice-error">{t("conv_window_closed")}</p>
          )}
          <div className="actions">
            {c.status !== "assistant" && <button onClick={() => setStatus("assistant")} disabled={busy}>{t("conv_return_to_bot")}</button>}
            <button onClick={() => setStatus("closed")} disabled={busy}>{t("conv_close")}</button>
          </div>
        </>
      )}
    </section>
  );
}

function Bubble({ m }: { m: Message }) {
  const { t } = useI18n();
  const from: TextKey | null = m.direction === "in" ? null
    : m.source === "staff" ? "conv_from_staff" : m.source === "doctor_echo" ? "conv_from_doctor" : "conv_from_bot";
  const state: TextKey | null = m.delivery_status === "draft" ? "conv_draft"
    : m.delivery_status === "discarded" ? "conv_discarded" : m.delivery_status === "failed" ? "conv_failed" : null;
  const text = m.body ?? (m.template_name ? `[${m.template_name}]` : `[${m.kind}]`);

  return (
    <li className={`bubble ${m.direction}${state ? ` ${m.delivery_status}` : ""}`}>
      {from && <span className="muted small">{t(from)}</span>}
      <p>{text}</p>
      <span className="muted small">{formatStamp(m.created_at)}{state ? ` · ${t(state)}` : ""}</span>
    </li>
  );
}
