// Today: one day's bookings per dentist (to check against the paper diary),
// with arrived / done / no-show / cancel.
import { useState } from "react";
import { Link } from "react-router-dom";
import { api, type DayRow } from "../lib/api";
import { formatDate, todayIn } from "../lib/format";
import { type TextKey, useI18n } from "../lib/i18n";
import { usePolling } from "../lib/usePolling";
import { Empty, ErrorBox, errorText, Loading, PatientLine, useBusy, useNotice } from "../components/ui";
import { useStaff } from "../components/session";

export function TodayPage() {
  const { t, lang } = useI18n();
  const { profile } = useStaff();
  const [date, setDate] = useState(todayIn(profile.timezone));
  const [mine, setMine] = useState(Boolean(profile.professional_id));
  const dentist = mine ? profile.professional_id : null;
  const day = usePolling(() => api.daySchedule(date, dentist), [date, dentist], 30_000);
  const { notice, fail } = useNotice();

  return (
    <section>
      <h1>{t("today_title")}</h1>
      <div className="toolbar">
        <input type="date" aria-label="date" value={date} onChange={(e) => e.target.value && setDate(e.target.value)} />
        {profile.professional_id && (
          <div className="segmented">
            <button className={mine ? "active" : ""} onClick={() => setMine(true)}>{t("today_mine")}</button>
            <button className={!mine ? "active" : ""} onClick={() => setMine(false)}>{t("today_all")}</button>
          </div>
        )}
      </div>
      <p className="muted">{formatDate(date, lang)}</p>
      {notice}
      {day.loading && !day.data && <Loading />}
      {day.error ? <ErrorBox error={day.error} onRetry={day.reload} /> : null}
      {day.data?.length === 0 && <Empty>{t("today_empty")}</Empty>}
      <ul className="rows">
        {day.data?.map((row) => (
          <DayItem key={row.appointment_id} row={row} showDentist={!mine}
            onChanged={day.reload} onError={async (e) => { fail(errorText(e, t)); await day.reload(); }} />
        ))}
      </ul>
    </section>
  );
}

function DayItem({ row, showDentist, onChanged, onError }: {
  row: DayRow; showDentist: boolean; onChanged: () => Promise<void>; onError: (e: unknown) => Promise<void>;
}) {
  const { t } = useI18n();
  const [busy, run] = useBusy();
  const set = (status: string) => run(async () => {
    if (status === "cancelled" && !window.confirm(t("today_confirm_cancel"))) return;
    try { await api.setAppointmentStatus(row.appointment_id, row.version, status); await onChanged(); }
    catch (e) { await onError(e); }
  });

  const actions: { status: string; label: TextKey }[] =
    row.status === "booked" || row.status === "confirmed"
      ? [{ status: "checked_in", label: "today_arrived" }, { status: "no_show", label: "today_no_show" }, { status: "cancelled", label: "today_cancel" }]
      : row.status === "checked_in" ? [{ status: "completed", label: "today_done" }] : [];

  return (
    <li className={`row day st-${row.status}`}>
      <div className="time">{row.local_start}<span className="muted">–{row.local_end}</span></div>
      <div className="row-main">
        <PatientLine name={row.patient_name} waId={row.wa_id} />
        <span className="muted">{row.service_name}{showDentist ? ` · ${row.professional_name}` : ""}</span>
        <span className={`status st-${row.status}`}>{t(`st_${row.status}` as TextKey)}</span>
      </div>
      <div className="actions compact">
        {row.status === "pending_approval" && <Link className="link" to="/bookings">{t("today_review")}</Link>}
        {actions.map((a) => (
          <button key={a.status} className={a.status === "cancelled" ? "danger" : ""} onClick={() => set(a.status)} disabled={busy}>
            {t(a.label)}
          </button>
        ))}
      </div>
    </li>
  );
}
