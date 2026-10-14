#!/usr/bin/env node
// compile-context-bundles.mjs — the context compiler (CONCEPT.md §5, §7).
//
// Compiles ONE file per worker: for every story of a wave plan
// `context/workers/wave-N/<US-ID>.md` (`<US-ID>.backend.md` + `.frontend.md`
// under `Split: contract`), and for every role with an inject list
// `context/roles/wave-N/<role>.md` (reviewers, Quality-Gate fix workers).
// A file holds, in this order: a header line (plan path, plan hash, role,
// wave), the role preamble, the project context of the role's inject list,
// the PROJ architecture filtered to the wave's PRDs, the wave's API
// contracts and — story files only — `## Deine Story` with the story's
// wave-plan section verbatim (story-slice.mjs). The worker's role comes from
// the plan table's `Agent Type` column (validate-wave-plan.mjs resolveStories).
// Every wave compiles on its own; there is no merged cross-wave view.
//
// The source-id -> path map and the hard never-inject list (whole PRDs,
// other stories' wave plans, progress.md, SKILL.md texts, src/**/agent.md)
// live HERE, not in the manifests: a manifest can only pick from the closed
// vocabulary below. agent.md files are distributed via the reading protocol.
//
// The manifest budget covers the role context (preamble to contracts); story
// tokens are reported, not capped. Everything renders in memory first: a
// budget, parser, assignment, plan-folder or manifest error exits before
// anything is written or deleted. Output is deterministic (no timestamps), so
// a rerun is idempotent; a write (I/O) error exits 1 — rerun compile.
//
// Usage:
//   node compile-context-bundles.mjs compile <proj-x> <theme> [--wave N|all] [--roles-dir D]
//   node compile-context-bundles.mjs check   <proj-x> <theme> [--roles-dir D]
//   node compile-context-bundles.mjs show    <proj-x> <theme> <US-ID>[.backend|.frontend]
//   node compile-context-bundles.mjs show    <proj-x> <theme> --wave N <role>
//
// `compile` without --wave (or --wave all) compiles every wave, each on its own.
// `check` renders every wave in memory and writes nothing — run it before CP1.
// Exit: 0 ok · 1 budget breach / bad manifest or architecture / write error · 2 missing or unresolvable inputs · 64 usage
import { readFileSync, writeFileSync, existsSync, readdirSync, renameSync, mkdirSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { slice } from "./story-slice.mjs";
import { resolveStories } from "./validate-wave-plan.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

function usage(candidates) {
  if (candidates) console.error(candidates);
  else console.error(
    "Usage: compile-context-bundles.mjs <compile|check|show> <proj-x> <theme> [args]\n" +
    "  compile [--wave N|all] [--roles-dir D]\n" +
    "  check   [--roles-dir D]\n" +
    "  show    <US-ID>[.backend|.frontend] | --wave N <role>",
  );
  process.exit(64);
}

const [cmd, projX, theme, ...rest] = process.argv.slice(2);
if (!["compile", "check", "show"].includes(cmd) || !projX || !theme) usage();

let waveArg = null, rolesDirArg = null;
const positional = [];
for (let i = 0; i < rest.length; i++) {
  if (rest[i] === "--wave") waveArg = rest[++i];
  else if (rest[i] === "--roles-dir") rolesDirArg = rest[++i];
  else if (rest[i].startsWith("--")) usage();
  else positional.push(rest[i]);
}
if (waveArg !== null && waveArg !== "all" && !/^\d+$/.test(waveArg ?? "")) usage();
if (cmd === "check" && waveArg !== null) usage();
if (cmd === "show" ? positional.length !== 1 : positional.length) usage();

const BASE = `specs/PROJ-${projX}-${theme}`;
const OUT_DIR = join(BASE, "context");

function fail(msg, code = 1) { console.error(`compile-context-bundles: ${msg}`); process.exit(code); }
function sha256(s) { return createHash("sha256").update(s).digest("hex"); }
function tokens(s) { return Math.ceil(s.length / 4); } // documented heuristic: ~4 chars/token

if (!existsSync(BASE)) fail(`${BASE} not found — run from the repo root of an active PROJ`, 2);
// The one plan-folder resolution every plan read uses.
const PLAN_DIR = ["3-4_plan", "6_plan"].map((d) => join(BASE, d)).find((d) => existsSync(d))
  ?? fail(`${BASE} has neither 3-4_plan/ nor 6_plan/`, 2);
const PLAN_RE = new RegExp(`^PROJ-${projX}-wave-(\\d+)-plan\\.md$`);
const PLAN_WAVES = readdirSync(PLAN_DIR).map((f) => f.match(PLAN_RE)?.[1]).filter(Boolean).map(Number).sort((a, b) => a - b);
const planPath = (w) => join(PLAN_DIR, `PROJ-${projX}-wave-${w}-plan.md`);

// --- role manifests -----------------------------------------------------------
function rolesDir() {
  if (rolesDirArg) return rolesDirArg;
  if (existsSync("templates/roles")) return "templates/roles";           // repo copy (P0 setup installs)
  return join(SCRIPT_DIR, "..", "manifests", "roles");                    // skill tree
}

// Minimal YAML subset for the manifest frontmatter: flat `key: value`,
// string lists (`- item`), one-level nested maps under `claude:`/`codex:`.
function parseFrontmatter(text, file) {
  const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!m) fail(`${file}: missing frontmatter`);
  const [, fm, body] = m;
  const out = {};
  let currentKey = null, currentMap = null;
  for (const raw of fm.split("\n")) {
    if (!raw.trim() || raw.trim().startsWith("#")) continue;
    const indent = raw.match(/^\s*/)[0].length;
    const line = raw.trim();
    if (line.startsWith("- ")) {
      if (!currentKey || !Array.isArray(out[currentKey])) fail(`${file}: stray list item '${line}'`);
      out[currentKey].push(coerce(line.slice(2).trim()));
      continue;
    }
    const kv = line.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!kv) fail(`${file}: unparseable line '${line}'`);
    const [, key, valRaw] = kv;
    if (indent > 0 && currentMap) { currentMap[key] = coerce(valRaw); continue; }
    currentMap = null;
    if (valRaw === "") {
      // either a list (items follow) or a nested map (indented lines follow)
      if (key === "claude" || key === "codex") { out[key] = {}; currentMap = out[key]; currentKey = null; }
      else { out[key] = []; currentKey = key; }
    } else if (valRaw === "[]") {
      out[key] = []; currentKey = null;
    } else {
      out[key] = coerce(valRaw); currentKey = null;
    }
  }
  return { fm: out, body: body.trim() };
}
function coerce(v) {
  v = v.replace(/\s+#.*$/, "").trim();
  if (/^".*"$/.test(v) || /^'.*'$/.test(v)) return v.slice(1, -1);
  if (v === "true") return true;
  if (v === "false") return false;
  if (/^-?\d+$/.test(v)) return parseInt(v, 10);
  return v;
}

const SOURCE_IDS = [
  "product", "architecture-overview", "proj-architecture", "guidelines",
  "ground-file", "test-conventions", "design-system", "components",
  "api-contracts-own-wave", "security-baseline", "review-criteria", "diff-scope",
];
// Repo manifest copies synced before the rename (sync-framework never
// overwrites a locally edited manifest) still name the old id.
const SOURCE_ALIASES = { "architecture-delta": "proj-architecture" };

function loadManifests() {
  const dir = rolesDir();
  if (!existsSync(dir)) fail(`roles dir not found: ${dir}`, 2);
  const manifests = [];
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".md")).sort()) {
    const { fm, body } = parseFrontmatter(readFileSync(join(dir, f), "utf8"), join(dir, f));
    for (const req of ["name", "description", "tier", "scope", "inject", "budget_tokens", "matcher"])
      if (fm[req] === undefined) fail(`${f}: missing required manifest field '${req}'`);
    // the name becomes a file name (roles/wave-N/<name>.md, .claude/agents/skillchain-<name>.md)
    if (typeof fm.name !== "string" || !/^[a-z][a-z0-9-]*$/.test(fm.name)) fail(`${f}: manifest name '${fm.name}' must match ^[a-z][a-z0-9-]*$`);
    fm.inject = fm.inject.map((id) => SOURCE_ALIASES[id] ?? id);
    for (const id of fm.inject)
      if (!SOURCE_IDS.includes(id)) fail(`${f}: unknown inject source id '${id}' (closed vocabulary: ${SOURCE_IDS.join(", ")})`);
    manifests.push({ ...fm, preamble: body, file: join(dir, f) });
  }
  if (manifests.length === 0) fail(`no role manifests in ${dir}`, 2);
  return manifests;
}

