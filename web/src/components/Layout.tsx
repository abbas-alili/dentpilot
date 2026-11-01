// App frame: clinic name on top, navigation with badges at the bottom (thumb reach on phones).
import { NavLink, Outlet } from "react-router-dom";
import { useI18n } from "../lib/i18n";
import { useStaff } from "./session";

export function Layout() {
  const { t } = useI18n();
  const { profile, counts } = useStaff();

  const items = [
    { to: "/", label: t("nav_inbox"), badge: counts?.drafts, end: true },
    { to: "/bookings", label: t("nav_bookings"), badge: counts?.pending_bookings },
    { to: "/conversations", label: t("nav_conversations"), badge: counts?.attention, urgent: true },
    { to: "/today", label: t("nav_today") },
    { to: "/settings", label: t("nav_settings") },
  ];

  return (
    <div className="frame">
      <header className="topbar">
        <span className="brand">DentPilot</span>
        <span className="muted">{profile.clinic_name}</span>
        {profile.shadow_mode && <span className="pill">{t("settings_shadow")}</span>}
      </header>
      <main className="content">
        <Outlet />
      </main>
      <nav className="tabbar" aria-label="Main">
        {items.map((item) => (
          <NavLink key={item.to} to={item.to} end={item.end} className={({ isActive }) => `tab${isActive ? " active" : ""}`}>
            <span>{item.label}</span>
            {item.badge ? <span className={`badge${item.urgent ? " urgent" : ""}`}>{item.badge}</span> : null}
          </NavLink>
        ))}
      </nav>
    </div>
  );
}
