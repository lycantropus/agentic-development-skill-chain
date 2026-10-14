#!/usr/bin/env node
// plan.mjs — everything the chain derives from the wave plans, one parser family:
//
//   plan.mjs validate <3-4_plan-directory> [repository-root]
//     Plan/config consistency gate: structure, AC<->task<->command<->test mapping, AC wording
//     against the PRDs, task length, literal SQL/DDL, narrated-diff text. Exit 0 / 1 (2 usage).
//   plan.mjs validate --stories <wave-plan.md>
//     The wave plan's story table resolved against its sections, as JSON (the binding Agent Type).
//   plan.mjs slice <wave-plan.md> <US-ID>
//     One story's section verbatim: from its `## <US-ID>` heading to the next `## ` heading
//     (fenced code blocks are skipped). Exits 1 when the ID has no section or more than one.
//   plan.mjs context <compile|check|show> <proj-x> <theme> [args]
//     The context compiler (CONCEPT.md §5, §7): one file per worker.
//
// `context` — the context compiler (CONCEPT.md §5, §7).
//
// Compiles ONE file per worker: for every story of a wave plan
// `context/workers/wave-N/<US-ID>.md` (`<US-ID>.backend.md` + `.frontend.md`
// under `Split: contract`), and for every role with an inject list
// `context/roles/wave-N/<role>.md` (reviewers, Quality-Gate fix workers).
// A file holds, in this order: a header line (plan path, plan hash, role,
// wave), the role preamble, the project context of the role's inject list,
// the PROJ architecture filtered to the wave's PRDs, the wave's API
// contracts and — story files only — `## Deine Story` with the story's
// wave-plan section verbatim (`slice`). The worker's role comes from
// the plan table's `Agent Type` column (`validate --stories`).
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
//   node plan.mjs context compile <proj-x> <theme> [--wave N|all] [--roles-dir D]
//   node plan.mjs context check   <proj-x> <theme> [--roles-dir D]
//   node plan.mjs context show    <proj-x> <theme> <US-ID>[.backend|.frontend]
//   node plan.mjs context show    <proj-x> <theme> --wave N <role>
//
// `compile` without --wave (or --wave all) compiles every wave, each on its own.
// `check` renders every wave in memory and writes nothing — run it before CP1.
// Exit: 0 ok · 1 budget breach / bad manifest or architecture / write error · 2 missing or unresolvable inputs · 64 usage
import fs, { readFileSync, writeFileSync, existsSync, readdirSync, renameSync, mkdirSync, rmSync, realpathSync } from "node:fs";
import path, { join, dirname } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

// ---- slice --------------------------------------------------------------------
// The section text for `heading` (a US ID or section title) in `text`.
// Throws an Error with `count` when the heading does not match exactly one section.
export function slice(text, heading) {
  const lines = text.split("\n");
  const escaped = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const own = new RegExp(`^## ${escaped}(?::|\\s|$)`);
  const starts = [];
  let fence = null, end = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "");   // CRLF plans: match without the CR, output stays byte-exact
    // CommonMark: a fence closes only on the same char, at least as long, bare.
    const [, marker, info] = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/) ?? [];
    if (marker && !fence) fence = marker;
    else if (marker && marker[0] === fence[0] && marker.length >= fence.length && !info.trim()) { fence = null; continue; }
    if (fence || !line.startsWith("## ")) continue;
    if (own.test(line)) starts.push(i);
    else if (starts.length === 1 && end === null) end = i;
  }
  if (starts.length !== 1) {
    throw Object.assign(new Error(`${heading} has ${starts.length} sections (need exactly 1)`), { count: starts.length });
  }
  return lines.slice(starts[0], end ?? lines.length).join("\n").replace(/\s*$/, "\n");
}

function sliceMain([planPath, id]) {
  if (!planPath || !id) {
    console.error("usage: plan.mjs slice <wave-plan.md> <US-ID>");
    process.exit(2);
  }
  try {
    process.stdout.write(slice(readFileSync(planPath, "utf8"), id));
  } catch (error) {
    if (error.count === undefined) throw error;
    console.error(`plan.mjs slice: ${id} has ${error.count} sections in ${planPath} (need exactly 1)`);
    process.exit(1);
  }
}

// ---- validate -----------------------------------------------------------------

const isText = (value) => typeof value === "string" && value.trim() !== "";
const clean = (value) => value.trim().replace(/^`|`$/g, "");
const normalizeCommand = (value) => value.trim().replace(/\s+/g, " ");
const sameSet = (left, right) =>
  left.size === right.size && [...left].every((value) => right.has(value));
const MAX_TASK_BODY_LINES = 55;
const NARRATED_DIFF_PATTERN = /Post-cross-review|an earlier draft/i;
const EMBEDDED_SQL_PATTERN =
  /\bRAISE EXCEPTION\b|\bCREATE (TABLE|TRIGGER|FUNCTION)\b|\bALTER TABLE\b|\bBEFORE (INSERT|UPDATE|DELETE)\b|\bUPDATE\s+\w+\s+SET\b|\bINSERT INTO\b/i;