// A repo-local manifest synced before worker files existed would contradict
// the file its worker reads (story in the spawn prompt, no design system).
function checkManifests(manifests) {
  for (const m of manifests) {
    if (!["implementer", "frontend-implementer", "backend-implementer"].includes(m.name)) continue;
    if (/tasks\s+arrive\s+in\s+the\s+spawn\s+prompt/.test(m.preamble))
      fail(`${m.file}: preamble still says the story arrives in the spawn prompt — take the current manifest via sync-framework or align it by hand (story and ACs are in the worker file's \`## Deine Story\`)`, 2);
    if (m.name === "implementer" && !m.inject.includes("design-system"))
      fail(`${m.file}: inject list lacks design-system — take the current manifest via sync-framework or align it by hand`, 2);
  }
}

// --- sources ------------------------------------------------------------------
function readOr(path, note) {
  if (existsSync(path)) return readFileSync(path, "utf8").trim();
  return `_(source missing: ${path} — ${note})_`;
}

function apiContractsOwnWave(wave) {
  const path = join(BASE, "api-contracts.md");
  if (!existsSync(path)) return `_(source missing: ${path} — no contracts yet)_`;
  // Keep ## sections whose heading names this wave; heuristic, documented.
  const sections = readFileSync(path, "utf8").split(/^(?=## )/m);
  const kept = sections.filter((s) => new RegExp(`wave\\s*${wave}\\b`, "i").test(s.split("\n")[0]));
  if (kept.length === 0) return `_(no api-contracts sections matched wave ${wave} — check ${path} headings)_`;
  return kept.join("").trim();
}

// The PROJ architecture (skill 3) is ONE document. Workers get its implementer
// view: fenced blocks (Mermaid) and diagram-only sections dropped, every
// `### Decision N` and `### Flow N` reduced to its ID, Affects and Summary line
// (plus its optional `Changes baseline` pointer, so a worker knows which
// injected docs/ARCHITECTURE.md rule it overrides), and only the items whose
// Affects names a PRD of the wave (or `all`). Wave plans cite these same IDs.
// Parsing is strict: a malformed item heading, a doubled field or an Affects
// that names no PRD fails instead of vanishing from the file. PROJs planned
// before Summary lines existed fall back to architecture-delta.md, then to
// the full document.
const DROPPED_SECTIONS = ["PRDs Covered", "System Boundaries"];
const ITEM_SECTIONS = { "Cross-Cutting Tech Decisions": "Decision", "Key Flows": "Flow" };
const itemReached = new Map();   // item id -> listed in at least one compiled view (read by `check`)

function wavePrds(text, plan) {
  const lines = [];
  let fence = null;
  for (const line of text.split("\n").map((l) => l.replace(/\r$/, ""))) {
    const [, marker, info] = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/) ?? [];
    if (marker && !fence) { fence = marker; continue; }
    if (marker && fence && marker[0] === fence[0] && marker.length >= fence.length && !info.trim()) { fence = null; continue; }
    if (!fence) lines.push(line);
  }
  const header = lines.find((line) => /^\*\*PRDs involved:\*\*/.test(line));
  const ids = new Set([...((header ?? "").matchAll(/PRD-(\d+)/g))].map((m) => m[1]));
  const story = new RegExp(`^## PROJ-${projX}-PRD-(\\d+)-US-\\d+(?::|\\s|$)`);
  const missing = new Set(lines.map((line) => line.match(story)?.[1]).filter((id) => id && !ids.has(id)));
  if (missing.size) fail(`${plan}: **PRDs involved:** is missing ${[...missing].map((id) => `PRD-${id}`).join(", ")} from story sections`);
  return ids.size ? ids : null;
}

function implementerView(text, path, scope, wave, prds) {
  const sections = [];   // { heading, lines }
  let fence = null;
  for (const line of text.split("\n").map((l) => l.replace(/\r$/, ""))) {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})/)?.[1];
    if (marker && !fence) { fence = marker; continue; }
    if (marker && fence && marker[0] === fence[0] && marker.length >= fence.length) { fence = null; continue; }
    if (fence) continue;
    if (line.startsWith("## ")) sections.push({ heading: line.slice(3).trim(), lines: [] });
    else if (sections.length) sections.at(-1).lines.push(line);
  }
  const out = [];
  for (const { heading, lines } of sections) {
    if (DROPPED_SECTIONS.some((d) => heading.startsWith(d))) continue;
    if (scope === "backend" && heading.startsWith("UI Implementation Constraints")) continue;
    const kind = Object.entries(ITEM_SECTIONS).find(([h]) => heading.startsWith(h))?.[1];
    if (!kind) {
      out.push(`## ${heading}`, lines.join("\n").trim(), "");
      continue;
    }
    const items = [];
    for (const line of lines) {
      if (line.startsWith("### ")) {
        const head = line.match(new RegExp(`^### (${kind} \\d+):\\s*(.*)$`));
        if (!head) fail(`${path}: '${line}' under ## ${heading} must read '### ${kind} N: <title>'`);
        items.push({ id: head[1], title: head[2].trim() });
        continue;
      }
      const field = line.match(/^\*\*(Affects|Summary|Changes baseline):\*\*\s*(.*)$/);
      if (!field || !items.length) continue;
      const key = field[1] === "Changes baseline" ? "baseline" : field[1].toLowerCase();
      if (items.at(-1)[key] !== undefined) fail(`${path}: ${items.at(-1).id} has two **${field[1]}:** lines`);
      items.at(-1)[key] = field[2].trim();
    }
    if (!items.length && lines.some((l) => l.trim()))
      fail(`${path}: ## ${heading} has content but no '### ${kind} N: <title>' items — implementers would get none of it`);
    for (const d of items) {
      if (!d.summary || !d.affects) fail(`${path}: ${d.id} needs both an **Affects:** and a **Summary:** line`);
      if (!/\ball\b/i.test(d.affects) && !/PRD-\d+/.test(d.affects))
        fail(`${path}: ${d.id} **Affects:** names no PRD-n and not 'all' — it would reach no wave`);
    }
    const kept = items.filter((d) => !prds || /\ball\b/i.test(d.affects) ||
      [...d.affects.matchAll(/PRD-(\d+)/g)].some((m) => prds.has(m[1])));
    for (const d of items) itemReached.set(d.id, itemReached.get(d.id) || kept.includes(d));
    out.push(`## ${heading}`, ...kept.map((d) => `- **${d.id}: ${d.title}** (Affects: ${d.affects}) — ${d.summary}` +
      (d.baseline ? ` _Overrides the baseline: ${d.baseline} — this ${kind.toLowerCase()} wins over the injected architecture overview._` : "")), "");
  }
  const filter = prds ? ` Only items affecting ${[...prds].map((n) => `PRD-${n}`).join(", ")} (wave ${wave}) are listed.` : "";
  return `_Implementer view of \`${path}\`: diagrams dropped, each decision and key flow reduced to its Summary.${filter} Wave plans cite these Decision IDs; open the full file for the WHY._\n\n${out.join("\n").trim()}`;
}

