#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "stage-findings-"));
try {
  for (const provider of ["codex", "claude"]) {
    const work = path.join(temp, provider); fs.mkdirSync(work);
    const base = path.join(work, "specs/PROJ-1-test"); fs.mkdirSync(base, { recursive: true });
    const script = path.join(root, provider, "skills/6_qa/scripts/findings.mjs");
    const run = (args, input) => spawnSync(process.execPath, [script, ...args], { cwd: work, input, encoding: "utf8" });
    const ok = (args, input) => { const result = run(args, input); assert.equal(result.status, 0, result.stderr); return result.stdout; };
    const record = JSON.stringify({ source: "cross-review", severity: "high", summary: "Check contract", file: "spec.md", anchor: "contract" });
    const stages = { concept: "1_concept", requirements: "2_PRDs", architecture: "3-4_plan", qa: "6_qa", docs: "7_documentation", delivery: "8_delivery", implementation: "5_progress" };
    const initial = JSON.parse(ok(["list", "1", "test"])); assert.equal(initial.findings.length, 0);
    assert.deepEqual(fs.readdirSync(base), [], "reads must not create ledgers");
    // Parallel writers share the project lock and allocate unique global IDs.
    await Promise.all(Object.keys(stages).map(stage => new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [script, "add", "1", "test", "--stage", stage], { cwd: work, stdio: ["pipe", "pipe", "pipe"] });
      let error = ""; child.stderr.on("data", data => error += data);
      child.on("error", reject); child.on("exit", code => code === 0 ? resolve() : reject(new Error(error)));
      child.stdin.end(record);
    })));
    const aggregate = () => JSON.parse(ok(["list", "1", "test"])).findings;
    assert.equal(aggregate().length, 7); assert.equal(new Set(aggregate().map(f => f.id)).size, 7);
    assert.equal(fs.existsSync(path.join(base, "findings.json")), false, "no central copy");
    for (const [stage, directory] of Object.entries(stages)) {
      const file = path.join(base, directory, "findings.json");
      const findings = JSON.parse(fs.readFileSync(file)).findings; assert.equal(findings.length, 1);
      const id = findings[0].id;
      assert.equal(JSON.parse(ok(["list", "1", "test", "--stage", stage])).findings[0].id, id);
      ok(["set-status", "1", "test", id, "fixed", "abc"]);
      ok(["record-attempt", "1", "test", id]);
      assert.equal(JSON.parse(fs.readFileSync(file)).findings[0].fix_attempts, 1);
      ok(["add", "1", "test", "--stage", stage], record);
      assert.equal(JSON.parse(fs.readFileSync(file)).findings[0].status, "open", "re-report reopens in its own stage");
      assert.equal(aggregate().length, 7);
    }
    // Plan and architecture share their artifact folder and dedupe there.
    ok(["add", "1", "test", "--stage", "plan"], record); assert.equal(aggregate().length, 7);
    assert.equal(JSON.parse(ok(["stats", "1", "test"])).open_blocking, 7);
    ok(["set-status", "1", "test", aggregate()[0].id, "deferred"]);
    assert.equal(JSON.parse(ok(["stats", "1", "test"])).open_blocking, 6);
    // Existing root ledgers stay readable and are updated in place; no automatic migration.
    const progress = path.join(base, "5_progress/findings.json");
    fs.renameSync(progress, path.join(base, "findings.json"));
    const old = JSON.parse(fs.readFileSync(path.join(base, "findings.json"))).findings[0];
    ok(["set-status", "1", "test", old.id, "fixed"]);
    assert.equal(JSON.parse(fs.readFileSync(path.join(base, "findings.json"))).findings[0].status, "fixed");
    ok(["add", "1", "test"], record);
    assert.equal(fs.existsSync(progress), false, "legacy duplicate must reuse its owner");
    assert.equal(aggregate().length, 7);
    const before = fs.readFileSync(path.join(base, "1_concept/findings.json"), "utf8");
    assert.equal(run(["add", "1", "test", "--stage", "../2b_handoff"], record).status, 1);
    assert.equal(fs.readFileSync(path.join(base, "1_concept/findings.json"), "utf8"), before);
    // Generated packages are excluded, even if they contain a findings.json file.
    fs.mkdirSync(path.join(base, "2b_handoff/run"), { recursive: true });
    fs.writeFileSync(path.join(base, "2b_handoff/run/findings.json"), "invalid generated artifact");
    assert.equal(aggregate().length, 7);
    fs.renameSync(path.join(base, "2_PRDs"), path.join(base, "3_PRDs"));
    ok(["add", "1", "test", "--stage", "requirements"], record);
    assert.equal(fs.existsSync(path.join(base, "2_PRDs")), false, "legacy folder remains canonical");
    assert.equal(aggregate().length, 7);
    // External refinement migrates the existing ledger without rewriting any history.
    assert.notEqual(run(["migrate-refinement", "1", "test"]).status, 0, "linear projects cannot migrate");
    const oldRequirements = path.join(base, "3_PRDs/findings.json");
    const preserved = fs.readFileSync(oldRequirements);
    fs.writeFileSync(path.join(base, "external-handoff.json"), '{"schemaVersion":1}');
    // A marker beside 2b_handoff/ sits in the source product project: every path refuses, nothing written.
    assert.match(run(["add", "1", "test", "--stage", "requirements"], record).stderr, /sibling refinement project/);
    assert.equal(fs.existsSync(path.join(base, "refinement")), false);
    fs.mkdirSync(path.join(base, "refinement"));
    fs.copyFileSync(oldRequirements, path.join(base, "refinement/findings.json"));
    assert.match(run(["migrate-refinement", "1", "test"]).stderr, /sibling refinement project.*nothing written/);
    assert.deepEqual(fs.readFileSync(oldRequirements), preserved);
    assert.deepEqual(fs.readFileSync(path.join(base, "refinement/findings.json")), preserved);
    fs.rmSync(path.join(base, "refinement"), { recursive: true });
    fs.rmSync(path.join(base, "2b_handoff"), { recursive: true });
    assert.equal(JSON.parse(ok(["list", "1", "test", "--stage", "requirements"])).findings.length, 1);
    ok(["migrate-refinement", "1", "test"]);
    const refinement = path.join(base, "refinement/findings.json");
    assert.deepEqual(fs.readFileSync(refinement), preserved, "IDs, attempts, status and provenance are byte-identical");
    assert.equal(fs.existsSync(oldRequirements), false);
    ok(["migrate-refinement", "1", "test"]);
    assert.deepEqual(fs.readFileSync(refinement), preserved, "migration is idempotent");
    const migrated = JSON.parse(preserved).findings[0];
    ok(["set-status", "1", "test", migrated.id, "fixed", "revision"]);
    ok(["record-attempt", "1", "test", migrated.id]);
    ok(["add", "1", "test", "--stage", "requirements"], record);
    assert.equal(aggregate().length, 7, "re-report dedupes after migration");
    const updated = JSON.parse(ok(["list", "1", "test", "--stage", "requirements"])).findings[0];
    assert.equal(updated.id, migrated.id); assert.equal(updated.status, "open");
    assert.equal(updated.fix_attempts, migrated.fix_attempts + 1);
    fs.mkdirSync(path.join(base, "runs/second/refinement"), { recursive: true });
    ok(["add", "1", "test", "--stage", "requirements"], JSON.stringify({ ...JSON.parse(record), anchor: "second-round" }));
    assert.ok(aggregate().some(f => f.id === "F-PROJ-1-008"), "IDs continue across stages and runs");
    assert.equal(fs.existsSync(path.join(base, "runs/second/refinement/findings.json")), false);
    // A second ledger blocks ordinary use, and migrate-refinement merges it losslessly.
    const beforeMerge = JSON.parse(fs.readFileSync(refinement)).findings;
    const extra = { ...beforeMerge[0], id: "F-PROJ-1-099", summary: "old-ledger only" };
    fs.writeFileSync(oldRequirements, JSON.stringify({ proj: "PROJ-1", findings: [beforeMerge[0], extra] }));
    assert.notEqual(run(["list", "1", "test"]).status, 0, "conflicting ledgers fail closed");
    const conflicting = { ...beforeMerge[0], summary: "edited elsewhere" };
    fs.writeFileSync(oldRequirements, JSON.stringify({ proj: "PROJ-1", findings: [conflicting] }));
    assert.notEqual(run(["migrate-refinement", "1", "test"]).status, 0, "a differing duplicate ID needs its owner");
    assert.equal(fs.existsSync(oldRequirements), true);
    fs.writeFileSync(oldRequirements, JSON.stringify({ proj: "PROJ-2", findings: [extra] }));
    assert.notEqual(run(["migrate-refinement", "1", "test"]).status, 0, "another project's ledger is never merged");
    fs.writeFileSync(oldRequirements, JSON.stringify({ proj: "PROJ-1" }));
    assert.notEqual(run(["migrate-refinement", "1", "test"]).status, 0, "a malformed ledger is never dropped");
    assert.equal(fs.existsSync(oldRequirements), true);
    fs.unlinkSync(oldRequirements);
    const outside = path.join(work, "outside-prds"); fs.mkdirSync(outside);
    fs.writeFileSync(path.join(outside, "findings.json"), JSON.stringify({ proj: "PROJ-1", findings: [extra] }));
    fs.rmSync(path.join(base, "3_PRDs"), { recursive: true }); fs.symlinkSync(outside, path.join(base, "3_PRDs"));
    assert.notEqual(run(["migrate-refinement", "1", "test"]).status, 0, "a symlinked ledger directory is refused");
    assert.equal(fs.existsSync(path.join(outside, "findings.json")), true);
    fs.unlinkSync(path.join(base, "3_PRDs")); fs.mkdirSync(path.join(base, "3_PRDs"));
    const outsideRefinement = path.join(work, "outside-refinement"); fs.mkdirSync(outsideRefinement);
    const realRefinement = path.join(base, "refinement.real"); fs.renameSync(path.join(base, "refinement"), realRefinement);
    fs.symlinkSync(outsideRefinement, path.join(base, "refinement"));
    fs.writeFileSync(oldRequirements, JSON.stringify({ proj: "PROJ-1", findings: [extra] }));
    assert.notEqual(run(["migrate-refinement", "1", "test"]).status, 0, "a symlinked refinement directory is refused");
    assert.equal(fs.existsSync(path.join(outsideRefinement, "findings.json")), false);
    fs.unlinkSync(oldRequirements); fs.unlinkSync(path.join(base, "refinement")); fs.renameSync(realRefinement, path.join(base, "refinement"));
    const reordered = Object.fromEntries(Object.entries(beforeMerge[0]).reverse());
    fs.writeFileSync(oldRequirements, JSON.stringify({ proj: "PROJ-1", findings: [reordered, extra] }));
    ok(["migrate-refinement", "1", "test"]);
    assert.equal(fs.existsSync(oldRequirements), false);
    assert.deepEqual(JSON.parse(fs.readFileSync(refinement)).findings, [...beforeMerge, extra], "every record kept verbatim");
    ok(["set-status", "1", "test", extra.id, "fixed", "revision"]);
    const fresh = path.join(work, "specs/PROJ-2-external"); fs.mkdirSync(fresh);
    fs.writeFileSync(path.join(fresh, "external-handoff.json"), '{"schemaVersion":1}');
    ok(["add", "2", "external", "--stage", "requirements"], record);
    assert.equal(fs.existsSync(path.join(fresh, "refinement/findings.json")), true);
    assert.equal(fs.existsSync(path.join(fresh, "2_PRDs")), false);
    // Current numbered requirements ledgers migrate too; unrelated documents remain.
    const numbered = path.join(work, "specs/PROJ-3-received"); fs.mkdirSync(numbered);
    ok(["add", "3", "received", "--stage", "requirements"], record);
    const numberedLedger = path.join(numbered, "2_PRDs/findings.json");
    const numberedBytes = fs.readFileSync(numberedLedger);
    fs.writeFileSync(path.join(numbered, "2_PRDs/notes.md"), "Keep original evidence");
    fs.writeFileSync(path.join(numbered, "external-handoff.json"), '{"schemaVersion":1}');
    ok(["migrate-refinement", "3", "received"]);
    assert.deepEqual(fs.readFileSync(path.join(numbered, "refinement/findings.json")), numberedBytes);
    assert.equal(fs.existsSync(numberedLedger), false);
    assert.equal(fs.readFileSync(path.join(numbered, "2_PRDs/notes.md"), "utf8"), "Keep original evidence");
    // Corrupt ledgers fail closed, rather than making gates see zero findings.
    const ledger = path.join(base, "6_qa/findings.json"); const bytes = fs.readFileSync(ledger);
    fs.writeFileSync(ledger, "broken"); assert.notEqual(run(["list", "1", "test"]).status, 0); fs.writeFileSync(ledger, bytes);
    fs.unlinkSync(ledger); fs.symlinkSync(path.join(base, "1_concept/findings.json"), ledger);
    assert.notEqual(run(["list", "1", "test"]).status, 0);
    console.log(`${provider}: stage ledgers, aggregation, concurrency, owner updates, legacy and trust boundaries passed`);
  }
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
