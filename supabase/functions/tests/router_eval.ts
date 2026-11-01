// Router evaluation for the provider bake-off (evals.md). Calls the REAL
// provider configured in the environment — costs a few cents per run.
//
//   LLM_PROVIDER=anthropic LLM_MODEL=<model> LLM_API_KEY=<key> \
//     deno run -A supabase/functions/tests/router_eval.ts [path/to/golden.jsonl]
//
// Prints accuracy overall and per language, every miss, failures (null =
// invalid twice / provider error) and latency. Gate (evals.md): intent
// accuracy ≥ 92%. The bundled golden set is a DRAFT — replace it with ~150
// real, anonymised clinic messages before deciding.

import { createLLMFromEnv } from "../_shared/llm/providers.ts";
import { LLMRouter, type RouterInput } from "../_shared/router.ts";

interface Case { id: string; lang: "az" | "ru"; text: string; intent: string; faq_topic?: string }

const FAQ: Record<"az" | "ru", RouterInput["faq"]> = {
  az: [
    { id: "a0000000-0000-0000-0000-000000000001", topic: "hours", question: "İş saatlarınız neçədir?", altQuestions: ["Neçədə açılırsız?"] },
    { id: "a0000000-0000-0000-0000-000000000002", topic: "location", question: "Ünvanınız haradadır?", altQuestions: ["Necə gəlmək olar?"] },
    { id: "a0000000-0000-0000-0000-000000000003", topic: "price_range", question: "Plombun qiyməti nə qədərdir?", altQuestions: [] },
  ],
  ru: [
    { id: "b0000000-0000-0000-0000-000000000001", topic: "hours", question: "Какие у вас часы работы?", altQuestions: [] },
    { id: "b0000000-0000-0000-0000-000000000002", topic: "location", question: "Где вы находитесь?", altQuestions: [] },
    { id: "b0000000-0000-0000-0000-000000000003", topic: "price_range", question: "Сколько стоит пломба?", altQuestions: [] },
  ],
};

const path = Deno.args[0] ?? new URL("./evals/router_golden.jsonl", import.meta.url).pathname;
const cases: Case[] = (await Deno.readTextFile(path)).split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));

const llm = createLLMFromEnv();
if (!llm) throw new Error("Set LLM_PROVIDER, LLM_MODEL and LLM_API_KEY");
const router = new LLMRouter(llm, 15_000);

let correct = 0, failures = 0;
const perLang: Record<string, [number, number]> = {};
const latencies: number[] = [];
const misses: string[] = [];

for (const c of cases) {
  const input: RouterInput = {
    message: c.text, recentTurns: [], todayLocal: "2026-11-02", clinicName: "Avenue Dent",
    services: c.lang === "ru"
      ? [{ code: "svc_exam", name: "Осмотр" }, { code: "svc_clean", name: "Чистка" }, { code: "svc_fill", name: "Пломба" }]
      : [{ code: "svc_exam", name: "Müayinə" }, { code: "svc_clean", name: "Təmizləmə" }, { code: "svc_fill", name: "Plomb" }],
    dentists: ["Dr. Elvin", "Dr. Nərmin"],
    faq: FAQ[c.lang],
  };
  const started = performance.now();
  const d = await router.route(input);
  latencies.push(performance.now() - started);

  const topic = d?.kbEntryId ? FAQ[c.lang].find((f) => f.id === d.kbEntryId)?.topic : undefined;
  const ok = d !== null && d.intent === c.intent && (c.intent !== "faq" || topic === c.faq_topic);
  if (d === null) failures++;
  if (ok) correct++;
  else misses.push(`${c.id}  expected ${c.intent}${c.faq_topic ? "/" + c.faq_topic : ""}  got ${d ? d.intent + (topic ? "/" + topic : "") + ` (${d.confidence})` : "null"}  — ${c.text}`);
  perLang[c.lang] ??= [0, 0];
  perLang[c.lang][0] += ok ? 1 : 0;
  perLang[c.lang][1] += 1;
}

latencies.sort((a, b) => a - b);
const pct = (n: number, d: number) => `${((100 * n) / d).toFixed(1)}%`;
console.log(`\nprovider ${llm.name} · model ${Deno.env.get("LLM_MODEL")} · ${cases.length} cases`);
console.log(`intent accuracy  ${pct(correct, cases.length)}   (gate ≥ 92%)`);
for (const [lang, [ok, n]] of Object.entries(perLang)) console.log(`  ${lang}            ${pct(ok, n)}  (${ok}/${n})`);
console.log(`no decision      ${failures}`);
console.log(`latency p50/p95  ${latencies[Math.floor(latencies.length / 2)].toFixed(0)} / ${latencies[Math.floor(latencies.length * 0.95)].toFixed(0)} ms`);
if (misses.length) console.log("\nmisses:\n  " + misses.join("\n  "));
Deno.exit(correct / cases.length >= 0.92 ? 0 : 1);