function projArchitecture(scope, wave, prds) {
  const arch = join(PLAN_DIR, `PROJ-${projX}-architecture.md`);
  const delta = join(BASE, "architecture-delta.md");
  const text = existsSync(arch) ? readFileSync(arch, "utf8") : null;
  if (text && /^\*\*Summary:\*\*/m.test(text)) return { title: `PROJ architecture (${arch})`, text: implementerView(text, arch, scope, wave, prds) };
  if (existsSync(delta)) return { title: `Architecture delta of this PROJ (${delta} — legacy PROJ)`, text: readFileSync(delta, "utf8").trim() };
  if (text) return { title: `PROJ architecture (${arch} — legacy format without Summary lines, injected whole)`, text: text.trim() };
  return { title: "PROJ architecture", text: `_(source missing: ${arch} — no decisions recorded)_` };
}

function sourceContent(id, manifest, wave, prds) {
  switch (id) {
    case "product":              return { title: "Product (docs/PRODUCT.md)", text: readOr("docs/PRODUCT.md", "no intake baseline yet") };
    case "architecture-overview":return { title: "Architecture overview (docs/ARCHITECTURE.md)", text: readOr("docs/ARCHITECTURE.md", "no intake baseline yet") };
    case "proj-architecture":    return projArchitecture(manifest.scope, wave, prds);
    case "guidelines":           return { title: "Guidelines (docs/GUIDELINES.md)", text: readOr("docs/GUIDELINES.md", "no intake baseline yet") };
    case "ground-file":          return { title: `Validated assumptions (${BASE}/ground-file.md)`, text: readOr(join(BASE, "ground-file.md"), "generated in P0 step 6b") };
    case "test-conventions":     return { title: "Test conventions (docs/test-conventions.md)", text: readOr("docs/test-conventions.md", "no intake baseline yet") };
    case "design-system":        return { title: "Design system (docs/DESIGN-SYSTEM.md)", text: readOr("docs/DESIGN-SYSTEM.md", "no intake baseline yet") };
    case "components":           return { title: "Component registry (docs/components.md)", text: "Read `docs/components.md` before creating or changing a component; it is deliberately referenced by path so its inventory does not consume this file's budget." };
    case "security-baseline":    return { title: "Security baseline (docs/security-baseline.md)", text: readOr("docs/security-baseline.md", "no intake baseline yet") };
    case "api-contracts-own-wave": return { title: "API contracts — own wave only", text: apiContractsOwnWave(wave) };
    case "review-criteria":      return { title: "Review criteria", text: "_(dynamic: your persona's review criteria arrive in the spawn prompt — read them there)_" };
    case "diff-scope":           return { title: "Diff scope", text: "_(dynamic: the diff scope for this review arrives in the spawn prompt)_" };
    default: fail(`unknown source id '${id}'`);
  }
}

