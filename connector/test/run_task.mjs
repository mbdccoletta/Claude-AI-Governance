// Runs built workflow task scripts under Node, in order, sharing predecessor results like the
// AutomationEngine does. Usage: node test/run_task.mjs resolve_config enterprise_analytics
// Env: WF_PARAMS (JSON, maps to execution().params), DT_MOCK_URL, MOCK_ANTHROPIC_KEY
import { mkdirSync, copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const buildDir = join(here, "..", "workflow", "build");
const runDir = join(here, "mocks", ".run"); // lives under test/mocks so bare imports resolve to the shims
mkdirSync(runDir, { recursive: true });

globalThis.__wfResults = {};
const names = process.argv.slice(2);
if (!names.length) { console.error("usage: node run_task.mjs <task> [task...]"); process.exit(2); }

for (const name of names) {
  const src = join(buildDir, `${name}.js`);
  const dst = join(runDir, `${name}.mjs`);
  copyFileSync(src, dst);
  const mod = await import(pathToFileURL(dst).href + `?t=${Date.now()}`);
  const t0 = Date.now();
  try {
    const out = await mod.default();
    globalThis.__wfResults[name] = out;
    console.log(`RESULT ${name} (${Date.now() - t0} ms): ${JSON.stringify(out)}`);
  } catch (e) {
    console.error(`FAILED ${name}: ${e && e.stack ? e.stack : e}`);
    process.exit(1);
  }
}
