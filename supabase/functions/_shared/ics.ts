// Minimal iCalendar (RFC 5545) writer for the dentists' subscribed calendar.
// Times are written in UTC ("Z"), so no VTIMEZONE block is needed.

export interface FeedEvent {
  uid: string;
  sequence: number;
  startsAt: Date;
  endsAt: Date;
  summary: string;
  tentative: boolean;
  lastModified: Date;
}

function utc(d: Date): string {
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");   // 20261102T103000Z
}

function escapeText(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

/** Fold lines longer than 75 octets (UTF-8 aware), continuation lines start with a space. */
function fold(line: string): string {
  const bytes = new TextEncoder();
  const parts: string[] = [];
  let current = "";
  for (const ch of line) {
    const limit = parts.length === 0 ? 75 : 74;   // continuation lines carry a leading space
    if (bytes.encode(current + ch).length > limit) {
      parts.push(current);
      current = ch;
    } else {
      current += ch;
    }
  }
  parts.push(current);
  return parts.join("\r\n ");
}

export function renderCalendar(name: string, events: FeedEvent[], now = new Date()): string {
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//DentPilot//Calendar Feed//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    `X-WR-CALNAME:${escapeText(name)}`,
    "REFRESH-INTERVAL;VALUE=DURATION:PT15M",
    "X-PUBLISHED-TTL:PT15M",
  ];
  for (const e of events) {
    lines.push(
      "BEGIN:VEVENT",
      `UID:${e.uid}@dentpilot`,
      `SEQUENCE:${e.sequence}`,
      `DTSTAMP:${utc(now)}`,
      `DTSTART:${utc(e.startsAt)}`,
      `DTEND:${utc(e.endsAt)}`,
      `SUMMARY:${escapeText(e.summary)}`,
      `STATUS:${e.tentative ? "TENTATIVE" : "CONFIRMED"}`,
      `LAST-MODIFIED:${utc(e.lastModified)}`,
      "END:VEVENT",
    );
  }
  lines.push("END:VCALENDAR");
  return lines.map(fold).join("\r\n") + "\r\n";
}