// --- rendering (in memory) ---------------------------------------------------------
// Role context = file parts 2 to 5 (preamble, project context, architecture,
// contracts); the manifest budget applies to exactly this.
function roleContext(manifest, wave, prds) {
  const parts = [
    `# Worker context — role: ${manifest.name} (tier ${manifest.tier}, scope ${manifest.scope})`,
    "",
    manifest.preamble,
    "",
    "_Never injected by design: whole PRDs, other stories' wave plans, progress.md,",
    "SKILL.md texts, src/**/agent.md (reading protocol only — read the folder's",
    "agent.md before your first edit there)._",
  ];
  for (const id of manifest.inject) {
    const { title, text } = sourceContent(id, manifest, wave, prds);
    parts.push("", `## ${title}`, "", text);
  }
  return parts.join("\n").trim() + "\n";
}

const CONTRACT_SIDES = [["backend", "backend-implementer"], ["frontend", "frontend-implementer"]];
// Worker file names (without .md) and roles of one resolved story.
const storyTargets = (s) => s.split === "contract"
  ? CONTRACT_SIDES.map(([side, role]) => ({ name: `${s.id}.${side}`, role, story: s }))
  : [{ name: s.id, role: s.role, story: s }];

function planStories(wave) {
  const path = planPath(wave);
  const text = readFileSync(path, "utf8");
  try { return { path, text, stories: resolveStories(text, path) }; }
  catch (error) { fail(error.message, 2); }
}

