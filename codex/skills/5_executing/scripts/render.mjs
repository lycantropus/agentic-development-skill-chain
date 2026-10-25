#!/usr/bin/env node
// render.mjs — deterministic document rendering from state.json, findings.json
// and the plan's gate config (CONCEPT.md §7, §8). Pure render: the only files
// written are the report documents; no check is run, and prerequisite
// declarations are not acceptance evidence.
//
//   render.mjs pr <proj-x> <theme> [template-path]
//     Prints the PR body (P8). The template defaults to templates/pr-body.md.tmpl,
//     then the copy shipped with the skills.
//   render.mjs pr --selftest
//   render.mjs report morning [specs-dir]
//     Scans <specs-dir>/PROJ-*/state.json, writes <specs-dir>/morning-report-<date>.md
//     and prints the one-liner for the best-effort push notification.
//   render.mjs report stop <proj-x> <theme> --reason "<text>" [--error-file <path>]
//     Writes specs/PROJ-<X>-<theme>/5_progress/stop-report.md.
//
// The report resume command names the phase runner: SKILLCHAIN_RUNNER_DIR, else the
// runner shipped next to the installed skills; without one the report says to resume through P8.
// Exit: 0 ok · 1 render failed · 2 required input missing · 64 usage
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readFindings } from "./findings-store.mjs";
import { resolveInputs } from "./resolve-inputs.mjs";
import { integrationStatus } from "./integration-status.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const [kind, ...args] = process.argv.slice(2);

const usage = () => {
  console.error(
    "Usage: render.mjs pr <proj-x> <theme> [template-path] | pr --selftest\n" +
    "       render.mjs report morning [specs-dir]\n" +
    "       render.mjs report stop <proj-x> <theme> --reason <text> [--error-file <path>]",
  );
  process.exit(64);
};

// ---- shared ---------------------------------------------------------------
const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));
const findingsFor = readFindings;
const gateConfigPath = (base) =>
  ["3-4_plan", "6_plan"].map((dir) => join(base, dir, "wave-gate-config.json")).find(existsSync);
// One line per declared external prerequisite: a declaration, never a pass.
const externalPrerequisites = (base) => {
  const configPath = gateConfigPath(base);
  if (!configPath) return [];
  return Object.entries(readJson(configPath).waves ?? {}).flatMap(([wave, value]) =>
    (value.ac_commands ?? []).filter((ac) => ac.external_dependency).map((ac) => {
      const d = ac.external_dependency;
      return `- External prerequisite (declaration, not a pass): ${ac.id} / wave ${wave} — ${d.reason}; decided by ${d.decided_by} at ${d.decided_at}. Readiness: \`${d.check_command}\`; evidence: 5_progress/ralph-wave-${wave}.json.`;
    }));
};
const degradedLine = (s) => `⚠ Provider degradation: ${s.degraded_reason ?? "reason not recorded"}`;
// First existing copy: the project's templates/, next to a synchronized or installed render.mjs, the delivery skill's.
const templateFile = (name) => {
  const found = ["templates", join(here, "..", "templates"), join(here, "..", "..", "8_delivery", "templates")]
    .map((dir) => join(dir, name)).find(existsSync);
  if (!found) { console.error(`render.mjs: template ${name} not found`); process.exit(2); }
  return found;
};
const fill = (template, values) => {
  let out = template;
  for (const [k, v] of Object.entries(values)) out = out.replaceAll(`{{${k}}}`, () => String(v));
  const left = out.match(/{{[A-Z_]+}}/g);
  if (left) { console.error(`render.mjs: unreplaced placeholders: ${[...new Set(left)].join(", ")}`); process.exit(1); }
  return out;
};

// ---- pr -------------------------------------------------------------------
const storySummary = (metadata) => {
  if (!metadata || typeof metadata !== "object") return String(metadata ?? "unknown");
  return [metadata.title, metadata.status, Number.isInteger(metadata.wave) ? `wave ${metadata.wave}` : null]
    .filter((value) => typeof value === "string" && value.length > 0)
    .join(" — ") || "status unknown";
};

