#!/usr/bin/env node
// context-injector.mjs — retired, delete after the next release.
//
// Worker context is one file per worker now (compile-context-bundles.mjs
// compile); the lead names its path in the spawn prompt. `compile` and
// preflight.sh remove the old SubagentStart hook. This stub only keeps
// projects that still carry the hook running: it never delivers project
// context and reads no lock and no bundle.
//
//   node context-injector.mjs claude
//       SubagentStart hook (hook JSON on stdin): a framework role with an
//       inject list (implementer, frontend-/backend-implementer, reviewer,
//       matched by the manifests' matchers) gets one short notice that the
//       hook is retired; micro-fixer, explore/scout and anything else get
//       nothing.
//   node context-injector.mjs codex <role> [--path]
//       Prints nothing (a hint on stderr).
// Exit: 0 · 1 unknown mode
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const NOTICE = "Dieser Hook ist stillgelegt. Dein Auftrag steht in der Datei aus dem Spawn-Prompt. Ohne Pfad: abbrechen und melden.";
const mode = process.argv[2];
if (mode !== "claude" && mode !== "codex") {
  console.error("Usage: context-injector.mjs claude | codex <role> [--path]");
  process.exit(1);
}
if (mode === "codex") {
  console.error("context-injector: retired — the worker file path arrives in the lane prompt (compile-context-bundles.mjs compile)");
  process.exit(0);
}

// Manifest frontmatter: top-level name, matcher and the inject list only.
function frontmatter(text) {
  const out = {};
  let listKey = null;
  for (const raw of (text.match(/^---\n([\s\S]*?)\n---/)?.[1] ?? "").split("\n")) {
    const line = raw.trim();
    if (line.startsWith("- ")) { if (listKey) out[listKey].push(line.slice(2).trim()); continue; }
    const kv = raw.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);   // indented provider maps are skipped
    if (!kv) continue;
    const [, key, val] = kv;
    listKey = val === "" ? key : null;
    out[key] = val === "" || val === "[]" ? [] : val.replace(/^["']|["']$/g, "");
  }
  return out;
}

try {
  const hook = JSON.parse(readFileSync(0, "utf8") || "{}");
  const agentType = hook.agent_type ?? hook.subagent_type ?? hook.agentType ?? "";
  const dir = existsSync("templates/roles") ? "templates/roles" : join(dirname(fileURLToPath(import.meta.url)), "..", "manifests", "roles");
  const manifests = agentType && existsSync(dir)
    ? readdirSync(dir).filter((f) => f.endsWith(".md")).sort()
      .map((f) => frontmatter(readFileSync(join(dir, f), "utf8"))).filter((m) => m.name && m.matcher)
    : [];
  const stripped = agentType.replace(/^skillchain-/i, "").toLowerCase();
  const match = manifests.find((m) => m.name.toLowerCase() === stripped)
    ?? manifests.find((m) => { try { return new RegExp(m.matcher, "i").test(agentType); } catch { return false; } });
  if (match && (match.inject ?? []).length > 0)
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "SubagentStart", additionalContext: NOTICE } }));
} catch { /* a retired hook never blocks a spawn */ }
process.exit(0);
