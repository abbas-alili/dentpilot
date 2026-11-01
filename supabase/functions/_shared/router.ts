// The LLM router (Stage E2). It ONLY classifies: free text → one intent, or
// one approved FAQ entry id. It never writes text for the patient — every
// reply is a reviewed template or an approved FAQ answer sent word for word.
//
//   prompt (stable rules + clinic + FAQ list | message + recent turns)
//   → provider JSON → strict validation → one retry with the error → null
//   null / low confidence → caller shows the menu (decision E2-3)
//
// The emergency gate has already run before the router is called.

import { createLLMFromEnv, type LLMClient } from "./llm/providers.ts";
import type { Lang } from "./i18n.ts";
import { log } from "./log.ts";

export const INTENTS = [
  "book",                // wants an appointment / asks for free times
  "reschedule",          // move an existing appointment
  "cancel",              // cancel an existing appointment
  "confirm_attendance",  // "I'll come", confirms an upcoming visit
  "faq",                 // answered by one approved FAQ entry (kb_entry_id required)
  "opt_out",             // stop reminders
  "human_request",       // wants a person / administrator / a call back
  "clinical_question",   // symptoms, treatment, medicine, aftercare → a dentist must answer
  "complaint",           // unhappy about service, billing, a past treatment
  "greeting",            // hello / how are you, nothing else
  "thanks",              // thank you / ok, conversation closing
  "other",               // none of the above
] as const;

export type Intent = typeof INTENTS[number];

export interface RouterDecision {
  intent: Intent;
  kbEntryId: string | null;
  language: Lang | "other";
  confidence: number;
}

export interface RouterInput {
  message: string;
  recentTurns: { from: "patient" | "clinic"; text: string }[];
  todayLocal: string;                                  // YYYY-MM-DD, clinic time
  clinicName: string;
  services: { code: string; name: string }[];
  dentists: string[];
  faq: { id: string; topic: string; question: string; altQuestions: string[] }[];
}

export const CONFIDENCE_THRESHOLD = 0.6;

export const ROUTER_SCHEMA = {
  type: "object",
  properties: {
    intent: { type: "string", enum: [...INTENTS] },
    kb_entry_id: { type: ["string", "null"] },
    language: { type: "string", enum: ["az", "ru", "other"] },
    confidence: { type: "number" },
    reason: { type: "string" },
  },
  required: ["intent", "kb_entry_id", "language", "confidence", "reason"],
  additionalProperties: false,
} as const;

// ---------------------------------------------------------------- prompt
export function buildPrompt(input: RouterInput): { system: string; user: string } {
  // Stable first (cacheable): rules, then clinic data and FAQ list.
  const system = `You route WhatsApp messages sent by patients to a dental clinic in Azerbaijan.
Patients write in Azerbaijani (Latin script, often without ə ğ ı ş ç ö ü, sometimes in Cyrillic) or Russian, and mix them.
You do NOT reply to the patient. You only classify the latest message.

Return exactly one JSON object:
{"intent": <one of ${INTENTS.join(", ")}>, "kb_entry_id": <FAQ id or null>, "language": "az"|"ru"|"other", "confidence": <0..1>, "reason": <max 15 English words>}

Rules:
- "faq" only when ONE entry below answers the question; set kb_entry_id to its id exactly. Otherwise kb_entry_id is null.
- Any question about symptoms, pain, treatment choice, medicine, or what to do after a procedure is "clinical_question", even if an FAQ entry looks related.
- Asking whether there is a free time, or wanting to come in, is "book". Moving an existing visit is "reschedule".
- Prices: "faq" only if a price entry exists below; otherwise "human_request".
- If unsure, use a lower confidence rather than guessing. Never invent ids.

Clinic: ${input.clinicName}
Services: ${input.services.map((s) => s.name).join("; ") || "—"}
Dentists: ${input.dentists.join("; ") || "—"}

FAQ entries (id | topic | question | other phrasings):
${input.faq.map((f) => `${f.id} | ${f.topic} | ${f.question} | ${f.altQuestions.join(" / ")}`).join("\n") || "(none)"}`;

  const turns = input.recentTurns.map((t) => `${t.from}: ${t.text}`).join("\n");
  const user = `Today (clinic time): ${input.todayLocal}
Recent conversation (oldest first):
${turns || "(none)"}

Latest patient message:
"""${input.message.slice(0, 1000)}"""`;

  return { system, user };
}

// ---------------------------------------------------------------- validation
export function validateDecision(raw: unknown, faqIds: Set<string>): RouterDecision | string {
  if (typeof raw !== "object" || raw === null) return "not an object";
  const r = raw as Record<string, unknown>;
  if (!INTENTS.includes(r.intent as Intent)) return `invalid intent ${JSON.stringify(r.intent)}`;
  if (!["az", "ru", "other"].includes(r.language as string)) return "invalid language";
  if (typeof r.confidence !== "number" || r.confidence < 0 || r.confidence > 1) return "confidence must be 0..1";

  const kb = r.kb_entry_id ?? null;
  if (r.intent === "faq") {
    if (typeof kb !== "string" || !faqIds.has(kb)) return `kb_entry_id ${JSON.stringify(kb)} is not one of the listed FAQ ids`;
  } else if (kb !== null) {
    return "kb_entry_id must be null unless intent is faq";
  }

  return {
    intent: r.intent as Intent,
    kbEntryId: kb as string | null,
    language: r.language as RouterDecision["language"],
    confidence: r.confidence,
  };
}

// ---------------------------------------------------------------- routing
export interface Router {
  route(input: RouterInput): Promise<RouterDecision | null>;
}

export class LLMRouter implements Router {
  constructor(private llm: LLMClient, private timeoutMs = 8_000) {}

  async route(input: RouterInput): Promise<RouterDecision | null> {
    const { system, user } = buildPrompt(input);
    const faqIds = new Set(input.faq.map((f) => f.id));
    let userText = user;

    for (let attempt = 1; attempt <= 2; attempt++) {
      let raw: unknown;
      try {
        raw = await this.llm.completeJson({
          system, user: userText, schema: ROUTER_SCHEMA, schemaName: "route_message", timeoutMs: this.timeoutMs,
        });
      } catch (error) {
        log.warn("router.llm_failed", { provider: this.llm.name, attempt, error: String(error) });
        return null;   // transport/provider problem: don't retry here, fall back to the menu
      }
      const decision = validateDecision(raw, faqIds);
      if (typeof decision !== "string") {
        log.info("router.decision", { provider: this.llm.name, intent: decision.intent, confidence: decision.confidence });
        return decision;
      }
      log.warn("router.invalid_output", { provider: this.llm.name, attempt, problem: decision });
      userText = `${user}\n\nYour previous answer was invalid (${decision}). Return only the JSON object.`;
    }
    return null;
  }
}

/** Test double: returns queued decisions and records inputs. */
export class FakeRouter implements Router {
  calls: RouterInput[] = [];
  constructor(private next: (input: RouterInput) => RouterDecision | null) {}
  route(input: RouterInput): Promise<RouterDecision | null> {
    this.calls.push(input);
    return Promise.resolve(this.next(input));
  }
}

/** Router from LLM_* environment variables, or undefined when LLM_PROVIDER=none (E1 menu behaviour). */
export function createRouterFromEnv(): Router | undefined {
  const llm = createLLMFromEnv();
  return llm ? new LLMRouter(llm) : undefined;
}