// Every story of every wave plan, each ID in exactly one plan — otherwise the
// cross-wave cleanup would delete another wave's file and show would guess.
function allStories() {
  const seen = new Map();   // id -> plan path
  const byWave = new Map();
  for (const w of PLAN_WAVES) {
    const { path, stories } = planStories(w);
    for (const s of stories) {
      if (seen.has(s.id)) fail(`${s.id} is a story in two wave plans: ${seen.get(s.id)} and ${path} — keep it in one`, 2);
      seen.set(s.id, path);
    }
    byWave.set(w, stories);
  }
  return byWave;
}

// Renders one wave: { files: Map(relPath -> content), breaches, report, fallback }.
function renderWave(wave, manifests) {
  const { path, text, stories } = planStories(wave);
  const prds = wavePrds(text, path);
  const head = (role) => `Generated from ${path} @ ${sha256(text).slice(0, 12)} · role ${role} · wave ${wave}\n\n`;
  const files = new Map(), breaches = [], report = [];
  const contexts = new Map();
  for (const m of manifests) {
    if (m.inject.length === 0) continue;   // tier 0 / explore: no file
    const body = roleContext(m, wave, prds);
    const t = tokens(body);
    contexts.set(m.name, body);
    if (t > m.budget_tokens) breaches.push(`wave ${wave}: ${m.name} ${t}/${m.budget_tokens} tokens`);
    report.push(`${m.name} ${t}/${m.budget_tokens}`);
    files.set(join(OUT_DIR, "roles", `wave-${wave}`, `${m.name}.md`), head(m.name) + body);
  }
  const storyReport = [];
  for (const target of stories.flatMap(storyTargets)) {
    const body = contexts.get(target.role);
    if (!body) fail(`${path}: ${target.story.id} needs role ${target.role}, which has no manifest with an inject list in ${rolesDir()}`, 2);
    let storyText;
    try { storyText = slice(text, target.story.id); }
    catch (error) { fail(`${path}: ${target.story.id}: ${error.message}`, 2); }
    files.set(join(OUT_DIR, "workers", `wave-${wave}`, `${target.name}.md`), `${head(target.role)}${body}\n## Deine Story\n\n${storyText}`);
    storyReport.push(`${target.name} (${target.role}, story ${tokens(storyText)} tokens)`);
  }
  return { files, breaches, stories, fallback: stories.some((s) => s.fallback) ? path : null,
    report: `wave ${wave}: roles ${report.join(", ")} · workers ${storyReport.join(", ")}` };
}

