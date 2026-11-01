// Sign in with email + password (W1). Accounts are created by an admin.
// "Forgot password" emails a link; following it opens SetPasswordPage.
import { type FormEvent, useState } from "react";
import { supabase } from "../lib/supabase";
import { LANGS, useI18n } from "../lib/i18n";

export function LoginPage() {
  const { t, lang, setLang } = useI18n();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const signIn = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (error) setMessage({ kind: "error", text: t("login_invalid") });
  };

  const forgot = async () => {
    if (!email.trim()) return;
    setBusy(true);
    await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: window.location.origin });
    setBusy(false);
    setMessage({ kind: "ok", text: t("login_reset_sent") });   // same answer whether or not the email exists
  };

  return (
    <main className="login">
      <h1>DentPilot</h1>
      <form onSubmit={signIn}>
        <h2>{t("login_title")}</h2>
        <label className="field"><span>{t("login_email")}</span>
          <input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label className="field"><span>{t("login_password")}</span>
          <input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        {message && <p className={`notice notice-${message.kind}`} role="status">{message.text}</p>}
        <button className="primary" type="submit" disabled={busy}>{t("login_submit")}</button>
        <button type="button" className="link" onClick={forgot} disabled={busy}>{t("login_forgot")}</button>
      </form>
      <div className="segmented">
        {LANGS.map((l) => (
          <button key={l.code} className={lang === l.code ? "active" : ""} onClick={() => setLang(l.code)}>{l.label}</button>
        ))}
      </div>
    </main>
  );
}

export function SetPasswordPage() {
  const { t } = useI18n();
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState<string | null>(null);

  const save = async (e: FormEvent) => {
    e.preventDefault();
    const { error } = await supabase.auth.updateUser({ password });
    setMessage(error ? t("error_generic") : t("login_password_set"));
  };

  return (
    <main className="login">
      <form onSubmit={save}>
        <h2>{t("login_new_password")}</h2>
        <label className="field"><span>{t("login_new_password")}</span>
          <input type="password" autoComplete="new-password" minLength={8} required value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        {message && <p className="notice" role="status">{message}</p>}
        <button className="primary" type="submit">{t("login_set_password")}</button>
      </form>
    </main>
  );
}

export function NoAccessPage() {
  const { t } = useI18n();
  return (
    <main className="login">
      <p className="notice notice-error">{t("login_no_access")}</p>
      <button onClick={() => void supabase.auth.signOut()}>{t("sign_out")}</button>
    </main>
  );
}
