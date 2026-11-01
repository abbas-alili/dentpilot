// Router and provider adapter tests — no network: fetch is faked per provider.
import { assert, assertEquals, assertRejects } from "./assert.ts";
import {
  AnthropicClient, createLLMFromEnv, GeminiClient, type JsonRequest, LLMError, OpenAICompatibleClient,
} from "../_shared/llm/providers.ts";
import { buildPrompt, LLMRouter, type RouterInput, ROUTER_SCHEMA, validateDecision } from "../_shared/router.ts";

const FAQ_ID = "11111111-1111-1111-1111-111111111111";

const input: RouterInput = {
  message: "Sabah saat 3-ə yer var?",
  recentTurns: [{ from: "clinic", text: "Salam!" }],
  todayLocal: "2026-11-02",
  clinicName: "Avenue Dent",
  services: [{ code: "svc_exam", name: "Müayinə" }],
  dentists: ["Dr. Elvin"],
  faq: [{ id: FAQ_ID, topic: "hours", question: "İş saatlarınız?", altQuestions: ["Neçədə açılırsız?"] }],
};

const request: JsonRequest = {
  system: "SYS", user: "USER", schema: ROUTER_SCHEMA as unknown as Record<string, unknown>,
  schemaName: "route_message", timeoutMs: 1000,
};

