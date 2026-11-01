// Language detection and date/time wording for Azerbaijani and Russian.
// Deterministic on purpose: no locale data from the runtime, so the output
// is identical in tests, locally and on Supabase.

export type Lang = "az" | "ru";

/**
 * Best guess of the language of a patient's text, or null if unsure.
 * Azerbaijani is written in Latin script (ə ğ ı ş ç ö ü), sometimes without
 * the special letters, and by some older patients in Cyrillic (ә ғ ҹ һ ө ү ј).
 */
export function detectLanguage(text: string): Lang | null {
  const letters = text.replace(/[^\p{L}]/gu, "");
  if (letters.length < 2) return null;

  if (/[әғҹһөүјӘҒҸҺӨҮЈ]/.test(letters)) return "az";        // Azerbaijani Cyrillic
  if (/[əğışçöüƏĞİŞÇÖÜ]/.test(letters)) return "az";      // Azerbaijani Latin

  const cyrillic = (letters.match(/\p{Script=Cyrillic}/gu) ?? []).length;
  const latin = (letters.match(/\p{Script=Latin}/gu) ?? []).length;
  if (cyrillic / letters.length > 0.6) return "ru";
  if (latin / letters.length > 0.6) return "az";             // plain-Latin Azerbaijani
  return null;
}

const MONTHS: Record<Lang, string[]> = {
  az: ["yanvar", "fevral", "mart", "aprel", "may", "iyun", "iyul", "avqust", "sentyabr", "oktyabr", "noyabr", "dekabr"],
  ru: ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"],
};

// ISO weekday 1 = Monday … 7 = Sunday
const WEEKDAYS: Record<Lang, string[]> = {
  az: ["", "bazar ertəsi", "çərşənbə axşamı", "çərşənbə", "cümə axşamı", "cümə", "şənbə", "bazar"],
  ru: ["", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье"],
};

/** "2026-11-02" → "2 noyabr, bazar ertəsi" / "2 ноября, понедельник" */
export function formatDate(isoDate: string, lang: Lang): string {
  const [y, m, d] = isoDate.slice(0, 10).split("-").map(Number);
  const weekday = new Date(Date.UTC(y, m - 1, d)).getUTCDay() || 7;
  return `${d} ${MONTHS[lang][m - 1]}, ${WEEKDAYS[lang][weekday]}`;
}

/** "2026-11-02T14:30" → "14:30" */
export function formatTime(localDateTime: string): string {
  return localDateTime.slice(11, 16);
}

/** Replace {name} placeholders; unknown placeholders are left visible so tests catch them. */
export function fill(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (match, key) => (key in values ? String(values[key]) : match));
}
