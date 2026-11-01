// Structured logs (JSON lines). NEVER log message text, names or phone
// numbers — only ids, kinds and error codes. Supabase keeps function logs.

type Fields = Record<string, unknown>;

function write(level: "info" | "warn" | "error", event: string, fields: Fields = {}): void {
  console[level](JSON.stringify({ level, event, ...fields, at: new Date().toISOString() }));
}

export const log = {
  info: (event: string, fields?: Fields) => write("info", event, fields),
  warn: (event: string, fields?: Fields) => write("warn", event, fields),
  error: (event: string, fields?: Fields) => write("error", event, fields),
};