function agentFileContent(manifest) {
  const model = manifest.claude?.model ? `model: ${manifest.claude.model}\n` : "";
  const pointer = manifest.inject.length
    ? "\n\nDein vollständiger Auftrag steht in der Datei aus dem Spawn-Prompt. Lies sie zuerst vollständig. Fehlt der Pfad oder ist die Datei nicht lesbar, brich ab und melde das."
    : "";
  return `---\nname: skillchain-${manifest.name}\ndescription: "${manifest.description.replace(/"/g, '\\"')}"\ntools: ${manifest.claude?.tools ?? "Read,Grep,Glob"}\n${model}---\n\n${manifest.preamble}${pointer}\n`;
}

function atomicWrite(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, content);
  renameSync(tmp, path);
}

const waveDirs = (kind) => existsSync(join(OUT_DIR, kind))
  ? readdirSync(join(OUT_DIR, kind)).filter((d) => /^wave-\d+$/.test(d)).map((d) => join(OUT_DIR, kind, d))
  : [];

if (cmd === "compile") {
  if (PLAN_WAVES.length === 0) fail(`${PLAN_DIR} has no PROJ-${projX}-wave-<N>-plan.md`, 2);
  if (waveArg !== null && waveArg !== "all" && !PLAN_WAVES.includes(Number(waveArg)))
    fail(`${planPath(waveArg)} not found — no plan for wave ${waveArg}`, 2);
  const waves = waveArg === null || waveArg === "all" ? PLAN_WAVES : [Number(waveArg)];
  const manifests = loadManifests();
  checkManifests(manifests);
  allStories();
  const rendered = waves.map((w) => renderWave(w, manifests));
  const breaches = rendered.flatMap((r) => r.breaches);
  if (breaches.length) fail(`budget breach — nothing written:\n  ${breaches.join("\n  ")}\n  Condense the sources or raise that role's manifest budget when its scope genuinely requires it.`);
  const agentFiles = manifests.filter((m) => m.claude?.agent_file === true)
    .map((m) => [join(".claude", "agents", `skillchain-${m.name}.md`), agentFileContent(m)]);
  // Only now touch the disk. A write error leaves a partial set: exit 1, rerun.
  try {
    for (const f of existsSync(OUT_DIR) ? readdirSync(OUT_DIR) : [])
      if (/^bundle-.*\.md$/.test(f) || f === "bundles.lock.json" || f === "blocked-roles.json") rmSync(join(OUT_DIR, f), { force: true });
    const compiledIds = new Set(rendered.flatMap((r) => r.stories.map((s) => s.id)));
    for (const dir of [...waveDirs("workers"), ...waveDirs("roles")]) {
      const w = Number(dir.match(/wave-(\d+)$/)[1]);
      if (waves.includes(w) || !PLAN_WAVES.includes(w)) rmSync(dir, { recursive: true, force: true });
    }
    // a story now compiled into another wave leaves no stale file behind
    for (const dir of waveDirs("workers")) for (const f of readdirSync(dir))
      if (compiledIds.has(f.replace(/(\.backend|\.frontend)?\.md$/, ""))) rmSync(join(dir, f), { force: true });
    for (const r of rendered) for (const [path, content] of r.files) atomicWrite(path, content);
    // ONLY skillchain-<role>.md files are ever written — other agents in
    // .claude/agents/ are never touched.
    for (const [path, content] of agentFiles) atomicWrite(path, content);
  } catch (error) {
    fail(`write failed (${error.message}) — the context is incomplete; fix the cause and rerun compile before spawning workers`);
  }
  for (const r of rendered) {
    console.log(r.report);
    if (r.fallback) console.warn(`⚠ ${r.fallback}: no Agent Type column in the story table — every story falls back to implementer`);
  }
  console.log(`✓ ${rendered.reduce((n, r) => n + r.files.size, 0)} file(s) -> ${OUT_DIR}/{workers,roles}/wave-{${waves.join(",")}} · ${agentFiles.length} agent file(s) -> .claude/agents/skillchain-*.md`);
} else if (cmd === "check") {
  if (PLAN_WAVES.length === 0) fail(`${PLAN_DIR} has no PROJ-${projX}-wave-<N>-plan.md`, 2);
  const manifests = loadManifests();
  checkManifests(manifests);
  allStories();
  let breached = false;
  for (const w of PLAN_WAVES) {
    const r = renderWave(w, manifests);
    console.log(r.report);
    if (r.fallback) console.warn(`⚠ ${r.fallback}: no Agent Type column in the story table — every story falls back to implementer`);
    for (const b of r.breaches) { console.error(`✗ ${b} — compile would refuse at P0`); breached = true; }
  }
  const unreached = [...itemReached].filter(([, reached]) => !reached).map(([id]) => id);
  if (unreached.length) { console.error(`✗ ${unreached.join(", ")}: Affects names no PRD of any wave plan — no implementer would see it`); breached = true; }
  if (breached) { console.error("Shorten the Summary lines or the curated docs before CP1; the ground file (written at P0) still adds to these numbers."); process.exit(1); }
  console.log(`✓ check ok — every story maps to a role, every role fits its budget in ${PLAN_WAVES.length} wave(s); nothing written`);
} else {
  const [name] = positional;
  if (waveArg !== null) {
    const roles = loadManifests().filter((m) => m.inject.length).map((m) => m.name);
    const w = Number(waveArg);
    if (waveArg === "all" || !PLAN_WAVES.includes(w) || !roles.includes(name))
      usage(`show: no role file '${name}' in wave ${waveArg} — candidates: ${PLAN_WAVES.flatMap((pw) => roles.map((r) => `--wave ${pw} ${r}`)).join(", ")}`);
    const p = join(OUT_DIR, "roles", `wave-${w}`, `${name}.md`);
    if (!existsSync(p)) fail(`${p} not found — run compile ${projX} ${theme} --wave ${w}`, 2);
    process.stdout.write(readFileSync(p, "utf8"));
  } else {
    const targets = [...allStories()].flatMap(([w, stories]) => stories.flatMap(storyTargets).map((t) => ({ ...t, wave: w })));
    const target = targets.find((t) => t.name === name);
    if (!target) {
      const split = targets.filter((t) => t.story.id === name).map((t) => t.name);
      if (split.length) usage(`show: ${name} is split (contract) — candidates: ${split.join(", ")}`);
      const roles = loadManifests().filter((m) => m.inject.length).map((m) => m.name);
      if (roles.includes(name)) usage(`show: role files are per wave — candidates: ${PLAN_WAVES.map((w) => `--wave ${w} ${name}`).join(", ")}`);
      usage(`show: unknown worker '${name}' — candidates: ${targets.map((t) => t.name).join(", ")}`);
    }
    const p = join(OUT_DIR, "workers", `wave-${target.wave}`, `${name}.md`);
    if (!existsSync(p)) fail(`${p} not found — run compile ${projX} ${theme} --wave ${target.wave}`, 2);
    process.stdout.write(readFileSync(p, "utf8"));
  }
}
