import { AppError, toAppError } from "../lib/api";
import { durationOptions, formatDate, formatTime, todayIn } from "../lib/format";
import { DICTIONARIES, type TextKey, translate } from "../lib/i18n";

describe("translations", () => {
  const keys = Object.keys(DICTIONARIES.az) as TextKey[];
  it.each(["ru", "en"] as const)("%s has every key, with the same placeholders", (lang) => {
    expect(Object.keys(DICTIONARIES[lang]).sort()).toEqual([...keys].sort());
    for (const key of keys) {
      const placeholders = (s: string) => (s.match(/\{\w+\}/g) ?? []).sort().join();
      expect(placeholders(DICTIONARIES[lang][key]), key).toBe(placeholders(DICTIONARIES.az[key]));
      expect(DICTIONARIES[lang][key].trim(), key).not.toBe("");
    }
  });
  it("fills placeholders", () => {
    expect(translate("az", "minutes", { n: 45 })).toBe("45 dəq");
    expect(translate("en", "bookings_max", { n: 80 })).toBe("At most 80 min before the next booking");
  });
});

describe("formatting", () => {
  it("dates in three languages", () => {
    expect(formatDate("2026-11-02T10:00", "az")).toBe("2 noyabr, bazar ertəsi");
    expect(formatDate("2026-11-02", "ru")).toBe("2 ноября, понедельник");
    expect(formatDate("2026-11-08", "en")).toBe("Sunday, 8 November");
    expect(formatTime("2026-11-02T10:00")).toBe("10:00");
  });
  it("today in the clinic's time zone, not the browser's", () => {
    expect(todayIn("Asia/Baku", new Date("2026-11-02T21:30:00Z"))).toBe("2026-11-03");   // 01:30 in Baku
  });
  it("duration choices: 15-min steps up to the cap, always including the held duration", () => {
    expect(durationOptions(45, 80)).toEqual([15, 30, 45, 60, 75]);
    expect(durationOptions(50, 60)).toEqual([15, 30, 45, 50, 60]);
    expect(durationOptions(30, 20)).toEqual([15, 30]);   // held is kept even if the cap shrank
  });
});

describe("errors", () => {
  it("maps database codes to actionable kinds", () => {
    expect(toAppError({ code: "DP002" }).kind).toBe("window_closed");
    expect(toAppError({ code: "23P01" }).kind).toBe("overlap");
    expect(toAppError({ message: "Failed to fetch" }).kind).toBe("network");
    expect(toAppError({ code: "42501" })).toBeInstanceOf(AppError);
  });
});
