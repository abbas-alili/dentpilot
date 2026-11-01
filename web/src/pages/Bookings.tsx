// Bookings: requests waiting for the doctor (every booking needs approval at
// Avenue Dent). The doctor sets the real duration; the choices stop at the
// time until her next booking, so approving can't create a collision.
import { useState } from "react";
import { api, type PendingBooking } from "../lib/api";
import { durationOptions, formatDate, formatTime } from "../lib/format";
import { useI18n } from "../lib/i18n";
import { usePolling } from "../lib/usePolling";
import { Empty, ErrorBox, errorText, Loading, PatientLine, useBusy, useNotice } from "../components/ui";
import { useStaff } from "../components/session";

export function BookingsPage() {
  const { t } = useI18n();
  const { refreshCounts } = useStaff();
  const bookings = usePolling(() => api.pendingBookings(), []);
  const { notice, ok, fail } = useNotice();

  const after = async (message: string | null, error?: unknown) => {
    if (error) fail(errorText(error, t)); else if (message) ok(message);
    await Promise.all([bookings.reload(), refreshCounts()]);
  };

  return (
    <section>
      <h1>{t("bookings_title")}</h1>
      {notice}
      {bookings.loading && !bookings.data && <Loading />}
      {bookings.error ? <ErrorBox error={bookings.error} onRetry={bookings.reload} /> : null}
      {bookings.data?.length === 0 && <Empty>{t("bookings_empty")}</Empty>}
      <ul className="cards">
        {bookings.data?.map((b) => <BookingCard key={b.appointment_id} booking={b} after={after} />)}
      </ul>
    </section>
  );
}

function BookingCard({ booking: b, after }: { booking: PendingBooking; after: (m: string | null, e?: unknown) => Promise<void> }) {
  const { t, lang } = useI18n();
  const [minutes, setMinutes] = useState(b.held_minutes);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, run] = useBusy();

  const approve = () => run(async () => {
    try { await api.approveBooking(b.appointment_id, b.version, minutes); await after(t("bookings_approved")); }
    catch (e) { await after(null, e); }
  });
  const reject = () => run(async () => {
    try { await api.rejectBooking(b.appointment_id, b.version, reason.trim() || null); await after(t("bookings_rejected")); }
    catch (e) { await after(null, e); }
  });

  return (
    <li className="card">
      <div className="card-head">
        <PatientLine name={b.patient_name} waId={b.wa_id} />
      </div>
      <p className="big">{formatDate(b.local_start, lang)} · {formatTime(b.local_start)}</p>
      <p>{b.service_name} · {b.professional_name}</p>
      <label className="field">
        <span>{t("bookings_duration")}</span>
        <select aria-label={t("bookings_duration")} value={minutes} disabled={busy}
          onChange={(e) => setMinutes(Number(e.target.value))}>
          {durationOptions(b.held_minutes, b.max_duration_minutes).map((m) => (
            <option key={m} value={m}>{t("minutes", { n: m })}</option>
          ))}
        </select>
      </label>
      <p className="muted small">{t("bookings_held", { n: b.held_minutes })} · {t("bookings_max", { n: b.max_duration_minutes })}</p>
      {rejecting && (
        <label className="field">
          <span>{t("bookings_reject_reason")}</span>
          <input value={reason} onChange={(e) => setReason(e.target.value)} disabled={busy} />
        </label>
      )}
      <div className="actions">
        {!rejecting && <button className="primary" onClick={approve} disabled={busy}>{t("bookings_approve")}</button>}
        {rejecting
          ? <>
              <button className="danger" onClick={reject} disabled={busy}>{t("bookings_reject")}</button>
              <button onClick={() => setRejecting(false)} disabled={busy}>{t("cancel")}</button>
            </>
          : <button onClick={() => setRejecting(true)} disabled={busy}>{t("bookings_reject")}</button>}
      </div>
    </li>
  );
}
