// Provider-neutral JSON completion. One interface, three adapters:
//
//   anthropic  Messages API, forced tool call → structured input
//   openai     Chat Completions with json_schema (or json_object) — also any
//              OpenAI-compatible endpoint via LLM_BASE_URL (OpenRouter, Mistral,
//              Groq, Together, DeepSeek, self-hosted vLLM/Ollama, …)
//   gemini     generateContent with responseMimeType application/json
//
// Whatever the provider returns is validated by the caller; no adapter is
// trusted to honour the schema. Selected at runtime by environment:
//   LLM_PROVIDER = anthropic | openai | gemini | none     (none = deterministic menu)
//   LLM_MODEL    = model id for that provider (chosen by the bake-off)
//   LLM_API_KEY  = provider key (Edge Function secret)
//   LLM_BASE_URL = optional, OpenAI-compatible endpoint
//   LLM_OPENAI_JSON_MODE = json_schema (default) | json_object (for endpoints without schema support)

export interface JsonRequest {
  /** Stable part of the prompt (rules, clinic data) — cacheable. */
  system: string;
  /** Per-message part. */
  user: string;
  /** JSON Schema of the expected object. */
  schema: Record<string, unknown>;
  schemaName: string;
  timeoutMs: number;
  maxTokens?: number;
}

export interface LLMClient {
  readonly name: string;
  completeJson(request: JsonRequest): Promise<unknown>;
}

export class LLMError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
  }
}

type Fetch = typeof fetch;

async function postJson(fetchFn: Fetch, url: string, headers: Record<string, string>, body: unknown, timeoutMs: number) {
  let response: Response;
  try {
    response = await fetchFn(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    throw new LLMError(`request failed: ${error}`);
  }
  const json = await response.json().catch(() => null);
  if (!response.ok) {
    throw new LLMError(`HTTP ${response.status}: ${JSON.stringify(json)?.slice(0, 300)}`, response.status);
  }
  return json;
}

function parseJsonText(text: string | undefined): unknown {
  if (!text) throw new LLMError("empty response");
  const cleaned = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/```$/, "").trim();
  try {
    return JSON.parse(cleaned);
  } catch {
    throw new LLMError("response is not JSON");
  }
}

// ---------------------------------------------------------------- Anthropic
export class AnthropicClient implements LLMClient {
  readonly name = "anthropic";
  constructor(private apiKey: string, private model: string, private fetchFn: Fetch = fetch,
              private baseUrl = "https://api.anthropic.com") {}

  async completeJson(r: JsonRequest): Promise<unknown> {
    const json = await postJson(this.fetchFn, `${this.baseUrl}/v1/messages`, {
      "x-api-key": this.apiKey,
      "anthropic-version": "2023-06-01",
    }, {
      model: this.model,
      max_tokens: r.maxTokens ?? 300,
      system: [{ type: "text", text: r.system, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: r.user }],
      tools: [{ name: r.schemaName, description: "Return the routing decision.", input_schema: r.schema }],
      tool_choice: { type: "tool", name: r.schemaName },
    }, r.timeoutMs);
    const block = (json?.content ?? []).find((c: { type: string }) => c.type === "tool_use");
    if (!block) throw new LLMError("no tool_use block in response");
    return block.input;
  }
}

// ---------------------------------------------------------------- OpenAI (and compatible)
export class OpenAICompatibleClient implements LLMClient {
  readonly name = "openai";
  constructor(private apiKey: string, private model: string, private fetchFn: Fetch = fetch,
              private baseUrl = "https://api.openai.com/v1", private jsonMode: "json_schema" | "json_object" = "json_schema") {}

  async completeJson(r: JsonRequest): Promise<unknown> {
    const responseFormat = this.jsonMode === "json_schema"
      ? { type: "json_schema", json_schema: { name: r.schemaName, schema: r.schema, strict: true } }
      : { type: "json_object" };
    const json = await postJson(this.fetchFn, `${this.baseUrl.replace(/\/$/, "")}/chat/completions`, {
      Authorization: `Bearer ${this.apiKey}`,
    }, {
      model: this.model,
      // No max_tokens / temperature: newer OpenAI models reject them, and the
      // answer is a small JSON object anyway.
      messages: [{ role: "system", content: r.system }, { role: "user", content: r.user }],
      response_format: responseFormat,
    }, r.timeoutMs);
    return parseJsonText(json?.choices?.[0]?.message?.content);
  }
}

// ---------------------------------------------------------------- Gemini
export class GeminiClient implements LLMClient {
  readonly name = "gemini";
  constructor(private apiKey: string, private model: string, private fetchFn: Fetch = fetch,
              private baseUrl = "https://generativelanguage.googleapis.com/v1beta") {}

  async completeJson(r: JsonRequest): Promise<unknown> {
    // The schema is also spelled out in the system prompt; JSON mode keeps the
    // output parseable. (Gemini's own schema dialect differs from JSON Schema,
    // so we validate ourselves instead of relying on it.)
    const json = await postJson(this.fetchFn, `${this.baseUrl}/models/${this.model}:generateContent`, {
      "x-goog-api-key": this.apiKey,
    }, {
      systemInstruction: { parts: [{ text: r.system }] },
      contents: [{ role: "user", parts: [{ text: r.user }] }],
      generationConfig: { responseMimeType: "application/json", maxOutputTokens: r.maxTokens ?? 300, temperature: 0 },
    }, r.timeoutMs);
    const parts = json?.candidates?.[0]?.content?.parts ?? [];
    return parseJsonText(parts.map((p: { text?: string }) => p.text ?? "").join(""));
  }
}

// ---------------------------------------------------------------- factory
export function createLLMFromEnv(get: (name: string) => string | undefined = (n) => Deno.env.get(n)): LLMClient | null {
  const provider = (get("LLM_PROVIDER") ?? "none").toLowerCase();
  if (provider === "none") return null;

  const model = get("LLM_MODEL");
  const key = get("LLM_API_KEY");
  if (!model || !key) throw new Error("LLM_PROVIDER is set but LLM_MODEL or LLM_API_KEY is missing");
  const baseUrl = get("LLM_BASE_URL");

  switch (provider) {
    case "anthropic":
      return new AnthropicClient(key, model, fetch, baseUrl ?? undefined);
    case "openai":
      return new OpenAICompatibleClient(key, model, fetch, baseUrl ?? undefined,
        get("LLM_OPENAI_JSON_MODE") === "json_object" ? "json_object" : "json_schema");
    case "gemini":
      return new GeminiClient(key, model, fetch, baseUrl ?? undefined);
    default:
      throw new Error(`Unknown LLM_PROVIDER "${provider}" (use anthropic, openai, gemini or none)`);
  }
}
