// Unit tests — no database, no network.  deno test -A supabase/functions/tests/unit_test.ts
import { assert, assertEquals, assertRejects } from "./assert.ts";
import {
  decryptFlowRequest, encryptFlowResponse, fromBase64, hmacSha256Hex, importFlowPrivateKey, toBase64,
  verifyMetaSignature,
} from "../_shared/crypto.ts";
import { emergencyGate } from "../_shared/emergency_gate.ts";
import { detectLanguage, fill, formatDate } from "../_shared/i18n.ts";
import { renderCalendar } from "../_shared/ics.ts";
import { TEXTS } from "../_shared/texts.ts";
import { parseWebhook } from "../_shared/webhook_parse.ts";
import { encryptAsMeta, generateFlowKeys } from "./helpers.ts";

// ---------------------------------------------------------------- crypto
Deno.test("Flow encryption: decrypt a Meta-style request and answer with the flipped IV", async () => {
  const keys = await generateFlowKeys();
  const privateKey = await importFlowPrivateKey(keys.privatePem);
  const { request, aesKey, iv } = await encryptAsMeta({ action: "ping", version: "3.0" }, keys.publicKey);

  const decrypted = await decryptFlowRequest(request, privateKey);
  assertEquals(decrypted.payload, { action: "ping", version: "3.0" });

  const answer = await encryptFlowResponse({ data: { status: "active" } }, decrypted.aesKey, decrypted.iv);
  const key = await crypto.subtle.importKey("raw", aesKey, "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: iv.map((b) => b ^ 0xff) }, key, fromBase64(answer));
  assertEquals(JSON.parse(new TextDecoder().decode(plain)), { data: { status: "active" } });
});

Deno.test("Flow key must be unencrypted PKCS#8, with a helpful error otherwise", async () => {
  await assertRejects(() => importFlowPrivateKey("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"),
    Error, "openssl pkcs8");
});

Deno.test("Meta signature: correct accepted, forged or missing rejected", async () => {
  const body = '{"x":1}';
  const good = "sha256=" + await hmacSha256Hex("secret", body);
  assert(await verifyMetaSignature("secret", body, good));
  assert(!(await verifyMetaSignature("secret", body + " ", good)));
  assert(!(await verifyMetaSignature("other", body, good)));
  assert(!(await verifyMetaSignature("secret", body, null)));
});

Deno.test("base64 round trip on binary data", () => {
  const bytes = new Uint8Array(70_000);   // > one 0x8000 chunk, to exercise the chunked encoder
  for (let i = 0; i < bytes.length; i += 65_536) crypto.getRandomValues(bytes.subarray(i, i + 65_536));
  assertEquals(fromBase64(toBase64(bytes)), bytes);
});

// ---------------------------------------------------------------- webhook parsing
Deno.test("parseWebhook: every message kind the pipeline routes on", () => {
  const msg = (m: Record<string, unknown>) => ({ from: "994551112233", id: `wamid.${m.type}`, timestamp: "1767000000", ...m });
  const events = parseWebhook({
    entry: [{
      changes: [{
        field: "messages",
        value: {
          metadata: { phone_number_id: "PN" },
          contacts: [{ wa_id: "994551112233", profile: { name: "Leyla" } }],
          messages: [
            msg({ type: "text", text: { body: "Salam" } }),
            msg({ type: "interactive", id: "wamid.list", interactive: { type: "list_reply", list_reply: { id: "menu:book", title: "Randevu al" } } }),
            msg({ type: "interactive", id: "wamid.btn", interactive: { type: "button_reply", button_reply: { id: "cancel:no", title: "Xeyr" } } }),
            msg({ type: "interactive", id: "wamid.nfm", interactive: { type: "nfm_reply", nfm_reply: { response_json: '{"hold_id":"x"}' } } }),
            msg({ type: "button", button: { payload: "remind:confirm:abc", text: "Gələcəyəm" } }),
            msg({ type: "image", image: { id: "MEDIA1", mime_type: "image/jpeg", caption: "şəkil" } }),
            msg({ type: "contacts", contacts: [] }),
          ],
          statuses: [{ id: "wamid.out", status: "delivered" }, { id: "wamid.out", status: "deleted" }],
        },
      }],
    }],
  });

  const inbound = events.filter((e) => e.type === "inbound");
  assertEquals(inbound.map((e) => [e.kind, e.body]), [
    ["text", "Salam"], ["interactive", "menu:book"], ["interactive", "cancel:no"],
    ["flow_reply", '{"hold_id":"x"}'], ["interactive", "remind:confirm:abc"], ["image", "şəkil"], ["unsupported", null],
  ]);
  assertEquals(inbound[0].type === "inbound" && inbound[0].profileName, "Leyla");
  assertEquals(inbound[5].type === "inbound" && inbound[5].mediaId, "MEDIA1");
  assertEquals(events.filter((e) => e.type === "status").length, 1, "unknown statuses are ignored");
});

Deno.test("parseWebhook: Coexistence echoes", () => {
  const events = parseWebhook({
    entry: [{ changes: [{ field: "smb_message_echoes", value: {
      metadata: { phone_number_id: "PN" },
      message_echoes: [{ from: "99412000000", to: "994551112233", id: "wamid.echo", timestamp: "1767000000", type: "text", text: { body: "Salam" } }],
    } }] }],
  });
  assertEquals(events, [{ type: "echo", phoneNumberId: "PN", waMessageId: "wamid.echo", patientWaId: "994551112233",
    kind: "text", body: "Salam", sentAt: new Date(1767000000 * 1000) }]);
});

// ---------------------------------------------------------------- language and dates
Deno.test("formatDate in both languages", () => {
  assertEquals(formatDate("2026-11-02", "az"), "2 noyabr, bazar ertəsi");
  assertEquals(formatDate("2026-11-02", "ru"), "2 ноября, понедельник");
  assertEquals(formatDate("2026-11-08T10:00", "az"), "8 noyabr, bazar");
});

Deno.test("detectLanguage", () => {
  assertEquals(detectLanguage("Salam, sabah yer var?"), "az");
  assertEquals(detectLanguage("Sabah üçün yer var?"), "az");
  assertEquals(detectLanguage("Дишим агрыйыр"), "ru");            // AZ in Cyrillic without special letters reads as RU
  assertEquals(detectLanguage("Сабаһ јер вар?"), "az");          // AZ Cyrillic letters
  assertEquals(detectLanguage("Здравствуйте, хочу записаться"), "ru");
  assertEquals(detectLanguage("👍"), null);
});

// ---------------------------------------------------------------- texts
Deno.test("every text exists in both languages and fits WhatsApp limits", () => {
  for (const [key, value] of Object.entries(TEXTS)) {
    assert(value.az.trim() && value.ru.trim(), `${key} has both languages`);
    const az = value.az.match(/\{\w+\}/g)?.sort().join() ?? "";
    const ru = value.ru.match(/\{\w+\}/g)?.sort().join() ?? "";
    assertEquals(az, ru, `${key}: same placeholders in az and ru`);
  }
  const limits: [keyof typeof TEXTS, number][] = [
    ["menu_book", 24], ["menu_reschedule", 24], ["menu_cancel", 24], ["menu_hours", 24], ["menu_location", 24],
    ["menu_staff", 24], ["menu_other_language", 24], ["menu_button", 20], ["cancel_yes", 20], ["cancel_no", 20],
    ["book_flow_cta", 20], ["reschedule_flow_cta", 20],
  ];
  for (const [key, max] of limits) {
    for (const lang of ["az", "ru"] as const) {
      assert([...TEXTS[key][lang]].length <= max, `${key}.${lang} ≤ ${max} chars: "${TEXTS[key][lang]}"`);
    }
  }
  assertEquals(fill("{a} {b}", { a: 1 }), "1 {b}", "unknown placeholders stay visible");
});

// ---------------------------------------------------------------- calendar
Deno.test("ICS: escaping, CRLF, 75-octet folding", () => {
  const ics = renderCalendar("DentPilot", [{
    uid: "u1", sequence: 2, startsAt: new Date("2026-11-02T06:00:00Z"), endsAt: new Date("2026-11-02T06:30:00Z"),
    summary: "Leyla — Müayinə, kontrol; " + "ə".repeat(60), tentative: true, lastModified: new Date("2026-10-31T00:00:00Z"),
  }]);
  assert(ics.includes("\r\nDTSTART:20261102T060000Z\r\n"));
  assert(ics.includes("STATUS:TENTATIVE"));
  assert(ics.includes("SUMMARY:Leyla — Müayinə\\, kontrol\\; "));
  for (const line of ics.split("\r\n")) assert(new TextEncoder().encode(line).length <= 75, `line too long: ${line}`);
});

// ---------------------------------------------------------------- emergency gate (same cases as the skill)
Deno.test("emergency gate: AZ/RU emergencies escalate, everyday messages don't", () => {
  for (const m of ["Dişim çox ağrıyır", "disim cox agriyir", "DİŞİM AĞRIYIR", "yanağım şişib", "у меня болит зуб", "десна кровит"]) {
    assert(emergencyGate(m).escalate, m);
  }
  for (const m of ["Salam, sabah saat 3-ə yer var?", "больше не нужно, спасибо", "Yadıma düşdü, sabah gələ bilmərəm"]) {
    assert(!emergencyGate(m).escalate, m);
  }
});
