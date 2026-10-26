// Shared reader for stage-local ledgers; never scans generated handoff packages.
import fs from "node:fs";
import path from "node:path";

export const STAGE_DIRS = {
  concept: "1_concept", requirements: "2_PRDs", architecture: "3-4_plan", plan: "3-4_plan",
  implementation: "5_progress", qa: "6_qa", docs: "7_documentation", delivery: "8_delivery",
};
export const REFINEMENT_DIR = "refinement";

// Only handoff-package creates 2b_handoff/, so a marker beside it sits in the source product project.
export function assertNotSourceProject(base) {
  if (fs.lstatSync(path.join(base, "2b_handoff"), { throwIfNoEntry: false }))
    throw new Error("external-handoff.json must not share a source product project (2b_handoff/ present); use a sibling refinement project");
}
const LEGACY_DIRS = { "2_PRDs": "3_PRDs", "3-4_plan": "6_plan", "5_progress": "7_progress" };

export function stageDirectory(base, stage) {
  const directory = STAGE_DIRS[stage];
  if (!directory) throw new Error(`unknown findings stage '${stage}'`);
  if (stage === "requirements" && fs.existsSync(path.join(base, "external-handoff.json"))) {
    assertNotSourceProject(base);
    const existing = [REFINEMENT_DIR, "2_PRDs", "3_PRDs"].filter(dir =>
      fs.existsSync(path.join(base, dir, "findings.json")));
    if (existing.length > 1) throw new Error("multiple requirements/refinement ledgers: reconcile before migration");
    // Keep old ledgers usable until the explicit, lossless migration.
    return path.join(base, existing[0] ?? REFINEMENT_DIR);
  }
  const legacy = LEGACY_DIRS[directory];
  return path.join(base, !fs.existsSync(path.join(base, directory)) && legacy && fs.existsSync(path.join(base, legacy)) ? legacy : directory);
}

export function readFindingLedgers(base) {
  stageDirectory(base, "requirements");
  const directories = ["", REFINEMENT_DIR, ...new Set(Object.values(STAGE_DIRS)), ...Object.values(LEGACY_DIRS)];
  const ids = new Set();
  return directories.flatMap(directory => {
    const parent = path.join(base, directory), file = path.join(parent, "findings.json");
    if (fs.lstatSync(parent, { throwIfNoEntry: false })?.isSymbolicLink() || fs.lstatSync(file, { throwIfNoEntry: false })?.isSymbolicLink()) throw new Error(`refusing findings symlink: ${file}`);
    if (!fs.existsSync(file)) return [];
    const ledger = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!Array.isArray(ledger.findings)) throw new Error(`invalid findings ledger: ${file}`);
    for (const finding of ledger.findings) {
      if (ids.has(finding.id)) throw new Error(`duplicate finding ID ${finding.id} across ledgers`);
      ids.add(finding.id);
    }
    return [{ file, ledger }];
  });
}

export const readFindings = base => readFindingLedgers(base).flatMap(({ ledger }) => ledger.findings);
