// Routes and the sign-in gate.
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { Layout } from "./components/Layout";
import { StaffGate, useAuthSession } from "./components/session";
import { Loading } from "./components/ui";
import { BookingsPage } from "./pages/Bookings";
import { ConversationPage } from "./pages/Conversation";
import { ConversationsPage } from "./pages/Conversations";
import { InboxPage } from "./pages/Inbox";
import { LoginPage, NoAccessPage, SetPasswordPage } from "./pages/Login";
import { SettingsPage } from "./pages/Settings";
import { TodayPage } from "./pages/Today";

export function AppRoutes() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<InboxPage />} />
        <Route path="bookings" element={<BookingsPage />} />
        <Route path="conversations" element={<ConversationsPage />} />
        <Route path="conversations/:id" element={<ConversationPage />} />
        <Route path="today" element={<TodayPage />} />
        <Route path="settings" element={<SettingsPage />} />
        <Route path="settings/calendar" element={<SettingsPage />} />   {/* Google OAuth returns here */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

export function App() {
  const { session, ready, recovery } = useAuthSession();
  if (!ready) return <Loading />;
  if (recovery) return <SetPasswordPage />;
  if (!session) return <LoginPage />;
  return (
    <BrowserRouter>
      <StaffGate key={session.user.id} loading={<Loading />} noAccess={<NoAccessPage />}>
        <AppRoutes />
      </StaffGate>
    </BrowserRouter>
  );
}
