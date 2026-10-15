#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "document-gates-"));
const prd = `# PROJ-1-PRD-1: Example

## Status: In Progress

## User Stories

### US-1: Save preferences
**Given** a profile
**When** saving
**Then** preferences persist

**Acceptance Criteria:**
- [ ] AC-7: Settings persist.

## Edge Cases
None

## Dependencies
Not applicable

## Technical Requirements
Use the existing API.
`;
const architecture = `# PROJ-1 Architecture — demo

## Overview
Save preferences through the existing service.

## PRDs Covered
- PROJ-1-PRD-1: Profile
- PROJ-1-PRD-2: Other

## Cross-Cutting Tech Decisions
### Decision 4: Reuse the service
**Affects:** PRD-1, PRD-2
**Summary:** Keep the current transaction boundary.
**Changes baseline:** docs/ARCHITECTURE.md § Storage

## Key Flows
### Flow 8: Save
**Affects:** all
**Summary:** Validate before writing.
`;
try {
  for (const provider of ["codex", "claude"]) {
    const skills = path.join(root, provider, "skills");
    const project = path.join(temp, provider); fs.mkdirSync(project);
    assert.equal(spawnSync("git", ["init", "-q", project]).status, 0);
    const installed = path.join(temp, `${provider}-installed`, "skills");
    fs.cpSync(skills, installed, { recursive: true });
    const sync = spawnSync(process.execPath, [path.join(installed, "5_executing/scripts/sync-framework.mjs"), "--target", project], { encoding: "utf8" });
    assert.equal(sync.status, 0, sync.stderr);
    const directory = path.join(project, "2_PRDs"); fs.mkdirSync(directory);
    const file = path.join(directory, "PROJ-1-PRD-1-profile.md");
    const second = path.join(directory, "PROJ-1-PRD-2-other.md");
    const arch = path.join(project, "PROJ-1-architecture.md");
    const reset = () => { fs.writeFileSync(file, prd); fs.writeFileSync(second, prd.replaceAll("PRD-1", "PRD-2")); fs.writeFileSync(arch, architecture); };
    reset();
    fs.writeFileSync(path.join(directory, "PROJ-1-PRD-1-profile-review-decisions.md"), "not a PRD");
    for (const chain of [path.join(skills, "5_executing/scripts/chain"), path.join(installed, "5_executing/scripts/chain"), path.join(project, "scripts/chain")]) {
      const run = (kind, args, status, pattern) => {
        const result = spawnSync("bash", [chain, "check", kind, ...args], { encoding: "utf8" });
        assert.equal(result.status, status, `${kind} ${args}: ${result.stderr}`);
        if (pattern) assert.match(result.stderr, pattern);
        if (status === 1) assert.match(result.stderr, /:\d+: /, "document errors must name a source line");
        return result;
      };
      run("prds", [directory], 0); run("architecture", [arch, directory], 0);
      for (const kind of ["prds", "architecture"]) {
        run(kind, [], 64); run(kind, [directory, arch, "extra"], 64);
        run(kind, kind === "prds" ? [path.join(temp, "absent")] : [path.join(temp, "absent"), directory], 2, /:1: cannot read input/);
      }
      const prdCases = [
        [prd.replace("## Dependencies\nNot applicable", ""), /Dependencies/],
        [prd.replace("## Status: In Progress", "## Status:"), /Status.*nonempty/],
        [prd.replace("## Edge Cases\nNone", "## Edge Cases\n"), /Edge Cases.*nonempty/],
        [prd.replace("**Given** a profile", "**Given**"), /Given/],
        [prd.replace("**When** saving", ""), /When/],
        [prd.replace("**Then** preferences persist", "**Then** "), /Then/],
        [prd.replace("### US-1: Save preferences", "### US-1:"), /title/],
        [prd.replace("- [ ] AC-7: Settings persist.", ""), /own acceptance/],
        [prd.replace("AC-7: Settings persist.", "AC-7: "), /AC-7.*nonempty/],
        [prd.replace("## Edge Cases", "### US-1: Again\n**Given** x\n**When** y\n**Then** z\n- [ ] AC-9: z\n\n## Edge Cases"), /duplicate story/],
        [prd.replace("## Edge Cases", "### US-2: Again\n**Given** x\n**When** y\n**Then** z\n- [ ] AC-7: z\n\n## Edge Cases"), /duplicate AC/],
        [prd + "\n- [ ] AC-8: Orphan\n", /outside a story/],
        [prd.replace("PRD-1:", "PRD-3:"), /filename.*title/],
        [prd + "\n## UI Implementation Notes\n", /UI Implementation Notes.*nonempty/],
        [prd + "\n## UI Implementation Notes\nx\n## UI Implementation Notes\ny\n", /exactly one.*UI/],
        [prd + "\n## Dependencies\nNone\n", /exactly one.*Dependencies/],
      ];
      for (const [text, pattern] of prdCases) { fs.writeFileSync(file, text); run("prds", [directory], 1, pattern); }
      reset();
      for (const text of [prd.replace("# PROJ-1-PRD-1:", "# PROJ-1 PRD-1:"), prd.replace("### US-1:", "## US-1 —"), prd.replaceAll("\n", "\r\n"), prd + "\n## UI Implementation Notes\nUse screen A.\n", prd + "\n````md\n## Dependencies\n- [ ] AC-7: example\n```\n### US-99: example\n````\n"]) {
        fs.writeFileSync(file, text); run("prds", [directory], 0);
      }
      reset();
      const duplicate = path.join(directory, "PROJ-1-PRD-1-copy.md"); fs.writeFileSync(duplicate, prd);
      run("prds", [directory], 1, /duplicate PRD/); fs.unlinkSync(duplicate);
      const foreign = path.join(directory, "PROJ-2-PRD-1-copy.md"); fs.writeFileSync(foreign, prd.replaceAll("PROJ-1", "PROJ-2"));
      run("prds", [directory], 1, /mixed PROJ/); fs.unlinkSync(foreign);
      const empty = path.join(project, "empty"); fs.mkdirSync(empty, { recursive: true }); run("prds", [empty], 1, /at least one PRD/);
      const archCases = [
        [architecture.replace("## Overview", "## Other"), /Overview/],
        [architecture.replace("PROJ-1 Architecture", "PROJ-2 Architecture"), /filename.*title/],
        [architecture.replace("- PROJ-1-PRD-2: Other", ""), /PRDs Covered/],
        [architecture.replace("- PROJ-1-PRD-2: Other", "- PROJ-1-PRD-1: Other"), /PRDs Covered/],
        [architecture.replace("PROJ-1-PRD-2: Other", "PROJ-9-PRD-2: Other"), /PRDs Covered/],
        [architecture.replace("**Affects:** PRD-1, PRD-2", "**Affects:** PRD-9"), /unknown PRD-9/],
        [architecture.replace("**Affects:** PRD-1, PRD-2", "**Affects:** PRD-1, all"), /all alone/],
        [architecture.replace("**Affects:** PRD-1, PRD-2", "**Affects:** PROJ-9-PRD-1"), /all alone/],
        [architecture.replace("### Decision 4:", "### Decision four:"), /must read/],
        [architecture.replace("### Decision 4: Reuse the service", "### Decision 4:"), /title/],
        [architecture.replace("**Summary:** Keep the current transaction boundary.", ""), /needs both/],
        [architecture.replace("**Summary:** Keep the current transaction boundary.", "**Summary:** Keep it.\n**Summary:** Again."), /two.*Summary/],
        [architecture.replace("**Changes baseline:** docs/ARCHITECTURE.md § Storage", "**Changes baseline:**"), /baseline.*nonempty/],
        [architecture + "\n## Overview\nAgain\n", /exactly one.*Overview/],
        [architecture + "\n## Data Model\nx\n## Data Model\ny\n", /exactly one.*Data Model/],
        [architecture + "\n### Flow 8: Again\n**Affects:** all\n**Summary:** Again.\n", /duplicate Flow/],
        [architecture.replace("## Key Flows", "### Decision 4: Again\n**Affects:** all\n**Summary:** Again.\n\n## Key Flows"), /duplicate Decision/],
        [architecture.replace("### Flow 8: Save\n**Affects:** all\n**Summary:** Validate before writing.", "Text without items."), /no.*items/],
      ];
      for (const [text, pattern] of archCases) { fs.writeFileSync(arch, text); run("architecture", [arch, directory], 1, pattern); }
      for (const text of [architecture.replace(/\n## Key Flows[\s\S]*/, "\n"), architecture.replaceAll("\n", "\r\n"), architecture + "\n````mermaid\n## Overview\n### Flow 8: fake\n```\n**Summary:** fake\n````\n"]) {
        fs.writeFileSync(arch, text); run("architecture", [arch, directory], 0);
      }
      reset();
      // Historical commands keep their distinct invocation/parse exit codes.
      for (const [args, status] of [[["check", "plan"], 2], [["check", "plan", "--stories"], 64], [["check", "plan", "--stories", arch], 2], [["render", "slice"], 2], [["render", "slice", arch, "US-404"], 1], [["render", "context"], 64], [["render", "context", "check", "missing", "demo"], 2]]) {
        const result = spawnSync("bash", [chain, ...args], { cwd: project, encoding: "utf8" }); assert.equal(result.status, status, result.stderr);
      }
    }
    // Pure modules expose only readers: no filesystem, process, child process or CLI side effects.
    for (const relative of ["4_writing-plans/scripts/document-parser.mjs", "3_architecture/scripts/architecture-parser.mjs"]) {
      const source = fs.readFileSync(path.join(skills, relative), "utf8");
      assert.doesNotMatch(source, /node:(?:fs|child_process)|process\.|console\./);
      const module = await import(pathToFileURL(path.join(skills, relative)));
      assert.ok(Object.values(module).some(value => typeof value === "function"));
    }
    console.log(`${provider}: document validation, exit codes, pure imports and all distribution layouts passed`);
  }
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
