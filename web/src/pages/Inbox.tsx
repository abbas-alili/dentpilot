// Inbox: the bot's drafts waiting for approval (shadow mode), oldest first.
// Each shows the patient's message it answers; staff send it as is, edit then
// send, or discard. Templates can't be edited (their wording is fixed by Meta).
import { useState } from "react";
import { api, type Draft } from "../lib/api";
import { formatStamp } from "../lib/format";
import { useI18n } from "../lib/i18n";
import { usePolling } from "../lib/usePolling";
import { Empty, ErrorBox, errorText, Loading, PatientLine, useBusy, useNotice } from "../components/ui";
import { useStaff } from "../components/session";

export function InboxPage() {
  const { t } = useI18n();
  const { refreshCounts } = useStaff();
  const drafts = usePolling(() => api.drafts(), []);
  const { notice, ok, fail } = useNotice();

  const done = async (message: string) => {
    ok(message);
    await Promise.all([drafts.reload(), refreshCounts()]);
  };

  return (
    <section>
      <h1>{t("inbox_title")}</h1>
      {notice}
      {drafts.loading && !drafts.data && <Loading />}
      {drafts.error ? <ErrorBox error={drafts.error} onRetry={drafts.reload} /> : null}
      {drafts.data?.length === 0 && <Empty>{t("inbox_empty")}</Empty>}
      <ul className="cards">
        {drafts.data?.map((d) => (
          <DraftCard key={d.message_id} draft={d}
            onSent={() => done(t("inbox_sent"))}
            onDiscarded={() => done(t("inbox_discarded"))}
            onError={async (e) => { fail(errorText(e, t)); await drafts.reload(); }} />
        ))}
      </ul>
    </section>
  );
}

function DraftCard({ draft, onSent, onDiscarded, onError }: {
  draft: Draft;
  onSent: () => Promise<void>;
  onDiscarded: () => Promise<void>;
  onError: (e: unknown) => Promise<void>;
}) {
  const { t } = useI18n();
  const [text, setText] = useState(draft.body ?? "");
  const [busy, run] = useBusy();
  const isTemplate = draft.kind === "template";
  const blocked = !isTemplate && !draft.window_open;   // WhatsApp would reject free text

  const send = () => run(async () => {
    try {
      const edited = draft.editable && text.trim() !== (draft.body ?? "").trim() ? text.trim() : null;
      await api.approveDraft(draft.message_id, edited);
      await onSent();
    } catch (e) { await onError(e); }
  });
  const discard = () => run(async () => {
    try { await api.discardDraft(draft.message_id); await onDiscarded(); } catch (e) { await onError(e); }
  });

  return (
    <li className="card">
      <div className="card-head">
        <PatientLine name={draft.patient_name} waId={draft.wa_id} />
        <span className="muted small">{formatStamp(draft.created_at)}</span>
      </div>
      {draft.replying_to && (
        <blockquote className="quote">
          <span className="muted small">{t("inbox_replying_to")}</span>
          <p>{draft.replying_to}</p>
        </blockquote>
      )}
      {isTemplate ? (
        <p className="template">{t("inbox_template", { name: draft.template_name ?? "" })}</p>
      ) : (
        <>
          <textarea aria-label="draft" value={text} disabled={!draft.editable || busy}
            onChange={(e) => setText(e.target.value)} rows={Math.min(8, Math.max(3, text.split("\n").length + 1))} />
          {draft.kind === "interactive" && <p className="muted small">{t("inbox_interactive_note")}</p>}
        </>
      )}
      {blocked && <p className="notice notice-error">{t("err_window_closed")}</p>}
      <div className="actions">
        <button className="primary" onClick={send} disabled={busy || blocked || (draft.editable && !text.trim())}>{t("inbox_send")}</button>
        <button onClick={discard} disabled={busy}>{t("inbox_discard")}</button>
      </div>
    </li>
  );
}