function pr([projX, theme, templateArg]) {
  if (projX === "--selftest") {
    if (storySummary("complete") !== "complete") throw new Error("string story metadata changed");
    if (storySummary({ status: "complete", wave: 2 }) !== "complete — wave 2") throw new Error("object story metadata failed");
    if (storySummary({ title: "Register", status: "complete" }) !== "Register — complete") throw new Error("story title failed");
    console.log("✓ render pr story metadata self-test");
    return;
  }
  if (!projX || !theme) usage();

  const base = `specs/PROJ-${projX}-${theme}`;
  const templatePath = templateArg ?? templateFile("pr-body.md.tmpl");
  for (const f of [`${base}/state.json`, templatePath]) {
    if (!existsSync(f)) { console.error(`render.mjs: ${f} missing`); process.exit(2); }
  }

  const state = readJson(`${base}/state.json`);
  const findings = findingsFor(base);
  const count = (pred) => findings.filter(pred).length;
  const stories = Object.entries(state.waves?.stories ?? {});

  const storiesBlock = stories.length
    ? stories.map(([us, metadata]) => `- ${us}: ${storySummary(metadata)}`).join("\n")
    : "_no per-story status recorded_";

  let gateSummary = [
    `- Waves: ${state.waves?.current ?? "?"}/${state.waves?.total ?? "?"} complete`,
    `- Findings: ${findings.length} total — ` +
      `${count((f) => f.status === "fixed")} fixed, ` +
      `${count((f) => f.status === "deferred")} deferred, ` +
      `${count((f) => f.status === "false-positive")} false-positive, ` +
      `${count((f) => f.status === "open")} open`,
    `- Open blocking (critical/high): ${count((f) => f.status === "open" && (f.severity === "critical" || f.severity === "high"))}`,
  ].join("\n");

  const inputs = resolveInputs(base, { allowBlocked: true });
  if (inputs) {
    const integration = integrationStatus(inputs, base);
    gateSummary += `\n\n### External product scope\n\n` +
      `- Baseline: ${inputs.baselineIdentity}; accepted team revision: ${inputs.team?.revision ?? "missing"}\n` +
      `- Repository: ${inputs.repository}; delivery scope: ${inputs.repositories.join(", ")}\n` +
      `- Input readiness: ${inputs.blockers.length ? inputs.blockers.join("; ") : "ready for this repository"}\n` +
      `- Dependencies: ${inputs.dependencies.filter(d => d.repository === inputs.repository).map(d => `${d.requires}@${d.revision}: ${d.evidence}`).join("; ") || "none declared"}\n` +
      `- Shared integration: ${integration.status}${integration.reasons.length ? " — " + integration.reasons.join("; ") : " — pinned combined test evidence recorded"}\n` +
      `- Tested revisions: ${integration.repositories?.map(r => `${r.key}@${r.revision}`).join(", ") || "not recorded"}\n` +
      `- Release order: ${integration.releaseOrder?.join(" → ") || "not recorded"}\n` +
      `- This PR and its local gates do not establish whole-feature completion.`;
  }

  const gaps = externalPrerequisites(base);
  const knownGaps = gaps.length ? gaps.join("\n") : "none";

  const debt = findings.filter((f) => f.status === "deferred");
  const debtSection = debt.length
    ? ["| ID | Severity | File | Summary |", "|---|---|---|---|",
       ...debt.map((f) => `| ${f.id} | ${f.severity} | ${f.file ?? "—"} | ${f.summary.replaceAll("|", "\\|").replace(/\r\n|\r|\n/g, "<br>")} |`),
      ].join("\n")
    : "none";

  const docChanges = (state.docs_changed ?? []).length
    ? state.docs_changed.map((d) => `- ${d}`).join("\n")
    : "—";

  const worktreeIsolation = state.worktree
    ? `dependencies: ${state.worktree.dependency_install ?? "unknown"}; ` +
      `.env.local: ${state.worktree.env_link_status ?? "unknown"}; ` +
      `database/auth infrastructure: shared; dev port: ${state.worktree.dev_port ?? "—"}`
    : "legacy run — no PROJ worktree metadata";

  const worktreeCleanup = state.worktree
    ? `${state.worktree.cleanup_status ?? "pending"}` +
      (state.worktree.cleanup_reason ? ` — ${state.worktree.cleanup_reason}` : "")
    : "not applicable";

  process.stdout.write(fill(readFileSync(templatePath, "utf8"), {
    PROJ: state.proj,
    PROJ_NUMBER: projX,
    THEME: theme,
    BRANCH: state.branch ?? `proj/PROJ-${projX}`,
    BASE_SHA: state.base_sha ?? "—",
    SUMMARY: state.summary ?? "_no summary recorded in state.json_",
    STORIES: storiesBlock,
    GATE_SUMMARY: gateSummary,
    KNOWN_GAPS: knownGaps,
    DEBT_SECTION: debtSection,
    DEGRADATIONS: state.degraded ? degradedLine(state) : "none",
    WORKTREE_ISOLATION: worktreeIsolation,
    WORKTREE_CLEANUP: worktreeCleanup,
    DOC_CHANGES: docChanges,
    RENDERED_AT: new Date().toISOString(),
  }));
}

