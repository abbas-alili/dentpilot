// calendar-feed — GET /calendar-feed/<token>.ics → the dentist's appointments.
// Connects as dentpilot_agent; core.calendar_feed_events resolves the token
// itself (SECURITY DEFINER) and returns nothing for unknown/revoked tokens.
// Unknown tokens still get 200 + an empty calendar, so tokens can't be probed.

import { withoutClinic } from "../_shared/db.ts";
import { type FeedEvent, renderCalendar } from "../_shared/ics.ts";
import { log } from "../_shared/log.ts";

export function createFeedHandler() {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "GET") return new Response("method not allowed", { status: 405 });

    const token = new URL(req.url).pathname.split("/").pop()?.replace(/\.ics$/, "") ?? "";
    let events: FeedEvent[] = [];
    if (/^[0-9a-f]{64}$/.test(token)) {
      try {
        const rows = await withoutClinic((tx) => tx`select * from core.calendar_feed_events(${token})`);
        events = rows.map((r) => ({
          uid: r.uid, sequence: r.sequence, startsAt: r.starts_at, endsAt: r.ends_at,
          summary: r.summary, tentative: r.tentative, lastModified: r.last_modified,
        }));
      } catch (error) {
        log.error("feed.failed", { error: String(error) });
        return new Response("temporarily unavailable", { status: 503 });
      }
    }

    return new Response(renderCalendar("DentPilot", events), {
      status: 200,
      headers: {
        "Content-Type": "text/calendar; charset=utf-8",
        "Cache-Control": "private, max-age=300",
      },
    });
  };
}
