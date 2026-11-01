// Screens with the API mocked: what staff see and what each button calls.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { vi } from "vitest";
import type { ReactNode } from "react";

const mockApi = vi.hoisted(() => ({
  drafts: vi.fn(), approveDraft: vi.fn(), discardDraft: vi.fn(),
  pendingBookings: vi.fn(), approveBooking: vi.fn(), rejectBooking: vi.fn(),
  conversationInfo: vi.fn(), messages: vi.fn(), sendReply: vi.fn(), setConversationStatus: vi.fn(),
  daySchedule: vi.fn(), setAppointmentStatus: vi.fn(), counts: vi.fn(),
}));
vi.mock("../lib/api", async (original) => ({ ...(await original<typeof import("../lib/api")>()), api: mockApi }));

import { AppError } from "../lib/api";
import { I18nProvider } from "../lib/i18n";
import { StaffProvider } from "../components/session";
import { Layout } from "../components/Layout";
import { InboxPage } from "../pages/Inbox";
import { BookingsPage } from "../pages/Bookings";
import { ConversationPage } from "../pages/Conversation";
import { TodayPage } from "../pages/Today";

const profile = {
  clinic_id: "c1", clinic_name: "Avenue Dent", timezone: "Asia/Baku", role: "dentist" as const,
  professional_id: "d1", professional_name: "Dr. Ayten", shadow_mode: true,
};

function renderAt(path: string, element: ReactNode, route = path, counts = null as never) {
  return render(
    <I18nProvider lang="en">
      <StaffProvider value={{ profile, counts, refreshCounts: async () => {}, signOut: async () => {} }}>
        <MemoryRouter initialEntries={[path]}>
          <Routes><Route path={route} element={element} /></Routes>
        </MemoryRouter>
      </StaffProvider>
    </I18nProvider>,
  );
}

const draft = {
  message_id: "m1", conversation_id: "cv1", patient_id: "p1", patient_name: "Leyla", wa_id: "994501112233",
  language: "az", kind: "text", body: "Bəli, saat 10:00 boşdur.", template_name: null, editable: true,
  created_at: "2026-11-02T08:00:00Z", replying_to: "Sabah yer var?", conversation_status: "assistant", window_open: true,
};

beforeEach(() => vi.resetAllMocks());

describe("Inbox", () => {
  it("shows the draft under the patient's message and sends the edited text", async () => {
    mockApi.drafts.mockResolvedValue([draft]);
    mockApi.approveDraft.mockResolvedValue(undefined);
    renderAt("/", <InboxPage />);

    expect(await screen.findByText("Sabah yer var?")).toBeTruthy();
    const box = screen.getByLabelText("draft") as HTMLTextAreaElement;
    expect(box.value).toBe("Bəli, saat 10:00 boşdur.");

    fireEvent.change(box, { target: { value: "Bəli, saat 10:00 boşdur. Gözləyirik!" } });
    fireEvent.click(screen.getByText("Send"));
    await waitFor(() => expect(mockApi.approveDraft).toHaveBeenCalledWith("m1", "Bəli, saat 10:00 boşdur. Gözləyirik!"));
    expect(await screen.findByText("Sent.")).toBeTruthy();
  });

  it("sends unchanged text as approved-as-is (no edit recorded)", async () => {
    mockApi.drafts.mockResolvedValue([draft]);
    renderAt("/", <InboxPage />);
    fireEvent.click(await screen.findByText("Send"));
    await waitFor(() => expect(mockApi.approveDraft).toHaveBeenCalledWith("m1", null));
  });

  it("blocks free text outside the 24-hour window but allows templates", async () => {
    mockApi.drafts.mockResolvedValue([
      { ...draft, window_open: false },
      { ...draft, message_id: "m2", kind: "template", body: null, template_name: "dentpilot_reminder", editable: false, window_open: false },
    ]);
    renderAt("/", <InboxPage />);
    const sends = await screen.findAllByText("Send");
    expect((sends[0] as HTMLButtonElement).disabled).toBe(true);
    expect((sends[1] as HTMLButtonElement).disabled).toBe(false);
    expect(screen.getByText("Template: dentpilot_reminder")).toBeTruthy();
  });

  it("discards", async () => {
    mockApi.drafts.mockResolvedValue([draft]);
    renderAt("/", <InboxPage />);
    fireEvent.click(await screen.findByText("Don't send"));
    await waitFor(() => expect(mockApi.discardDraft).toHaveBeenCalledWith("m1"));
  });
});

