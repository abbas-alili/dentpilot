// A fake Google: OAuth token endpoint + Calendar events API, as an injectable fetch.
export class FakeGoogle {
  events = new Map<string, any>();                 // eventId → last body
  calls: string[] = [];
  revokedRefreshTokens = new Set<string>();

  fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => Promise.resolve(this.handle(input, init))) as typeof fetch;

  private handle(input: string | URL | Request, init?: RequestInit): Response {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    this.calls.push(`${method} ${url.pathname}`);

    if (url.href === "https://oauth2.googleapis.com/token") {
      const form = new URLSearchParams(String(init?.body));
      if (form.get("grant_type") === "refresh_token") {
        if (this.revokedRefreshTokens.has(form.get("refresh_token")!)) {
          return Response.json({ error: "invalid_grant", error_description: "Token has been expired or revoked." }, { status: 400 });
        }
        return Response.json({ access_token: "access-1", expires_in: 3600 });
      }
      const payload = btoa(JSON.stringify({ email: "ayten@gmail.example" })).replace(/=+$/, "");
      return Response.json({ access_token: "access-0", refresh_token: "refresh-from-code", id_token: `h.${payload}.s` });
    }

    const match = url.pathname.match(/^\/calendar\/v3\/calendars\/([^/]+)\/events(?:\/([^/]+))?$/);
    if (!match) return new Response("not found", { status: 404 });
    const [, , eventId] = match;
    const body = init?.body ? JSON.parse(String(init.body)) : null;

    if (method === "PUT") {
      if (!this.events.has(eventId)) return new Response("{}", { status: 404 });
      this.events.set(eventId, body);
      return Response.json(body);
    }
    if (method === "POST") {
      this.events.set(body.id, body);
      return Response.json(body);
    }
    if (method === "DELETE") {
      return new Response(null, { status: this.events.delete(eventId) ? 204 : 410 });
    }
    return new Response("unsupported", { status: 400 });
  }
}
