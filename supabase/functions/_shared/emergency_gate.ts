// Deterministic emergency / clinical-risk gate. Runs BEFORE any model call.
// Recall-first: a false positive costs one human glance; a false negative can
// cost a patient. Seed lists below MUST be reviewed and extended by the
// receptionist from real clinic messages before go-live.
//
// Handles: Azerbaijani Latin with or without diacritics (ə/e, ş/s/sh, ğ/g, ı/i),
// Azerbaijani typed in Russian keyboard Cyrillic, Russian, and the Turkish
// dotted-İ lowercasing trap in JS.

export type GateResult =
  | { escalate: false }
  | { escalate: true; category: Category; matched: string };

export type Category = "pain" | "bleeding" | "swelling" | "fever" | "trauma" | "medication" | "breathing";

// Stems starting with "=" must match a whole word ("=боль" must not hit "больше").
// Stems are matched against the NORMALISED text (see normalise()), as
// substrings at a word start. Keep stems short enough to catch inflections
// (ağrıyır, ağrısı, ağrılar → "agri"), long enough to avoid noise.
const STEMS: Record<Category, string[]> = {
  pain: [
    "agri", "agriy", "aqri", "sizild", "zoqq", "dozulmez", "dozemir",             // az
    "болит", "=боль", "=больно", "болью", "болев", "ноет", "ноющ", "дерга", "невыносим",                                   // ru
    "агры",                                                                        // az in Cyrillic
  ],
  bleeding: [
    "qanaxma", "qanayir", "qan gelir", "qan axir", "qanama",                       // az
    "кров", "кровотеч", "кровит",                                                  // ru
    "ганахма", "ган гелир",                                                        // az in Cyrillic
  ],
  swelling: [
    "sisib", "sisdi", "sisk", "sis var", "yanaq sis",                        // az
    "опух", "отек", "отёк", "флюс", "раздуло",                                     // ru
    "шиш",                                                                         // az in Cyrillic
  ],
  fever: ["qizdirma", "hererat", "temperatur", "температур", "жар", "озноб"],
  trauma: [
    "sindi", "qirildi", "dis dusdu", "disi dusdu", "zerbe", "qeza",                          // az
    "выбил", "сломал", "откол", "удар", "травм",                                   // ru
  ],
  medication: [
    "derman", "antibiotik", "agrikesen", "=hap", "hapi", "iyne", "allergi",               // az
    "лекарств", "таблет", "антибиот", "обезбол", "аллерг", "укол",                 // ru
  ],
  breathing: ["nefes ala bilmir", "bogul", "udqun", "дышать", "задыха", "глотать"],
};

// Phrases that contain a stem but are clearly not clinical. Keep this list tiny;
// every entry is a potential missed emergency.
const ALLOW: string[] = [];

const AZ_FOLD: Record<string, string> = {
  "ə": "e", "ı": "i", "ş": "s", "ç": "c", "ğ": "g", "ö": "o", "ü": "u",
  "ё": "е",
};

export function normalise(input: string): string {
  return input
    // Fix Turkish/Azerbaijani capitals before lowercasing: JS maps "İ" to "i̇".
    .replace(/İ/g, "i").replace(/I/g, "ı")
    .toLowerCase()
    .replace(/[əışçğöüё]/g, (c) => AZ_FOLD[c] ?? c)
    .replace(/sh/g, "s").replace(/ch/g, "c").replace(/gh/g, "g")  // "agh" / "shish" spellings
    .normalize("NFKD").replace(/[\u0300-\u036f]/g, "")             // strip combining marks
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// Fold stems through the same normalisation once at load time.
const NORM_STEMS: [Category, string, string][] = Object.entries(STEMS).flatMap(
  ([cat, stems]) => stems.map((s) => [cat as Category, s, normalise(s)] as [Category, string, string]),
);

export function emergencyGate(text: string): GateResult {
  const t = " " + normalise(text) + " ";
  if (ALLOW.some((a) => t.includes(normalise(a)))) return { escalate: false };
  for (const [category, raw, stem] of NORM_STEMS) {
    const hit = raw.startsWith("=") ? t.includes(" " + stem + " ") : t.includes(" " + stem);
    if (stem && hit) return { escalate: true, category, matched: raw };
  }
  return { escalate: false };
}
