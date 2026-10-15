#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { fenceMask } from "./document-parser.mjs";
import { parseArchitecture, validateArchitectureItems } from "./architecture-parser.mjs";

export function validateArchitecture(text, file, prds) {
  const fail = (line, message) => { throw new Error(`${file}:${line}: ${message}`); };
  const lines = text.split(/\r?\n/), fenced = fenceMask(lines);
  const live = lines.map((line, i) => fenced[i] ? "" : line);
  const titles = live.flatMap((line, i) => /^# /.test(line) ? [{ text: line, line: i + 1 }] : []);
  const proj = path.basename(file).match(/^PROJ-(.+)-architecture\.md$/)?.[1];
  const declared = titles[0]?.text.match(/^# PROJ-(.+) Architecture(?:\s|$)/)?.[1];
  if (!proj || titles.length !== 1 || declared !== proj)
    fail(titles[0]?.line ?? 1, "filename and single architecture title must agree on PROJ ID");
  if (!prds.length || prds.some(id => !id.startsWith(`PROJ-${proj}-PRD-`)) || new Set(prds).size !== prds.length) fail(1, "PRD set must be nonempty, unique and belong to this PROJ");
  const sections = validateArchitectureItems(parseArchitecture(text), file);
  const required = ["Overview", "PRDs Covered", "Cross-Cutting Tech Decisions"];
  const optional = ["System Boundaries", "Data Model", "Key Flows", "UI Implementation Constraints", "Cross-PROJ Dependencies", "Dependencies"];
  for (const name of [...required, ...optional]) {
    const matches = sections.filter(s => s.heading === name);
    if (matches.length > 1 || (required.includes(name) && matches.length !== 1)) fail(matches[1]?.line ?? 1, `need exactly one ## ${name} section`);
    if (required.includes(name) && !matches[0].lines.join("\n").trim()) fail(matches[0].line, `## ${name} must be nonempty`);
  }
  const coverage = sections.find(s => s.heading === "PRDs Covered");
  const covered = [...coverage.lines.join("\n").matchAll(/PROJ-[A-Za-z0-9-]+-PRD-\d+(?![\w-])/g)].map(m => m[0]);
  if ([...coverage.lines.join("\n").matchAll(/PRD-\d+/g)].length !== covered.length || covered.length !== prds.length || new Set(covered).size !== covered.length || covered.some(id => !prds.includes(id))) fail(coverage.line, "PRDs Covered must list every input PRD exactly once, using full local PROJ-X-PRD-Y IDs");
  const ids = new Set();
  for (const section of sections) for (const item of section.items) {
    if (ids.has(item.id)) fail(item.line, `duplicate ${item.id}`);
    ids.add(item.id);
    if (!item.title) fail(item.line, `${item.id} needs a title`);
    if (item.affects === "all") continue;
    if (!/^PRD-\d+(?:\s*,\s*PRD-\d+)*$/.test(item.affects)) fail(item.fields.affects, `${item.id} Affects must be PRD-Y IDs separated by commas, or all alone`);
    for (const id of item.affects.split(/\s*,\s*/)) if (!prds.includes(`PROJ-${proj}-${id}`)) fail(item.fields.affects, `${item.id} Affects references unknown ${id}`);
  }
}

function main(args) {
  if (args.length !== 2) { console.error("usage: validate-architecture.mjs <architecture-file> <prd-directory>"); return 64; }
  const [file, directory] = args; let text, entries;
  try {
    text = fs.readFileSync(file, "utf8");
    entries = fs.readdirSync(directory).filter(name => name.endsWith(".md") && !name.endsWith("-review-decisions.md")).map(name => ({ name, text: fs.readFileSync(path.join(directory, name), "utf8") }));
  } catch (error) { console.error(`${file}:1: cannot read input: ${error.message}`); return 2; }
  try {
    const prds = entries.map(entry => {
      const id = entry.name.match(/^(PROJ-.+-PRD-\d+)-.+\.md$/)?.[1];
      const title = entry.text.split(/\r?\n/); const fenced = fenceMask(title);
      const declared = title.find((line, i) => !fenced[i] && /^# /.test(line))?.match(/^# (PROJ-.+?)[- ](PRD-\d+)(?=[:\s]|$)/);
      if (!id || `${declared?.[1]}-${declared?.[2]}` !== id) throw new Error(`${path.join(directory, entry.name)}:1: filename and PRD title must agree`);
      return id;
    });
    validateArchitecture(text, file, prds);
    console.log("Architecture structure passed"); return 0;
  } catch (error) { console.error(error.message); return 1; }
}
const isMain = () => { try { return fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; } };
if (isMain()) process.exitCode = main(process.argv.slice(2));