/** A fetch that records the call and answers with `body`. */
function fakeFetch(body: unknown, status = 200) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fn = ((url: string, init: RequestInit) => {
    calls.push({ url, init });
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as unknown as typeof fetch;
  return { fn, calls, sent: () => JSON.parse(String(calls[0].init.body)) };
}

const DECISION = { intent: "book", kb_entry_id: null, language: "az", confidence: 0.9, reason: "asks for a slot" };

// ---------------------------------------------------------------- adapters
Deno.test("Anthropic adapter: forced tool call, cached system prompt, reads tool input", async () => {
  const f = fakeFetch({ content: [{ type: "tool_use", name: "route_message", input: DECISION }] });
  const out = await new AnthropicClient("KEY", "model-x", f.fn).completeJson(request);
  assertEquals(out, DECISION);
  assertEquals(f.calls[0].url, "https://api.anthropic.com/v1/messages");
  const headers = f.calls[0].init.headers as Record<string, string>;
  assertEquals([headers["x-api-key"], headers["anthropic-version"]], ["KEY", "2023-06-01"]);
  const body = f.sent();
  assertEquals(body.model, "model-x");
  assertEquals(body.tool_choice, { type: "tool", name: "route_message" });
  assertEquals(body.system[0].cache_control, { type: "ephemeral" });
  assertEquals(body.tools[0].input_schema.required.length, 5);
});

Deno.test("OpenAI adapter: strict json_schema, custom base URL, parses content", async () => {
  const f = fakeFetch({ choices: [{ message: { content: JSON.stringify(DECISION) } }] });
  const out = await new OpenAICompatibleClient("KEY", "m", f.fn, "https://openrouter.example/api/v1/").completeJson(request);
  assertEquals(out, DECISION);
  assertEquals(f.calls[0].url, "https://openrouter.example/api/v1/chat/completions");
  assertEquals((f.calls[0].init.headers as Record<string, string>).Authorization, "Bearer KEY");
  const body = f.sent();
  assertEquals(body.response_format.type, "json_schema");
  assertEquals(body.response_format.json_schema.strict, true);
  assert(!("max_tokens" in body), "no max_tokens: newer models reject it");
});

Deno.test("OpenAI adapter: json_object mode for endpoints without schema support", async () => {
  const f = fakeFetch({ choices: [{ message: { content: "```json\n" + JSON.stringify(DECISION) + "\n```" } }] });
  const out = await new OpenAICompatibleClient("KEY", "m", f.fn, undefined, "json_object").completeJson(request);
  assertEquals(out, DECISION, "code fences are tolerated");
  assertEquals(f.sent().response_format, { type: "json_object" });
});

Deno.test("Gemini adapter: JSON mode, system instruction, joins parts", async () => {
  const text = JSON.stringify(DECISION);
  const f = fakeFetch({ candidates: [{ content: { parts: [{ text: text.slice(0, 10) }, { text: text.slice(10) }] } }] });
  const out = await new GeminiClient("KEY", "gem-x", f.fn).completeJson(request);
  assertEquals(out, DECISION);
  assertEquals(f.calls[0].url, "https://generativelanguage.googleapis.com/v1beta/models/gem-x:generateContent");
  assertEquals((f.calls[0].init.headers as Record<string, string>)["x-goog-api-key"], "KEY");
  const body = f.sent();
  assertEquals(body.generationConfig.responseMimeType, "application/json");
  assertEquals(body.systemInstruction.parts[0].text, "SYS");
});

Deno.test("adapters raise LLMError on HTTP errors and non-JSON output", async () => {
  await assertRejects(() => new AnthropicClient("K", "m", fakeFetch({ error: "x" }, 429).fn).completeJson(request), LLMError, "HTTP 429");
  await assertRejects(
    () => new OpenAICompatibleClient("K", "m", fakeFetch({ choices: [{ message: { content: "hello" } }] }).fn).completeJson(request),
    LLMError, "not JSON",
  );
});

Deno.test("createLLMFromEnv: none, each provider, and configuration errors", () => {
  const env = (vars: Record<string, string>) => (n: string) => vars[n];
  assertEquals(createLLMFromEnv(env({})), null);
  assertEquals(createLLMFromEnv(env({ LLM_PROVIDER: "none" })), null);
  for (const p of ["anthropic", "openai", "gemini"]) {
    assertEquals(createLLMFromEnv(env({ LLM_PROVIDER: p, LLM_MODEL: "m", LLM_API_KEY: "k" }))?.name, p);
  }
  let threw = false;
  try { createLLMFromEnv(env({ LLM_PROVIDER: "anthropic" })); } catch { threw = true; }
  assert(threw, "missing model/key is a startup error");
});

// ---------------------------------------------------------------- prompt + validation
Deno.test("prompt: stable part holds rules, clinic and FAQ ids; message goes last", () => {
  const { system, user } = buildPrompt(input);
  assert(system.includes(FAQ_ID) && system.includes("Müayinə") && system.includes("clinical_question"));
  assert(!system.includes("Sabah saat 3"), "the message is not in the cacheable part");
  assert(user.includes("2026-11-02") && user.endsWith('"""Sabah saat 3-ə yer var?"""'));
});

Deno.test("validateDecision: accepts valid, rejects invented ids and malformed output", () => {
  const ids = new Set([FAQ_ID]);
  assertEquals(validateDecision({ ...DECISION, intent: "faq", kb_entry_id: FAQ_ID }, ids), {
    intent: "faq", kbEntryId: FAQ_ID, language: "az", confidence: 0.9,
  });
  assert(typeof validateDecision({ ...DECISION, intent: "faq", kb_entry_id: "made-up" }, ids) === "string");
  assert(typeof validateDecision({ ...DECISION, kb_entry_id: FAQ_ID }, ids) === "string", "id only with faq");
  assert(typeof validateDecision({ ...DECISION, intent: "diagnose" }, ids) === "string");
  assert(typeof validateDecision({ ...DECISION, confidence: 7 }, ids) === "string");
  assert(typeof validateDecision("book", ids) === "string");
});

Deno.test("LLMRouter: retries once with the validation error, then succeeds", async () => {
  const answers: unknown[] = [{ intent: "faq", kb_entry_id: "bogus", language: "az", confidence: 0.9, reason: "" },
                              { ...DECISION }];
  const seen: string[] = [];
  const router = new LLMRouter({ name: "fake", completeJson: (r) => { seen.push(r.user); return Promise.resolve(answers.shift()); } });
  const decision = await router.route(input);
  assertEquals(decision?.intent, "book");
  assertEquals(seen.length, 2);
  assert(seen[1].includes("previous answer was invalid"));
});

Deno.test("LLMRouter: gives up (null → menu) after two invalid answers or a provider error", async () => {
  const always = new LLMRouter({ name: "fake", completeJson: () => Promise.resolve({ intent: "nope" }) });
  assertEquals(await always.route(input), null);
  const down = new LLMRouter({ name: "fake", completeJson: () => Promise.reject(new LLMError("HTTP 503", 503)) });
  assertEquals(await down.route(input), null);
});
