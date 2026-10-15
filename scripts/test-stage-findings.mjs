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
    // Corrupt ledgers fail closed, rather than making gates see zero findings.
    const ledger = path.join(base, "6_qa/findings.json"); const bytes = fs.readFileSync(ledger);
    fs.writeFileSync(ledger, "broken"); assert.notEqual(run(["list", "1", "test"]).status, 0); fs.writeFileSync(ledger, bytes);
    fs.unlinkSync(ledger); fs.symlinkSync(path.join(base, "1_concept/findings.json"), ledger);
    assert.notEqual(run(["list", "1", "test"]).status, 0);
    console.log(`${provider}: stage ledgers, aggregation, concurrency, owner updates, legacy and trust boundaries passed`);
  }
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
