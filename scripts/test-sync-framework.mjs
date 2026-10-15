#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import { createHash } from "node:crypto";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "helper-sync-"));
try {
  for (const provider of ["codex", "claude"]) {
    const skills = path.join(temp, provider, "skills");
    fs.cpSync(path.join(root, provider, "skills"), skills, { recursive: true });
    const target = path.join(temp, `${provider}-project`);
    fs.mkdirSync(target);
    assert.equal(spawnSync("git", ["init", "-q", target]).status, 0);
    const script = path.join(skills, "5_executing/scripts/sync-framework.mjs");
    const run = (...args) => spawnSync(process.execPath, [script, "--target", target, ...args], { encoding: "utf8" });
    const ok = (...args) => { const result = run(...args); assert.equal(result.status, 0, result.stderr); return result; };
    const bad = (pattern, ...args) => { const result = run(...args); assert.equal(result.status, 1); assert.match(result.stderr, pattern); };
    const manifest = path.join(target, ".skillchain-helpers.json");
    bad(/refresh required/, "--check");
    assert.equal(fs.existsSync(manifest), false);
    ok(); ok("--check");
    const permissionFile = path.join(target, "scripts/state.sh");
    const permissionSource = path.join(skills, "5_executing/scripts/state.sh");
    const permissionMode = fs.statSync(permissionSource).mode & 0o777;
    fs.chmodSync(permissionFile, permissionMode ^ 0o032);
    ok("--check");
    assert.equal(fs.statSync(permissionFile).mode & 0o777, permissionMode ^ 0o032, "check must not normalize non-executable permission bits");
    fs.chmodSync(permissionFile, permissionMode ^ 0o011);
    ok("--check");
    assert.equal(fs.statSync(permissionFile).mode & 0o777, permissionMode ^ 0o011, "group/other-only execute drift must remain current");
    fs.chmodSync(permissionFile, permissionMode ^ 0o100);
    bad(/refresh required/, "--check");
    ok(); ok("--check");
    assert.equal(fs.statSync(permissionFile).mode & 0o777, permissionMode, "owner-execute drift must refresh the installed mode");
    const copied = path.join(target, "scripts/sync-framework.mjs");
    assert.equal(spawnSync(process.execPath, [copied, "--target", target], { encoding: "utf8" }).status, 1);
    assert.equal(spawnSync(process.execPath, [copied, "--target", target, "--skills-root", skills], { encoding: "utf8" }).status, 0);
    const lock = path.join(target, ".git/skillchain-helper-sync.lock");
    fs.mkdirSync(lock); bad(/already locked/); assert.equal(fs.existsSync(lock), true); fs.rmdirSync(lock);
    const before = fs.readFileSync(manifest, "utf8");
    ok(); assert.equal(fs.readFileSync(manifest, "utf8"), before, "idempotent manifest");
    // Manifests from before CP1/P0 moved into 5_executing must upgrade, not conflict.
    const legacy = JSON.parse(before);
    legacy.files["scripts/state.sh"].source = "4b_setup/scripts/state.sh";
    legacy.files["templates/decisions.md.tmpl"].source = "4a_checkpoint/templates/decisions.md.tmpl";
    fs.writeFileSync(manifest, JSON.stringify(legacy, null, 2) + "\n");
    const stateSource = path.join(skills, "5_executing/scripts/state.sh");
    const stateOriginal = fs.readFileSync(stateSource);
    fs.appendFileSync(stateSource, "\n# upstream after the move\n");
    ok(); assert.equal(fs.readFileSync(path.join(target, "scripts/state.sh"), "utf8"), fs.readFileSync(stateSource, "utf8"));
    assert.equal(JSON.parse(fs.readFileSync(manifest, "utf8")).files["scripts/state.sh"].source, "5_executing/scripts/state.sh");
    fs.writeFileSync(stateSource, stateOriginal); ok();
    assert.equal(fs.readFileSync(manifest, "utf8"), before, "legacy manifest migrated");
    const source = path.join(skills, "5_executing/scripts/wave-gate.sh");
    const local = path.join(target, "scripts/wave-gate.sh");
    fs.appendFileSync(source, "\n# upstream v2\n");
    bad(/refresh required/, "--check");
    ok(); assert.equal(fs.readFileSync(local, "utf8"), fs.readFileSync(source, "utf8"));
    fs.appendFileSync(local, "\n# project adaptation\n");
    const adapted = fs.readFileSync(local, "utf8");
    fs.appendFileSync(path.join(skills, "5_executing/scripts/state.sh"), "\n# new helper\n");
    const untouched = fs.readFileSync(path.join(target, "scripts/state.sh"), "utf8");
    bad(/no files changed/);
    assert.equal(fs.readFileSync(path.join(target, "scripts/state.sh"), "utf8"), untouched, "conflict must prevent partial updates");
    ok("--adopt", "scripts/wave-gate.sh"); ok("--check");
    assert.equal(fs.readFileSync(local, "utf8"), adapted);
    fs.appendFileSync(source, "\n# upstream v3\n");
    bad(/upstream changed/); assert.equal(fs.readFileSync(local, "utf8"), adapted);
    fs.writeFileSync(local, fs.readFileSync(source, "utf8") + "\n# project adaptation\n");
    ok("--adopt", "scripts/wave-gate.sh"); ok("--check");
    // Upgrade the retired monolith only with known, unchanged upstream bytes.
    const digest = text => createHash("sha256").update(text).digest("hex");
    const oldPath = path.join(target, "scripts/plan.mjs");
    const backup = oldPath + ".pre-split";
    const oldBytes = "// previously synchronized monolithic helper\n";
    const stable = fs.readFileSync(manifest, "utf8");
    const installOld = (bytes = oldBytes, entry = { source: "5_executing/scripts/plan.mjs", source_hash: digest(oldBytes), local_hash: digest(oldBytes) }) => {
      fs.writeFileSync(oldPath, bytes);
      const value = JSON.parse(stable);
      for (const name of ["validate-prds", "validate-architecture", "validate-wave-plan", "compile-context", "story-slice", "document-parser", "architecture-parser"]) {
        const relative = `scripts/${name}.mjs`;
        delete value.files[relative];
        fs.rmSync(path.join(target, relative), { force: true });
      }
      if (entry) value.files["scripts/plan.mjs"] = entry;
      fs.writeFileSync(manifest, JSON.stringify(value, null, 2) + "\n");
    };
    const snapshot = () => {
      const files = fs.readdirSync(target, { recursive: true }).filter(name => !name.startsWith(".git") && fs.lstatSync(path.join(target, name)).isFile());
      return files.sort().map(name => [name, digest(fs.readFileSync(path.join(target, name)))]);
    };
    const unchangedAfterFailure = (pattern, ...args) => {
      const before = snapshot(); bad(pattern, ...args); assert.deepEqual(snapshot(), before, "blocked upgrade must write nothing");
    };
    installOld();
    unchangedAfterFailure(/refresh required/, "--check");
    ok(); assert.equal(fs.existsSync(oldPath), false); assert.equal(fs.readFileSync(backup, "utf8"), oldBytes);
    ok(); ok("--check"); assert.equal(fs.readFileSync(backup, "utf8"), oldBytes);
    fs.unlinkSync(backup);
    for (const entry of [
      { source: "5_executing/scripts/plan.mjs", source_hash: digest(oldBytes), local_hash: digest(oldBytes) },
      { source: "5_executing/scripts/plan.mjs", source_hash: digest(oldBytes), local_hash: digest(oldBytes + "// adaptation\n") },
      null,
    ]) {
      const edited = oldBytes + "// adaptation\n";
      installOld(edited, entry);
      unchangedAfterFailure(/modified or unknown provenance/);
      unchangedAfterFailure(/modified or unknown provenance/, "--check");
      bad(/not a managed path/, "--adopt", "scripts/plan.mjs");
      // Complete the documented manual path, retaining the original adaptation.
      fs.renameSync(oldPath, backup); ok();
      const newPath = path.join(target, "scripts/validate-wave-plan.mjs");
      fs.appendFileSync(newPath, "\n// adaptation\n");
      ok("--adopt", "scripts/validate-wave-plan.mjs"); ok("--check");
      assert.ok(fs.readFileSync(newPath, "utf8").endsWith("// adaptation\n"));
      assert.equal(fs.readFileSync(backup, "utf8"), edited);
      fs.unlinkSync(backup);
      fs.copyFileSync(path.join(skills, "4_writing-plans/scripts/validate-wave-plan.mjs"), newPath);
      ok();
    }
    installOld(); fs.writeFileSync(backup, "existing backup");
    unchangedAfterFailure(/backup.*already exists/); unchangedAfterFailure(/backup.*already exists/, "--check"); fs.unlinkSync(backup);
    fs.symlinkSync(source, backup); bad(/symlink/); fs.unlinkSync(backup);
    fs.unlinkSync(oldPath); fs.symlinkSync(source, oldPath); bad(/symlink/); fs.unlinkSync(oldPath);
    // A separate inventory conflict must prevent the rename as well.
    installOld();
    fs.appendFileSync(path.join(target, "scripts/state.sh"), "\n# local edit\n");
    unchangedAfterFailure(/no files changed/); assert.equal(fs.existsSync(backup), false);
    fs.copyFileSync(path.join(skills, "5_executing/scripts/state.sh"), path.join(target, "scripts/state.sh"));
    ok(); fs.unlinkSync(backup);
    // Names from before consolidation are unknown copies, never silently adopted.
    installOld();
    const prior = JSON.parse(fs.readFileSync(manifest, "utf8"));
    for (const name of ["validate-wave-plan.mjs", "story-slice.mjs"]) {
      delete prior.files[`scripts/${name}`];
      fs.writeFileSync(path.join(target, "scripts", name), `// older ${name} with adaptation\n`);
    }
    fs.writeFileSync(manifest, JSON.stringify(prior, null, 2) + "\n");
    unchangedAfterFailure(/back them up under other names/); unchangedAfterFailure(/back them up under other names/, "--check");
    for (const name of ["validate-wave-plan.mjs", "story-slice.mjs"]) fs.renameSync(path.join(target, "scripts", name), path.join(target, "scripts", name + ".old"));
    ok();
    for (const name of ["validate-wave-plan.mjs", "story-slice.mjs"]) {
      const file = path.join(target, "scripts", name);
      fs.appendFileSync(file, "\n// adaptation from older helper\n");
      ok("--adopt", `scripts/${name}`);
      assert.match(fs.readFileSync(file + ".old", "utf8"), /with adaptation/);
    }
    ok("--check"); assert.equal(fs.readFileSync(backup, "utf8"), oldBytes);
    fs.unlinkSync(backup);
    for (const [name, owner] of [["validate-wave-plan.mjs", "4_writing-plans"], ["story-slice.mjs", "5_executing"]]) fs.copyFileSync(path.join(skills, owner, "scripts", name), path.join(target, "scripts", name));
    ok();
    bad(/not a managed path/, "--adopt", "../outside");
    bad(/cannot adopt/, "--check", "--adopt", "scripts/wave-gate.sh");
    fs.unlinkSync(manifest);
    bad(/untracked or modified/); assert.equal(fs.existsSync(manifest), false, "legacy custom helpers need review");
    ok("--adopt", "scripts/wave-gate.sh");
    fs.unlinkSync(local); fs.symlinkSync(source, local);
    bad(/symlink/); fs.unlinkSync(local); ok();
    fs.chmodSync(local, 0o600); ok();
    assert.equal(fs.statSync(local).mode & 0o777, fs.statSync(source).mode & 0o777);
    fs.unlinkSync(manifest); fs.symlinkSync(path.join(temp, "external-manifest"), manifest);
    bad(/symlink/); fs.unlinkSync(manifest);
    const templates = path.join(target, "templates");
    fs.renameSync(templates, templates + "-real"); fs.symlinkSync(templates + "-real", templates);
    bad(/symlink/); fs.unlinkSync(templates); fs.renameSync(templates + "-real", templates);
    fs.unlinkSync(path.join(skills, "5_executing/scripts/state.sh"));
    bad(/ENOENT/); assert.equal(fs.existsSync(manifest), false);
    console.log(`${provider}: helper synchronization, upgrades, adaptation conflicts, adoption and path protection passed`);
  }
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
