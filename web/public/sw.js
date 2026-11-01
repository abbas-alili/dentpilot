// Service worker: shows staff push notifications and opens the right screen.
// Payload from run-jobs: { title, body, kind, detail, conversation_id, appointment_id }.

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { /* plain text */ }
  const title = data.title || "DentPilot";
  event.waitUntil(self.registration.showNotification(title, {
    body: data.body || "",
    icon: "/icon.svg",
    tag: data.conversation_id || data.appointment_id || data.kind || "dentpilot",
    renotify: data.kind === "escalation",
    requireInteraction: data.kind === "escalation",
    data,
  }));
});

function targetFor(data) {
  switch (data.kind) {
    case "escalation":
    case "handover":
      return data.conversation_id ? `/conversations/${data.conversation_id}` : "/conversations";
    case "draft_waiting":
      return "/";
    case "pending_approval":
    case "approval_reminder":
      return "/bookings";
    case "calendar_disconnected":
      return "/settings";
    default:
      return "/";
  }
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = targetFor(event.notification.data || {});
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of windows) {
      if ("focus" in client) {
        await client.navigate(url);
        return client.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});