// ---- report ---------------------------------------------------------------
const today = new Date().toISOString().slice(0, 10);
const now = new Date().toISOString();
const shellQuote = (value) => `'${String(value).replaceAll("'", `'"'"'`)}'`;
const runnerScript = () => {
  const dirs = [process.env.SKILLCHAIN_RUNNER_DIR, join(here, "..", "runner"), join(here, "..", "..", "..", "..", "runner")];
  const dir = dirs.find((d) => d && existsSync(join(d, "run-phase.sh")));
  return dir ? join(dir, "run-phase.sh") : null;
};
const safeP8Resume = (s) => {
  if (!s.worktree?.path) return null;
  const projX = String(s.proj ?? "").replace(/^PROJ-/, "");
  const runner = runnerScript();
  if (!runner || !/^\d+$/.test(projX) || typeof s.theme !== "string") return null;
  return `(cd ${shellQuote(s.worktree.path)} && ${shellQuote(runner)} P8 ${shellQuote(projX)} ${shellQuote(s.theme)})`;
};
const cleanupDisplay = (wt) =>
  wt?.cleanup_status === "removed" && existsSync(wt.path)
    ? "removal sealed; awaiting guarded cleanup"
    : (wt?.cleanup_status ?? "pending");

function morning([specsArg]) {
  const specsDir = specsArg ?? "specs";
  if (!existsSync(specsDir)) { console.error(`render.mjs: ${specsDir} missing`); process.exit(2); }

  const projDirs = readdirSync(specsDir)
    .filter((d) => /^PROJ-\d+-/.test(d) && existsSync(join(specsDir, d, "state.json")))
    .sort();
  if (projDirs.length === 0) { console.error(`render.mjs: no PROJ-*/state.json under ${specsDir}`); process.exit(2); }

  let prs = 0, stops = 0, done = 0;
  const blocks = projDirs.map((dir) => {
    const base = join(specsDir, dir);
    const s = readJson(join(base, "state.json"));
    const f = findingsFor(base);
    const deferred = f.filter((x) => x.status === "deferred");
    const openBlocking = f.filter((x) => x.status === "open" && (x.severity === "critical" || x.severity === "high"));
    const wt = s.worktree;
    if (s.pr?.url) prs++;
    if (s.status === "blocked") stops++;
    if (s.phase === "P8" && s.status === "done" || s.phase === "done") done++;

    const lines = [
      `## ${s.proj} (${s.theme}) — ${s.phase}:${s.status}`,
      "",
      s.pr?.url ? `- **PR:** ${s.pr.url} (CI: ${s.pr.ci ?? "unknown"})` : "- **PR:** not created",
      `- **Waves:** ${s.waves?.current ?? "—"}/${s.waves?.total ?? "—"}`,
      "- **Wave-gate scope:** current ACs plus each wave's declared broad regressions; earlier AC commands are not implicitly rerun",
      `- **Findings:** ${f.length} total · ${openBlocking.length} open blocking · ${deferred.length} deferred debt`,
      ...externalPrerequisites(base),
      wt
        ? `- **Worktree:** \`${wt.path}\` (${cleanupDisplay(wt)}${wt.cleanup_reason ? ` — ${wt.cleanup_reason}` : ""})`
        : "- **Worktree:** not recorded",
      wt
        ? `- **Isolation:** dependencies ${wt.dependency_install ?? "unknown"}; .env.local ${wt.env_link_status ?? "unknown"}; database/auth infrastructure shared; dev port ${wt.dev_port ?? "—"}`
        : "- **Isolation:** legacy run",
      s.degraded ? `- **Degradation:** ${degradedLine(s)}` : "- **Degradation:** none",
    ];
    if (s.status === "blocked") {
      lines.push(`- **STOPPED:** ${s.stop?.reason ?? "unknown"} — report: ${s.stop?.report ?? "missing"}`);
      if (s.stop?.rescue_branch) lines.push(`- **Cleanup:** rescue branch \`${s.stop.rescue_branch}\` to inspect/merge/delete`);
    }
    if (wt?.cleanup_status === "retained") {
      const retry = safeP8Resume(s);
      lines.push(retry
        ? `- **Safe cleanup resume (reseals, pushes, and re-polls exact HEAD):** \`${retry}\``
        : "- **Cleanup:** resume through P8 and obtain final green CI before running the guarded worktree helper");
    }
    if (deferred.length) {
      lines.push("", "  Deferred debt (decide at CP2):");
      for (const d of deferred) lines.push(`  - ${d.id} [${d.severity}] ${d.file ?? ""} — ${d.summary}`);
    }
    return lines.join("\n");
  });

  const oneliner = `${projDirs.length} PROJ(s): ${done} done, ${prs} PR(s) open, ${stops} stop report(s)`;
  const out = fill(readFileSync(templateFile("morning-report.md.tmpl"), "utf8"), {
    DATE: today,
    ONELINER: `**${oneliner}**`,
    PROJS: blocks.join("\n\n"),
  });
  const outPath = join(specsDir, `morning-report-${today}.md`);
  writeFileSync(outPath, out);
  console.log(oneliner);
  console.log(`report: ${outPath}`);
}