// CommonMark fences: a fence closes only on the same char, at least as long, bare.
// Returns one entry per line: false outside fences, and for fence lines and everything between
// them the opening fence's indentation as `{ indent }` (truthy).
function fenceMask(lines) {
  let fence = null;
  return lines.map((line) => {
    const [, indent, marker, info] = line.match(/^( {0,3})(`{3,}|~{3,})(.*)$/) ?? [];
    if (marker && !fence) { fence = { marker, indent: indent.length }; return fence; }
    if (marker && marker[0] === fence?.marker[0] && marker.length >= fence.marker.length && !info.trim()) { const closed = fence; fence = null; return closed; }
    return fence ?? false;
  });
}

const cells = (line) => line.trim().replace(/^\||\|$/g, "").split("|").map((cell) => cell.trim());

// Rows of the `## User Stories in this Wave` table with raw (trimmed) cells, or null
// without such a table. Columns resolve by header name; a missing column is undefined.
// The lower-cased header names are on the (non-enumerable) `columns` property.
export function parseStoryTable(text) {
  const lines = text.split(/\r?\n/);
  const fenced = fenceMask(lines);
  const live = (i) => !fenced[i];
  const heading = lines.findIndex((line, i) => live(i) && /^## User Stories in this Wave\s*$/.test(line));
  if (heading < 0) return null;
  let head = heading + 1;
  while (head < lines.length && !(live(head) && /^(\||## )/.test(lines[head]))) head++;
  if (!lines[head]?.startsWith("|") || !live(head + 1) || !/^\|?[\s:|-]*-[\s:|-]*$/.test(lines[head + 1] ?? "")) return null;
  const names = cells(lines[head]).map((name) => name.toLowerCase().replace(/\s+/g, " "));
  const column = (name) => names.indexOf(name);
  const col = { id: column("us id"), scope: column("scope"), agentType: column("agent type"), complexity: column("complexity"), canStart: column("can start when") };
  const rows = Object.defineProperty([], "columns", { value: names });
  for (let i = head + 2; i < lines.length && live(i) && lines[i].startsWith("|"); i++) {
    const row = cells(lines[i]);
    const pick = (index) => (index < 0 ? undefined : row[index]);
    rows.push({ id: pick(col.id), scope: pick(col.scope), agentType: pick(col.agentType), complexity: pick(col.complexity), canStart: pick(col.canStart), line: i + 1 });
  }
  return rows;
}

const PLAN_FORMAT = {
  story: /^## (PROJ-[A-Za-z0-9-]+-PRD-\d+-US-\d+)(?::|\s|$)/,
  ac: /^- \[.\] ([A-Za-z0-9][A-Za-z0-9._-]*AC-[A-Za-z0-9._-]+):\s*(.*)$/,
};
// PRDs (2_requirements-engineer template): `### US-<Z>: …` (or `## US-<Z> — …`), `- [ ] AC-<N>: …`.
export const PRD_FORMAT = {
  story: /^#+ (US-\d+)(?!\d)/,
  ac: /^- \[.\] (AC-[A-Za-z0-9._-]+):\s*(.*)$/,
};

// Story sections (default: `## PROJ-<X>-PRD-<Y>-US-<Z>`) with Scope/Agent, Split and ACs, raw and in
// file order. A section ends at the next heading of the same or a higher level; an AC runs until the
// next AC line, heading, `**Label:**` line, `---` rule or unindented code fence. A fence indented by
// two or more spaces belongs to the list item and stays part of the AC text.
export function parseStories(text, format = PLAN_FORMAT) {
  const lines = text.split(/\r?\n/);
  const fenced = fenceMask(lines);
  const stories = [];
  let story = null, ac = null;
  const closeAc = () => {
    if (ac) ac.text = ac.text.replace(/\n+$/, "");
    ac = null;
  };
  lines.forEach((line, i) => {
    if (fenced[i]) {
      if (ac && fenced[i].indent >= 2) ac.text += `\n${line.replace(/\s+$/, "")}`;
      else closeAc();
      return;
    }
    const level = line.match(/^(#+)\s/)?.[1].length;
    const id = level && line.match(format.story)?.[1];
    if (id || (story && level <= story.level)) {
      closeAc();
      story = id ? { id, heading: line.replace(/^#+\s*/, "").trim(), line: i + 1, level, scope: null, agent: null, split: null, acs: [] } : null;
      if (story) stories.push(story);
      return;
    }
    if (!story) return;
    const acMatch = line.match(format.ac);
    if (acMatch) {
      closeAc();
      ac = { id: acMatch[1], text: acMatch[2].replace(/\s+$/, ""), line: i + 1 };
      story.acs.push(ac);
      return;
    }
    const boundary = /^#|^\*\*[^*]+:\*\*|^---+\s*$/.test(line);
    if (boundary) closeAc();
    const scope = line.match(/^\*\*Scope:\*\*\s*(.*)$/);
    if (scope && story.scope === null) {
      const [name, ...agent] = scope[1].split(/→|->/);
      story.scope = name.trim();
      story.agent = agent.length ? agent.join("→").trim() : null;
    }
    const split = line.match(/^\*\*Split:\*\*\s*`?([^\s+`]+)/);
    if (split && story.split === null) story.split = split[1];
    if (ac && !boundary) ac.text += `\n${line.replace(/\s+$/, "")}`;
  });
  closeAc();
  return stories;
}

const ROLES = ["implementer", "frontend-implementer", "backend-implementer"];
const ROLE_ALIASES = { "fullstack-implementer": "implementer", "full-stack-implementer": "implementer" };
const SIMPLE_SCOPES = ["frontend", "backend", "full-stack"];
const SPLITS = ["none", "contract", "fan-out"];
const normalizeRole = (value) => {
  const role = clean(value).replace(/^skillchain-/, "");
  return ROLE_ALIASES[role] ?? role;
};

// One record per story of a wave plan: the worker role comes from the table's
// `Agent Type` column (normalized), checked fail-closed against the story
// sections. A plan without that column (legacy) maps every story to
// `implementer` with `fallback: true`. Throws an Error naming story and plan.
export function resolveStories(text, planFile) {
  const fail = (id, message) => { throw new Error(`${planFile}: ${id}: ${message}`); };
  const stories = parseStories(text);
  const sections = new Map();
  for (const story of stories) {
    if (sections.has(story.id)) fail(story.id, `duplicate story section (lines ${sections.get(story.id).line} and ${story.line})`);
    sections.set(story.id, story);
  }
  const splitOf = (story) => {
    const split = story.split === null ? "none" : clean(story.split).toLowerCase();
    if (!SPLITS.includes(split)) fail(story.id, `unsupported **Split:** '${story.split}' (expected ${SPLITS.join("|")})`);
    return split;
  };
  const rows = parseStoryTable(text);
  if (!rows?.columns.includes("agent type")) {
    if (stories.length === 0) fail("-", "no story table with an Agent Type column and no story section");
    return stories.map((story) => {
      const row = rows?.find((entry) => clean(entry.id ?? "") === story.id);
      return { id: story.id, scope: story.scope, role: "implementer", agentType: null, complexity: row?.complexity ?? null, canStart: row?.canStart ?? null, split: splitOf(story), fallback: true };
    });
  }
  const resolved = new Map();
  for (const row of rows) {
    const id = clean(row.id ?? "");
    if (resolved.has(id)) fail(id, `duplicate row in the story table (line ${row.line})`);
    const section = sections.get(id);
    if (!section) fail(id, `story table row (line ${row.line}) has no story section`);
    const role = normalizeRole(row.agentType ?? "");
    if (!ROLES.includes(role)) fail(id, `unsupported Agent Type '${row.agentType ?? "(missing cell)"}' (one of ${ROLES.join(", ")}, optional skillchain- prefix)`);
    // Only the first token after the arrow is the agent; trailing prose
    // ("→ implementer. Backend scope shipped in Wave 2.") is not compared.
    const sectionRole = section.agent === null ? null : normalizeRole(section.agent.split(/[\s.(,;]/)[0]);
    if (ROLES.includes(sectionRole) && sectionRole !== role)
      fail(id, `Agent Type '${row.agentType}' contradicts the section's **Scope:** agent '${section.agent}'`);
    const tableScope = clean(row.scope ?? "").toLowerCase();
    const sectionScope = (section.scope ?? "").toLowerCase();
    if (SIMPLE_SCOPES.includes(tableScope) && SIMPLE_SCOPES.includes(sectionScope) && tableScope !== sectionScope)
      fail(id, `table Scope '${tableScope}' contradicts the section's **Scope:** '${sectionScope}'`);
    const split = splitOf(section);
    if (split === "contract" && [tableScope, sectionScope].some((scope) => scope === "frontend" || scope === "backend"))
      fail(id, `Split: contract contradicts the single-sided Scope '${[tableScope, sectionScope].find((scope) => scope === "frontend" || scope === "backend")}'`);
    resolved.set(id, { id, scope: clean(row.scope ?? "") || section.scope, role, agentType: clean(row.agentType), complexity: row.complexity ?? null, canStart: row.canStart ?? null, split });
  }
  for (const story of stories) if (!resolved.has(story.id)) fail(story.id, "story section has no row in the story table");
  return stories.map((story) => resolved.get(story.id));
}

function storiesMain(planFile) {
  if (!planFile) {
    console.error("usage: plan.mjs validate --stories <wave-plan.md>");
    process.exit(64);
  }
  try {
    console.log(JSON.stringify(resolveStories(fs.readFileSync(planFile, "utf8"), planFile), null, 2));
  } catch (error) {
    console.error(`stories: ${error.message}`);
    process.exit(2);
  }
}

function validateMain(args) {
  if (args[0] === "--stories") return storiesMain(args[1]);
  const planDir = path.resolve(args[0] ?? "");
  const repoRoot = path.resolve(args[1] ?? path.join(planDir, "../../.."));
  const errors = [];
  const fail = (message) => errors.push(message);
  if (!args[0]) {
    console.error("usage: plan.mjs validate <3-4_plan-directory> [repository-root]");
    process.exit(2);
  }

  const configPath = path.join(planDir, "wave-gate-config.json");
  if (!fs.existsSync(configPath)) {
    console.error(`plan consistency: missing ${configPath}`);
    process.exit(1);
  }

  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch (error) {
    console.error(`plan consistency: invalid JSON in ${configPath}: ${error.message}`);
    process.exit(1);
  }

  const planFiles = fs
    .readdirSync(planDir)
    .filter((name) => /^PROJ-.+-wave-\d+-plan\.md$/.test(name))
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

  if (planFiles.length === 0) fail("no PROJ-*-wave-<N>-plan.md files found");

  const plans = new Map();
  const allPlanAcs = new Map();
  const wordedAcs = [];

  for (const file of planFiles) {
    const wave = file.match(/-wave-(\d+)-plan\.md$/)?.[1];
    if (!wave) continue;
    if (plans.has(wave)) {
      fail(`wave ${wave}: more than one plan file`);
      continue;
    }

    const tasks = new Map();
    const acceptanceCriteria = new Set();
    let currentTask = null;
    let inFiles = false;
    let inGateCommands = false;

    const planText = fs.readFileSync(path.join(planDir, file), "utf8");
    for (const story of parseStories(planText)) wordedAcs.push(...story.acs.map((ac) => ({ ...ac, file: path.join(planDir, file) })));
    for (const line of planText.split(/\r?\n/)) {
      const taskMatch = line.match(/^### Task ([^:]+):/);
      if (taskMatch) {
        const task = `Task ${taskMatch[1].trim()}`;
        if (tasks.has(task)) fail(`wave ${wave}: duplicate task identifier ${task}`);
        currentTask = { fulfills: new Set(), testFiles: new Set(), commands: new Map(), body: [] };
        tasks.set(task, currentTask);
        inFiles = false;
        inGateCommands = false;
        continue;
      }

      const acMatch = line.match(/^- \[ \] ([A-Za-z0-9][A-Za-z0-9._-]*AC-[A-Za-z0-9._-]+):/);
      if (acMatch) {
        const id = acMatch[1];
        acceptanceCriteria.add(id);
        if (allPlanAcs.has(id)) {
          fail(`acceptance criterion ${id} appears more than once (${allPlanAcs.get(id)} and wave ${wave})`);
        } else {
          allPlanAcs.set(id, wave);
        }
      }

      if (currentTask) currentTask.body.push(line);
      if (!currentTask) continue;
      const fulfillsMatch = line.match(/^\*\*Fulfills:\*\*\s*(.+)$/);
      if (fulfillsMatch) {
        for (const id of fulfillsMatch[1].split(",").map(clean).filter(Boolean)) {
          currentTask.fulfills.add(id);
        }
        inFiles = false;
        inGateCommands = false;
        continue;
      }
      if (line === "**Files:**") {
        inFiles = true;
        inGateCommands = false;
        continue;
      }
      if (line === "**Gate commands:**") {
        inFiles = false;
        inGateCommands = true;
        continue;
      }
      if (/^(###|##|\*\*)/.test(line)) {
        inFiles = false;
        inGateCommands = false;
      }
      if (inFiles) {
        const testMatch = line.match(/^- Test(?: \([^)]*\))?:\s*(.+)$/);
        if (testMatch) currentTask.testFiles.add(clean(testMatch[1]));
      }
      if (inGateCommands) {
        const commandMatch = line.match(/^- `?([A-Za-z0-9][A-Za-z0-9._-]*AC-[A-Za-z0-9._-]+)`?:\s*`(.+)`\s*$/);
        if (commandMatch) {
          const [, id, command] = commandMatch;
          if (currentTask.commands.has(id)) fail(`wave ${wave}: duplicate gate command for ${id}`);
          currentTask.commands.set(id, command);
        }
      }
    }

    const fulfillingTasks = new Map();
    for (const [task, metadata] of tasks) {
      if (metadata.fulfills.size === 0) fail(`wave ${wave} ${task}: missing Fulfills metadata`);
      if (metadata.testFiles.size === 0) fail(`wave ${wave} ${task}: missing Test entry in Files`);
      for (const id of metadata.fulfills) {
        if (!acceptanceCriteria.has(id)) fail(`wave ${wave} ${task}: Fulfills references undeclared AC ${id}`);
        const owners = fulfillingTasks.get(id) ?? [];
        owners.push(task);
        fulfillingTasks.set(id, owners);
        if (!metadata.commands.has(id)) fail(`wave ${wave} ${task}: missing Gate command for ${id}`);
      }
      for (const id of metadata.commands.keys()) {
        if (!metadata.fulfills.has(id)) fail(`wave ${wave} ${task}: Gate command ${id} is absent from Fulfills`);
      }
      const bodyText = metadata.body.join("\n");
      const bodyLines = metadata.body.filter((line) => line.trim() !== "").length;
      if (bodyLines > MAX_TASK_BODY_LINES) {
        fail(`wave ${wave} ${task}: task body is ${bodyLines} non-blank lines (max ${MAX_TASK_BODY_LINES}) — over-specified; split it or move migration/DDL detail to migration-design.md and cite it`);
      }
      if (NARRATED_DIFF_PATTERN.test(bodyText)) {
        fail(`wave ${wave} ${task}: contains narrated-diff scaffolding ("Post-cross-review"/"an earlier draft") — reconcile review feedback by rewriting the task, not by appending review history`);
      }
      if (EMBEDDED_SQL_PATTERN.test(bodyText)) {
        fail(`wave ${wave} ${task}: contains literal SQL/DDL — describe the resulting behaviour in prose, or cite migration-design.md by decision`);
      }
    }
    for (const id of acceptanceCriteria) {
      const owners = fulfillingTasks.get(id) ?? [];
      if (owners.length !== 1) {
        fail(`wave ${wave}: acceptance criterion ${id} must be fulfilled by exactly one task (found ${owners.length})`);
      }
    }
    plans.set(wave, { acceptanceCriteria, tasks });
  }

  // AC wording, byte-exact after the checkbox/ID prefix except for line endings (CRLF = LF), the
  // trailing whitespace of each line, trailing blank lines and the leading spaces of the first
  // line (all dropped by parseStories on both sides): plan PROJ-X-PRD-Y-US-Z-AC-N against
  // AC-N under US-Z in ../2_PRDs/PROJ-X-PRD-Y-*.md (first entry wins). Several such files (e.g. a
  // stray copy): the one whose first H1 is `# PROJ-X-PRD-Y` (or `# PROJ-X PRD-Y`) wins; 2c's
  // `<prd-stem>-review-decisions.md` never counts. No 2_PRDs/ directory: legacy, note only.
  const prdDir = path.join(planDir, "..", "2_PRDs");
  if (!fs.statSync(prdDir, { throwIfNoEntry: false })?.isDirectory()) {
    if (wordedAcs.length) console.error(`note: AC wording not compared against PRDs: ${prdDir} is not a directory (legacy project)`);
  } else {
    const prdNames = fs.readdirSync(prdDir).filter((name) => name.endsWith(".md") && !name.endsWith("-review-decisions.md"));
    const titleOf = (name) => fs.readFileSync(path.join(prdDir, name), "utf8").match(/^# .*$/m)?.[0].match(/^# PROJ-(.+?)[- ]PRD-(\d+)(?!\d)/)?.slice(1).join("/");
    const prdStories = new Map();
    for (const ac of wordedAcs) {
      const plan = `${ac.file}:${ac.line}: ${JSON.stringify(ac.text)}`;
      const [, x, y, us, acId] = ac.id.match(/^PROJ-(.+)-PRD-(\d+)-US-(\d+)-(AC-[A-Za-z0-9._-]+)$/) ?? [];
      if (!acId) { fail(`${ac.id}: no PRD entry, the ID does not follow PROJ-<X>-PRD-<Y>-US-<Z>-AC-<N>\n    plan ${plan}`); continue; }
      let names = prdNames.filter((name) => name.startsWith(`PROJ-${x}-PRD-${y}-`));
      if (names.length > 1) names = names.filter((name) => titleOf(name) === `${x}/${y}`);
      if (names.length !== 1) { fail(`${ac.id}: no PRD entry, expected one ${path.join(prdDir, `PROJ-${x}-PRD-${y}-*.md`)} (titled # PROJ-${x}-PRD-${y} if several), found ${names.length}\n    plan ${plan}`); continue; }
      const prdFile = path.join(prdDir, names[0]);
      if (!prdStories.has(prdFile)) prdStories.set(prdFile, parseStories(fs.readFileSync(prdFile, "utf8"), PRD_FORMAT));
      const prdAc = prdStories.get(prdFile).find((story) => story.id === `US-${us}`)?.acs.find((entry) => entry.id === acId);
      if (!prdAc) fail(`${ac.id}: no PRD entry (${acId} under US-${us})\n    plan ${plan}\n    PRD  ${prdFile}: (missing)`);
      else if (prdAc.text !== ac.text) fail(`${ac.id}: plan wording differs from the PRD\n    plan ${plan}\n    PRD  ${prdFile}:${prdAc.line}: ${JSON.stringify(prdAc.text)}`);
    }
  }

  if (!config || typeof config !== "object" || Array.isArray(config)) {
    fail("config root must be an object");
  }
  const waves = config?.waves;
  if (!waves || typeof waves !== "object" || Array.isArray(waves)) {
    fail("config.waves must be an object");
  }
  if (!isText(config?.sonar_cmd)) {
    fail("sonar_cmd must be a non-empty top-level string");
  }

  const configuredAcs = new Map();
  const regressionFilesByWave = new Map();
  let hasAuthConsumingCommand = false;

  for (const [wave, plan] of plans) {
    const waveConfig = waves?.[wave];
    if (!waveConfig || typeof waveConfig !== "object" || Array.isArray(waveConfig)) {
      fail(`wave ${wave}: missing config.waves.${wave}`);
      continue;
    }

    const acCommands = waveConfig.ac_commands;
    const acEvidence = [];
    if (!Array.isArray(acCommands) || acCommands.length === 0) {
      fail(`wave ${wave}: ac_commands must be a non-empty array`);
    } else {
      acCommands.forEach((entry, index) => {
        const label = `wave ${wave} ac_commands[${index}]`;
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
          fail(`${label}: legacy string entries are unsupported; replace each with {id, task, command, test_files, auth_consuming}`);
          return;
        }
        for (const key of ["id", "task", "command"]) {
          if (!isText(entry[key])) fail(`${label}: ${key} must be a non-empty string`);
        }
        if (Object.hasOwn(entry, "external_dependency")) {
          const dependency = entry.external_dependency;
          if (!dependency || typeof dependency !== "object" || Array.isArray(dependency)) {
            fail(`${label}: external_dependency must be an object`);
          } else {
            for (const key of ["reason", "decided_by", "decided_at", "check_command"]) {
              if (!isText(dependency[key])) fail(`${label}: external_dependency.${key} must be non-empty`);
            }
            if (!/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(dependency.decided_at ?? "") || !Number.isFinite(Date.parse(dependency.decided_at))) {
              fail(`${label}: external_dependency.decided_at must be an ISO timestamp with timezone`);
            }
          }
        }
        if (isText(entry.command) && /&&|\|\||;/.test(entry.command)) {
          fail(`${label}: must invoke exactly one test runner; split shell-chained commands`);
        }
        if (typeof entry.auth_consuming !== "boolean") {
          fail(`${label}: auth_consuming must be boolean`);
        } else if (entry.auth_consuming) {
          hasAuthConsumingCommand = true;
          if (!isText(entry.wave_required_reason)) {
            fail(`${label}: wave_required_reason must explain why hosted auth is needed before CI`);
          }
        }
        if (!Array.isArray(entry.test_files) || entry.test_files.length === 0 || !entry.test_files.every(isText)) {
          fail(`${label}: test_files must be a non-empty string array`);
        }

        if (isText(entry.id)) {
          if (configuredAcs.has(entry.id)) {
            fail(`acceptance criterion ${entry.id} has more than one configured command`);
          } else {
            configuredAcs.set(entry.id, wave);
          }
          if (!plan.acceptanceCriteria.has(entry.id)) {
            fail(`${label}: id ${entry.id} is not declared in the wave ${wave} plan`);
          }
        }

        const task = isText(entry.task) ? plan.tasks.get(entry.task) : null;
        if (isText(entry.task) && !task) fail(`${label}: task ${entry.task} does not exist in the wave ${wave} plan`);
        if (task && isText(entry.id) && !task.fulfills.has(entry.id)) {
          fail(`${label}: task ${entry.task} does not fulfill ${entry.id}`);
        }
        if (task && isText(entry.id) && isText(entry.command) && task.commands.get(entry.id) !== entry.command) {
          fail(`${label}: command differs from ${entry.task} Gate command for ${entry.id}`);
        }
        if (task && Array.isArray(entry.test_files) && entry.test_files.every(isText)) {
          const configuredFiles = new Set(entry.test_files.map(clean));
          if (!sameSet(configuredFiles, task.testFiles)) {
            fail(`${label}: test_files differ from ${entry.task} Files/Test entries (config: ${[...configuredFiles].join(", ")}; plan: ${[...task.testFiles].join(", ")})`);
          }
        }
        if (isText(entry.command) && Array.isArray(entry.test_files) && entry.test_files.length > 0 && entry.test_files.every(isText)) {
          acEvidence.push({ command: normalizeCommand(entry.command), testFiles: new Set(entry.test_files.map(clean)) });
        }
      });
    }

    const regressions = waveConfig.regression_commands;
    const regressionFiles = new Set();
    regressionFilesByWave.set(wave, regressionFiles);
    if (!Array.isArray(regressions) || regressions.length === 0) {
      fail(`wave ${wave}: regression_commands must declare at least one broad regression suite`);
    } else {
      regressions.forEach((entry, index) => {
        const label = `wave ${wave} regression_commands[${index}]`;
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
          fail(`${label}: must be a structured object`);
          return;
        }
        for (const key of ["label", "command"]) {
          if (!isText(entry[key])) fail(`${label}: ${key} must be a non-empty string`);
        }
        if (Object.hasOwn(entry, "selection_check_cmd") && !isText(entry.selection_check_cmd)) {
          fail(`${label}: selection_check_cmd must be a non-empty string`);
        }
        if (isText(entry.command) && /&&|\|\||;/.test(entry.command)) {
          fail(`${label}: must invoke exactly one test runner; split shell-chained commands`);
        }
        if (!Array.isArray(entry.test_files) || entry.test_files.length === 0 || !entry.test_files.every(isText)) {
          fail(`${label}: test_files must be a non-empty string array`);
        } else {
          const entryFiles = new Set(entry.test_files.map(clean));
          entryFiles.forEach((file) => regressionFiles.add(file));
          if (
            isText(entry.command) &&
            acEvidence.some(
              (ac) => ac.command === normalizeCommand(entry.command) && sameSet(ac.testFiles, entryFiles),
            )
          ) {
            fail(`${label}: duplicates an AC command and test_files set; this is not broad regression coverage`);
          }
        }
        if (typeof entry.auth_consuming !== "boolean") {
          fail(`${label}: auth_consuming must be boolean`);
        } else if (entry.auth_consuming) {
          hasAuthConsumingCommand = true;
          if (!isText(entry.wave_required_reason)) {
            fail(`${label}: wave_required_reason must explain why hosted auth is needed before CI`);
          }
        }
        if (Object.hasOwn(entry, "reuse_passed") && typeof entry.reuse_passed !== "boolean") {
          fail(`${label}: reuse_passed must be boolean when present`);
        }
        if (entry.reuse_passed === true && entry.auth_consuming === true) {
          fail(`${label}: reuse_passed cannot cache auth-consuming commands`);
        }
        if (
          Object.hasOwn(entry, "require_non_empty_selection") &&
          typeof entry.require_non_empty_selection !== "boolean"
        ) {
          fail(`${label}: require_non_empty_selection must be boolean when present`);
        }
      });
    }
  }

  for (const key of ["coverage_cmd", "lint_cmd", "complexity_cmd", "arch_rules_cmd", "mutation_cmd"]) {
    if (config[key] !== undefined && !isText(config[key])) fail(`${key} must be a non-empty string`);
  }
  for (const key of ["build_artifacts", "coverage_artifacts"]) {
    if (config[key] !== undefined && (!Array.isArray(config[key]) || !config[key].length || !config[key].every(isText))) fail(`${key} must be a non-empty string array`);
  }
  if (config.coverage_cmd && !config.coverage_artifacts?.length) fail("coverage_cmd requires coverage_artifacts");
  const qualityLabels = new Set();
  for (const entry of Array.isArray(config.phase_commands) ? config.phase_commands : []) {
    if (entry?.phase !== "quality") continue;
    if (qualityLabels.has(entry.label)) fail(`duplicate quality command label: ${entry.label}`);
    qualityLabels.add(entry.label);
    if (config.coverage_cmd && entry.command === config.coverage_cmd) fail("coverage_cmd must not also run as a quality phase command");
  }

  const phaseCommands = config.phase_commands;
  if (phaseCommands !== undefined) {
    if (!Array.isArray(phaseCommands)) {
      fail("phase_commands must be an array when present");
    } else {
      phaseCommands.forEach((entry, index) => {
        const label = `phase_commands[${index}]`;
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
          fail(`${label}: must be a structured object`);
          return;
        }
        for (const key of ["label", "command"]) {
          if (!isText(entry[key])) fail(`${label}: ${key} must be a non-empty string`);
        }
        if (!isText(entry.phase) || !["quality", "ci", "nightly"].includes(entry.phase)) {
          fail(`${label}: phase must be quality, ci, or nightly`);
        }
        if (!Array.isArray(entry.test_files) || entry.test_files.length === 0 || !entry.test_files.every(isText)) {
          fail(`${label}: test_files must be a non-empty string array`);
        }
        if (typeof entry.auth_consuming !== "boolean") {
          fail(`${label}: auth_consuming must be boolean`);
        }
        if (["ci", "nightly"].includes(entry.phase) && !isText(entry.workflow_file)) {
          fail(`${entry.phase} phase command requires workflow_file`);
        } else if (["ci", "nightly"].includes(entry.phase)) {
          const workflowPath = path.resolve(repoRoot, entry.workflow_file);
          if (!fs.existsSync(workflowPath)) {
            fail(`${label}: workflow_file does not exist: ${entry.workflow_file}`);
          } else if (
            isText(entry.command) &&
            !fs
              .readFileSync(workflowPath, "utf8")
              .split(/\r?\n/)
              .some((line) => !/^\s*#/.test(line) && line.includes(entry.command))
          ) {
            fail(`${label}: command is absent from workflow_file ${entry.workflow_file}`);
          }
        }
      });
    }
  }

  for (const wave of Object.keys(waves ?? {})) {
    if (!plans.has(wave)) fail(`config.waves.${wave} has no matching wave plan`);
  }
  for (const [id, wave] of allPlanAcs) {
    if (!configuredAcs.has(id)) fail(`acceptance criterion ${id} from wave ${wave} has no configured command`);
  }

  if (Object.hasOwn(config, "auth_provider_rate_limited") && typeof config.auth_provider_rate_limited !== "boolean") {
    fail("auth_provider_rate_limited must be boolean when present");
  }
  const authBudget = config.auth_budget;
  if (hasAuthConsumingCommand || config.auth_provider_rate_limited === true || authBudget !== undefined) {
    if (!authBudget || typeof authBudget !== "object" || Array.isArray(authBudget)) {
      fail("auth-consuming commands or rate-limited hosted auth require config.auth_budget");
    } else {
      if (!isText(authBudget.preflight_cmd)) fail("auth_budget.preflight_cmd must be a non-empty string");
      if (config.auth_provider_rate_limited === true && !isText(authBudget.rate_limit_evidence_cmd)) {
        fail("rate-limited hosted auth requires auth_budget.rate_limit_evidence_cmd for failures outside the test log");
      }
      if (!Number.isInteger(authBudget.exhausted_exit_code) || authBudget.exhausted_exit_code < 1 || authBudget.exhausted_exit_code > 255) {
        fail("auth_budget.exhausted_exit_code must be an integer from 1 to 255 (default 75)");
      }
    }
  }

  const frontend = config.frontend;
  if (frontend !== undefined) {
    if (!frontend || typeof frontend !== "object" || Array.isArray(frontend)) {
      fail("frontend must be an object");
    } else {
      const routes = frontend.routes;
      if (!Array.isArray(routes)) {
        fail("frontend.routes must be an array");
      } else if (routes.length > 0) {
        if (!isText(frontend.dev_cmd)) fail("frontend.dev_cmd must be a non-empty string when routes are configured");
        if (!isText(frontend.dev_url)) fail("frontend.dev_url must be a non-empty string when routes are configured");
        const readiness = frontend.readiness;
        if (!readiness || typeof readiness !== "object" || Array.isArray(readiness)) {
          fail("frontend.readiness must be an object when routes are configured");
        } else {
          if (!isText(readiness.path)) fail("frontend.readiness.path must be a non-empty string");
          for (const key of ["timeout_seconds", "interval_seconds"]) {
            if (!Number.isInteger(readiness[key]) || readiness[key] <= 0) fail(`frontend.readiness.${key} must be a positive integer`);
          }
        }
        routes.forEach((route, index) => {
          const label = `frontend.routes[${index}]`;
          if (!route || typeof route !== "object" || Array.isArray(route)) {
            fail(`${label}: must be an object`);
            return;
          }
          const wave = String(route.wave ?? "");
          if (!plans.has(wave)) fail(`${label}: wave must name an existing wave`);
          for (const key of ["path", "expected_url", "expected_text"]) {
            if (!isText(route[key])) fail(`${label}: ${key} must be a non-empty string`);
          }
          if (isText(route.path) && isText(route.expected_url) && isText(frontend.dev_url)) {
            try {
              const requestedPath = new URL(route.path, frontend.dev_url).pathname;
              const expectedPath = new URL(route.expected_url, frontend.dev_url).pathname;
              if (requestedPath !== expectedPath) {
                fail(`${label}: expected_url must retain route path ${requestedPath}; redirects are not smoke success`);
              }
            } catch {
              fail(`${label}: path and expected_url must be valid URL references`);
            }
          }
          if (typeof route.protected !== "boolean") fail(`${label}: protected must be boolean`);
          const e2eFiles = route.authenticated_e2e_test_files;
          if (e2eFiles !== undefined && (!Array.isArray(e2eFiles) || e2eFiles.length === 0 || !e2eFiles.every(isText))) {
            fail(`${label}: authenticated_e2e_test_files must be a non-empty string array when present`);
          }
          if (Array.isArray(e2eFiles) && e2eFiles.every(isText) && plans.has(wave)) {
            for (const file of e2eFiles.map(clean)) {
              if (!regressionFilesByWave.get(wave)?.has(file) && !waves[wave]?.ac_commands?.some((ac) => Array.isArray(ac.test_files) && ac.test_files.map(clean).includes(file))) {
                fail(`${label}: authenticated E2E file ${file} is absent from wave ${wave} AC/regression test_files`);
              }
            }
          }
          const hasE2eCoverage = Array.isArray(e2eFiles) && e2eFiles.length > 0 && e2eFiles.every(isText);
          if (route.protected === true && !isText(route.auth_state) && !hasE2eCoverage) {
            fail(`${label}: protected routes require auth_state or authenticated_e2e_test_files`);
          }
        });
      }
    }
  }

  if (errors.length > 0) {
    console.error("wave plan consistency failed:");
    errors.forEach((error) => console.error(`- ${error}`));
    process.exit(1);
  }

  console.log(`wave plan consistency passed: ${plans.size} wave(s), ${allPlanAcs.size} AC(s)`);
}

// ---- context: compile the worker files ------------------------------------
// The whole compiler lives in this function so it runs only for `plan.mjs context`.
// (Its body keeps the original indentation: it contains multi-line template literals.)
function context(argv) {

function usage(candidates) {
  if (candidates) console.error(candidates);
  else console.error(
    "Usage: plan.mjs context <compile|check|show> <proj-x> <theme> [args]\n" +
    "  compile [--wave N|all] [--roles-dir D]\n" +
    "  check   [--roles-dir D]\n" +
    "  show    <US-ID>[.backend|.frontend] | --wave N <role>",
  );
  process.exit(64);
}

const [cmd, projX, theme, ...rest] = argv;
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

function fail(msg, code = 1) { console.error(`plan.mjs context: ${msg}`); process.exit(code); }
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
    for (const req of ["name", "description", "tier", "scope", "inject", "budget_tokens"])
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
  let stories;
  try { stories = resolveStories(text, path); }
  catch (error) { fail(error.message, 2); }
  if (stories.length === 0) fail(`${path}: no story — a wave plan needs at least one story section`, 2);
  return { path, text, stories };
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
  const storiesByWave = allStories();
  const rendered = waves.map((w) => renderWave(w, manifests));
  const breaches = rendered.flatMap((r) => r.breaches);
  if (breaches.length) fail(`budget breach — nothing written:\n  ${breaches.join("\n  ")}\n  Condense the sources or raise that role's manifest budget when its scope genuinely requires it.`);
  const agentFiles = manifests.filter((m) => m.claude?.agent_file === true)
    .map((m) => [join(".claude", "agents", `skillchain-${m.name}.md`), agentFileContent(m)]);
  // Only now touch the disk. A write error leaves a partial set: exit 1, rerun.
  try {
    for (const f of existsSync(OUT_DIR) ? readdirSync(OUT_DIR) : [])
      if (/^bundle-.*\.md$/.test(f) || f === "bundles.lock.json" || f === "blocked-roles.json") rmSync(join(OUT_DIR, f), { force: true });
    for (const dir of [...waveDirs("workers"), ...waveDirs("roles")]) {
      const w = Number(dir.match(/wave-(\d+)$/)[1]);
      if (waves.includes(w) || !PLAN_WAVES.includes(w)) rmSync(dir, { recursive: true, force: true });
    }
    // Waves not compiled now keep their valid files untouched; a file of a
    // story deleted, moved or re-split in that wave's plan, a story file whose
    // header names another role than the plan now resolves (or no parseable
    // header), and a role file without manifest/inject list are removed. The
    // plan hash is deliberately not compared: post-wave notes change a plan
    // after its wave, and finished waves keep their files.
    const roleFiles = new Map(manifests.filter((m) => m.inject.length).map((m) => [`${m.name}.md`, null]));
    for (const dir of [...waveDirs("workers"), ...waveDirs("roles")]) {
      const w = Number(dir.match(/wave-(\d+)$/)[1]);
      const keep = dir.startsWith(join(OUT_DIR, "workers"))
        ? new Map(storiesByWave.get(w).flatMap(storyTargets).map((t) => [`${t.name}.md`, t.role]))
        : roleFiles;
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, entry.name);
        const valid = entry.isFile() && keep.has(entry.name) && (keep.get(entry.name) === null ||
          readFileSync(p, "utf8").split("\n", 1)[0].match(/^Generated from .+ · role (\S+) · wave \d+$/)?.[1] === keep.get(entry.name));
        if (!valid) rmSync(p, { recursive: true, force: true });
      }
    }
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
}

// ---- CLI ----------------------------------------------------------------------
function cli([mode, ...args]) {
  if (mode === "validate") return validateMain(args);
  if (mode === "slice") return sliceMain(args);
  if (mode === "context") return context(args);
  console.error("usage: plan.mjs validate|slice|context …  (see the header of plan.mjs)");
  process.exit(64);
}

// Run the CLI only when started directly (symlink-safe), not when imported by a test.
// argv[1] is no path under `node -e`; an unresolvable one means "imported".
const isMain = () => { try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; } };
if (isMain()) cli(process.argv.slice(2));
