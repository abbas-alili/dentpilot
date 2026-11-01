// Settings: language, push notifications on this device, Google Calendar
// (dentists connect their own; admins any dentist), clinic settings (admins).
import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api, type CalendarLink, type ClinicSettings, type Professional } from "../lib/api";
import { LANGS, type TextKey, useI18n } from "../lib/i18n";
import { enablePush, pushState, type PushState } from "../lib/push";
import { ErrorBox, errorText, useBusy, useNotice } from "../components/ui";
import { useStaff } from "../components/session";

const CALENDAR_STATUS: Record<string, TextKey> = {
  connected: "cal_connected", cancelled: "cal_cancelled", invalid: "cal_invalid", failed: "cal_failed",
};

export function SettingsPage() {
  const { t, lang, setLang } = useI18n();
  const { profile, signOut } = useStaff();
  const [params] = useSearchParams();
  const calendarStatus = params.get("status");
  const { notice, ok, fail } = useNotice();
  const [busy, run] = useBusy();

  // Push
  const [push, setPush] = useState<PushState | null>(null);
  useEffect(() => { pushState().then(setPush).catch(() => setPush("unsupported")); }, []);
  const turnOnPush = () => run(async () => {
    try { setPush(await enablePush()); } catch (e) { fail(errorText(e, t)); }
  });

  // Google Calendar
  const isAdmin = profile.role === "admin";
  const [professionals, setProfessionals] = useState<Professional[]>([]);
  const [links, setLinks] = useState<CalendarLink[]>([]);
  const [loadError, setLoadError] = useState<unknown>(null);
  useEffect(() => {
    Promise.all([api.professionals(), api.calendarLinks()])
      .then(([p, l]) => { setProfessionals(p); setLinks(l); })
      .catch(setLoadError);
  }, []);
  const connectable = professionals.filter((p) => isAdmin || p.id === profile.professional_id);
  const connect = (professionalId: string) => run(async () => {
    try { window.location.assign(await api.googleConnectUrl(professionalId)); } catch (e) { fail(errorText(e, t)); }
  });

  // Clinic settings (admins)
  const [clinic, setClinic] = useState<ClinicSettings | null>(null);
  useEffect(() => {
    if (isAdmin) api.clinicSettings(profile.clinic_id).then(setClinic).catch(setLoadError);
  }, [isAdmin, profile.clinic_id]);
  const toggle = (key: keyof ClinicSettings) => run(async () => {
    if (!clinic) return;
    const next = { ...clinic, [key]: !clinic[key] };
    try { await api.updateClinicSettings(profile.clinic_id, { [key]: next[key] }); setClinic(next); ok(t("settings_saved")); }
    catch (e) { fail(errorText(e, t)); }
  });

  return (
    <section className="settings">
      <h1>{t("settings_title")}</h1>
      {calendarStatus && CALENDAR_STATUS[calendarStatus] && (
        <div className={`notice notice-${calendarStatus === "connected" ? "ok" : "error"}`} role="status">
          {t(CALENDAR_STATUS[calendarStatus])}
        </div>
      )}
      {notice}
      {loadError ? <ErrorBox error={loadError} /> : null}

      <h2>{t("settings_language")}</h2>
      <div className="segmented">
        {LANGS.map((l) => (
          <button key={l.code} className={lang === l.code ? "active" : ""} onClick={() => setLang(l.code)}>{l.label}</button>
        ))}
      </div>

      <h2>{t("settings_push")}</h2>
      {push === "on" && <p>{t("settings_push_on")}</p>}
      {push === "off" && <button className="primary" onClick={turnOnPush} disabled={busy}>{t("settings_push_enable")}</button>}
      {push === "denied" && <p className="muted">{t("settings_push_denied")}</p>}
      {push === "unsupported" && <p className="muted">{t("settings_push_unsupported")}</p>}

      {connectable.length > 0 && <h2>{t("settings_calendar")}</h2>}
      <ul className="rows">
        {connectable.map((p) => {
          const link = links.find((l) => l.professional_id === p.id);
          const broken = link?.status === "needs_reconnect";
          return (
            <li key={p.id} className="row">
              <div className="row-main">
                <strong>{p.display_name}</strong>
                <span className={broken ? "notice-error-text" : "muted"}>
                  {!link ? t("settings_calendar_none")
                    : broken ? t("settings_calendar_broken")
                    : t("settings_calendar_connected", { email: link.google_email ?? "" })}
                </span>
              </div>
              <button onClick={() => connect(p.id)} disabled={busy}>
                {link ? t("settings_calendar_reconnect") : t("settings_calendar_connect")}
              </button>
            </li>
          );
        })}
      </ul>

      {isAdmin && clinic && (
        <>
          <h2>{t("settings_clinic")}</h2>
          <label className="switch">
            <input type="checkbox" checked={clinic.shadow_mode} onChange={() => toggle("shadow_mode")} disabled={busy} />
            <span>{t("settings_shadow")}<small className="muted">{t("settings_shadow_hint")}</small></span>
          </label>
          <label className="switch">
            <input type="checkbox" checked={clinic.all_bookings_need_approval} onChange={() => toggle("all_bookings_need_approval")} disabled={busy} />
            <span>{t("settings_all_approval")}</span>
          </label>
        </>
      )}

      <hr />
      <button onClick={() => void signOut()}>{t("sign_out")}</button>
    </section>
  );
}