describe("Bookings", () => {
  const booking = {
    appointment_id: "a1", version: 1, patient_name: "Leyla", wa_id: "994501112233", service_name: "Plomb",
    service_minutes: 45, buffer_minutes: 10, professional_id: "d1", professional_name: "Dr. Ayten",
    local_start: "2026-11-05T10:00", held_minutes: 45, max_duration_minutes: 80, requested_at: "", booked_by: "assistant",
  };

  it("offers durations only up to the next booking and approves with the chosen one", async () => {
    mockApi.pendingBookings.mockResolvedValue([booking]);
    renderAt("/bookings", <BookingsPage />);
    const select = (await screen.findByLabelText("Duration")) as HTMLSelectElement;
    expect([...select.options].map((o) => o.value)).toEqual(["15", "30", "45", "60", "75"]);
    expect(select.value).toBe("45");
    fireEvent.change(select, { target: { value: "75" } });
    fireEvent.click(screen.getByText("Approve"));
    await waitFor(() => expect(mockApi.approveBooking).toHaveBeenCalledWith("a1", 1, 75));
  });

  it("explains an overlap in words", async () => {
    mockApi.pendingBookings.mockResolvedValue([booking]);
    mockApi.approveBooking.mockRejectedValue(new AppError("overlap", "23P01"));
    renderAt("/bookings", <BookingsPage />);
    fireEvent.click(await screen.findByText("Approve"));
    expect(await screen.findByText("That duration overlaps the next booking.")).toBeTruthy();
  });

  it("rejects with an optional reason", async () => {
    mockApi.pendingBookings.mockResolvedValue([booking]);
    renderAt("/bookings", <BookingsPage />);
    fireEvent.click(await screen.findByText("Reject"));
    fireEvent.change(screen.getByLabelText("Reason for rejecting (optional)"), { target: { value: "Həkim məzuniyyətdədir" } });
    fireEvent.click(screen.getByText("Reject"));
    await waitFor(() => expect(mockApi.rejectBooking).toHaveBeenCalledWith("a1", 1, "Həkim məzuniyyətdədir"));
  });
});

describe("Conversation", () => {
  const info = { conversation_id: "cv1", patient_name: "Leyla", wa_id: "994501112233", language: "az",
                 status: "escalated", status_reason: "emergency:pain", version: 2, window_open: true };

  it("shows the thread with drafts marked, and replies", async () => {
    mockApi.conversationInfo.mockResolvedValue(info);
    mockApi.messages.mockResolvedValue([
      { message_id: "1", direction: "in", source: "patient", kind: "text", body: "Dişim ağrıyır", template_name: null, delivery_status: null, edited: false, created_at: "2026-11-02T08:00:00Z" },
      { message_id: "2", direction: "out", source: "assistant", kind: "text", body: "Həkimə çatdırdıq", template_name: null, delivery_status: "draft", edited: false, created_at: "2026-11-02T08:00:01Z" },
    ]);
    renderAt("/conversations/cv1", <ConversationPage />, "/conversations/:id");
    expect(await screen.findByText("Dişim ağrıyır")).toBeTruthy();
    expect(screen.getByText("Urgent")).toBeTruthy();
    expect(screen.getByText(/Draft/)).toBeTruthy();

    fireEvent.change(screen.getByLabelText("Write a reply…"), { target: { value: "Salam, 30 dəqiqəyə gələ bilərsiniz." } });
    fireEvent.click(screen.getByText("Send"));
    await waitFor(() => expect(mockApi.sendReply).toHaveBeenCalledWith("cv1", "Salam, 30 dəqiqəyə gələ bilərsiniz."));
  });

  it("hides free text when the window is closed, and can hand back to the bot", async () => {
    mockApi.conversationInfo.mockResolvedValue({ ...info, status: "handed_to_staff", window_open: false });
    mockApi.messages.mockResolvedValue([]);
    renderAt("/conversations/cv1", <ConversationPage />, "/conversations/:id");
    expect(await screen.findByText(/hasn't written for over 24 hours/)).toBeTruthy();
    expect(screen.queryByLabelText("Write a reply…")).toBeNull();
    fireEvent.click(screen.getByText("Hand back to bot"));
    await waitFor(() => expect(mockApi.setConversationStatus).toHaveBeenCalledWith("cv1", "assistant"));
  });
});

describe("Today", () => {
  it("lists the day and offers the right actions per status", async () => {
    mockApi.daySchedule.mockResolvedValue([
      { appointment_id: "a1", version: 3, local_start: "10:00", local_end: "10:45", patient_name: "Leyla", wa_id: "1",
        service_name: "Plomb", professional_id: "d1", professional_name: "Dr. Ayten", status: "booked", booked_by: "assistant" },
      { appointment_id: "a2", version: 1, local_start: "11:30", local_end: "12:15", patient_name: "Orxan", wa_id: "2",
        service_name: "Müayinə", professional_id: "d1", professional_name: "Dr. Ayten", status: "checked_in", booked_by: "staff" },
    ]);
    renderAt("/today", <TodayPage />);
    expect(await screen.findByText("Leyla")).toBeTruthy();
    expect(mockApi.daySchedule.mock.calls[0][1]).toBe("d1");   // a dentist sees her own day first

    fireEvent.click(screen.getByText("Arrived"));
    await waitFor(() => expect(mockApi.setAppointmentStatus).toHaveBeenCalledWith("a1", 3, "checked_in"));
    fireEvent.click(screen.getByText("Done"));
    await waitFor(() => expect(mockApi.setAppointmentStatus).toHaveBeenCalledWith("a2", 1, "completed"));
  });
});

describe("Layout", () => {
  it("shows badge counts on the navigation", () => {
    render(
      <I18nProvider lang="az">
        <StaffProvider value={{ profile, counts: { drafts: 3, pending_bookings: 1, attention: 2, unread_notifications: 0 },
                                refreshCounts: async () => {}, signOut: async () => {} }}>
          <MemoryRouter><Routes><Route path="/" element={<Layout />} /></Routes></MemoryRouter>
        </StaffProvider>
      </I18nProvider>,
    );
    expect(screen.getByText("Gələnlər").parentElement?.textContent).toContain("3");
    expect(screen.getByText("Söhbətlər").parentElement?.textContent).toContain("2");
    expect(screen.getByText("Kölgə rejimi")).toBeTruthy();
  });
});
