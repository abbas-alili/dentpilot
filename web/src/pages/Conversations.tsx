// Conversations list: "needs attention" first (emergencies on top), or all open.
import { useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../lib/api";
import { formatStamp } from "../lib/format";
import { type TextKey, useI18n } from "../lib/i18n";
import { usePolling } from "../lib/usePolling";
import { Empty, ErrorBox, Loading } from "../components/ui";

type Filter = "attention" | "open" | "all";

export function statusKey(status: string): TextKey {
  return (`conv_status_${status}` as TextKey);
}

export function ConversationsPage() {
  const { t } = useI18n();
  const [filter, setFilter] = useState<Filter>("attention");
  const list = usePolling(() => api.conversations(filter), [filter]);

  return (
    <section>
      <h1>{t("conv_title")}</h1>
      <div className="segmented" role="tablist">
        {(["attention", "open", "all"] as Filter[]).map((f) => (
          <button key={f} role="tab" aria-selected={filter === f} className={filter === f ? "active" : ""}
            onClick={() => setFilter(f)}>{t(`conv_filter_${f}` as TextKey)}</button>
        ))}
      </div>
      {list.loading && !list.data && <Loading />}
      {list.error ? <ErrorBox error={list.error} onRetry={list.reload} /> : null}
      {list.data?.length === 0 && <Empty>{t("conv_empty")}</Empty>}
      <ul className="rows">
        {list.data?.map((c) => (
          <li key={c.conversation_id}>
            <Link to={`/conversations/${c.conversation_id}`} className="row">
              <div className="row-main">
                <strong>{c.patient_name || `+${c.wa_id}`}</strong>
                <span className="muted ellipsis">{c.last_preview}</span>
              </div>
              <div className="row-side">
                <span className={`status status-${c.status}`}>{t(statusKey(c.status))}</span>
                <span className="muted small">{formatStamp(c.last_message_at)}</span>
                {c.drafts > 0 && <span className="small">{t("conv_drafts", { n: c.drafts })}</span>}
              </div>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}
