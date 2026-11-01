// The app's API list must match the database. Reads every migration, finds the
// LAST definition of each function (later migrations replace earlier ones),
// and checks that each RPC the app calls exists with exactly these parameters.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { RPCS } from "../lib/api";

const dir = join(__dirname, "../../../supabase/migrations");

function definitions(): Map<string, string[]> {
  const defs = new Map<string, string[]>();
  for (const file of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) {
    const sql = readFileSync(join(dir, file), "utf8");
    const re = /create or replace function (\w+)\.(\w+)\s*\(([\s\S]*?)\)\s*returns/gi;
    for (const m of sql.matchAll(re)) {
      const params = m[3].split(",").map((p) => p.trim().split(/\s+/)[0]).filter((p) => p.startsWith("p_"));
      defs.set(`${m[1]}.${m[2]}`, params);
    }
  }
  return defs;
}

describe("app ↔ database contract", () => {
  const defs = definitions();
  for (const [name, spec] of Object.entries(RPCS)) {
    it(`${spec.schema}.${name}(${spec.params.join(", ")}) exists`, () => {
      expect(defs.has(`${spec.schema}.${name}`)).toBe(true);
      expect(defs.get(`${spec.schema}.${name}`)).toEqual([...spec.params]);
    });
  }
});