function stop(rest) {
  const [projX, theme] = rest;
  if (!projX || !theme) usage();
  const reasonIdx = rest.indexOf("--reason");
  if (reasonIdx < 0 || !rest[reasonIdx + 1]) usage();
  const reason = rest[reasonIdx + 1];
  const errIdx = rest.indexOf("--error-file");
  const errFile = errIdx >= 0 ? rest[errIdx + 1] : null;

  const base = `specs/PROJ-${projX}-${theme}`;
  if (!existsSync(join(base, "state.json"))) { console.error(`render.mjs: ${base}/state.json missing`); process.exit(2); }
  const s = readJson(join(base, "state.json"));

  let errorOutput = "(no captured output)";
  if (errFile && existsSync(errFile)) {
    const raw = readFileSync(errFile, "utf8").split("\n");
    errorOutput = raw.slice(-120).join("\n").trim() || errorOutput;
  }

  const lanes = (s.lanes ?? []).slice(-4).map(
    (l) => `- lane ${l.provider}/${l.role} (${l.phase}): exit ${l.exit_code ?? "running?"} — output: ${l.output_file ?? "—"}`,
  );
  const stateSummary = [
    `- Phase/status: ${s.phase}:${s.status}`,
    `- Branch: \`${s.branch ?? "—"}\` (base ${s.base_sha ?? "—"})`,
    s.worktree
      ? `- Worktree: \`${s.worktree.path}\` from control \`${s.worktree.control_path}\` (${cleanupDisplay(s.worktree)}${s.worktree.cleanup_reason ? ` — ${s.worktree.cleanup_reason}` : ""})`
      : "- Worktree: not recorded (legacy run)",
    s.worktree
      ? `- Isolation: dependencies ${s.worktree.dependency_install ?? "unknown"}; .env.local ${s.worktree.env_link_status ?? "unknown"}; database/auth infrastructure shared; dev port ${s.worktree.dev_port ?? "—"}`
      : null,
    `- Waves: ${s.waves?.current ?? "—"}/${s.waves?.total ?? "—"}; stories: ${
      Object.entries(s.waves?.stories ?? {}).map(([us, st]) => `${us}=${st}`).join(", ") || "—"
    }`,
    ...lanes,
    ...externalPrerequisites(base),
  ].filter(Boolean).join("\n");

  const cleanup = [
    s.stop?.rescue_branch ? `- Rescue branch \`${s.stop.rescue_branch}\`: inspect, salvage, delete` : null,
    `- Lane output files under \`${base}/5_progress/lanes/\`: review, then remove`,
    s.worktree?.path
      ? (safeP8Resume(s)
          ? `- Retained PROJ worktree \`${s.worktree.path}\`: after resolving the stop, resume P8 (reseal, push, exact-head CI, guarded cleanup) with \`${safeP8Resume(s)}\``
          : `- Retained PROJ worktree \`${s.worktree.path}\`: resume through P8 and obtain final green CI before running \`scripts/chain worktree cleanup\``)
      : "- Open worktrees / dev servers (if any): documented above — evidence, do not delete before reading",
  ].filter(Boolean).join("\n");

  const out = fill(readFileSync(templateFile("stop-report.md.tmpl"), "utf8"), {
    PROJ: s.proj,
    THEME: s.theme,
    DATE: now,
    PHASE_STATUS: `${s.phase}:${s.status}`,
    REASON: reason,
    ERROR_OUTPUT: errorOutput,
    STATE_SUMMARY: stateSummary,
    CLEANUP: cleanup,
    NEXT_ACTION:
      `Fix the stop cause, then resume with ` +
      `\`bash scripts/chain state transition ${projX} ${theme} ${s.phase} running\` ` +
      `and re-run \`runner/run-phase.sh ${s.phase} ${projX} ${theme}\`.`,
  });

  mkdirSync(join(base, "5_progress"), { recursive: true });
  const outPath = join(base, "5_progress", "stop-report.md");
  writeFileSync(outPath, out);
  console.log(`stop report: ${outPath}`);
}

if (kind === "pr") {
  try { pr(args); }
  catch (error) { console.error(`render.mjs: ${error.message}`); process.exitCode = 1; }
}
else if (kind === "report" && args[0] === "morning") morning(args.slice(1));
else if (kind === "report" && args[0] === "stop") stop(args.slice(1));
else usage();
