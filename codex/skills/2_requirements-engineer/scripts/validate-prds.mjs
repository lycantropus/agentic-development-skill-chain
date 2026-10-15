#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { fenceMask, parseStories, PRD_FORMAT } from "./document-parser.mjs";

export function validatePrd(text, file) {
  const fail = (line, message) => { throw new Error(`${file}:${line}: ${message}`); };
  const lines = text.split(/\r?\n/), fenced = fenceMask(lines);
  const live = lines.map((line, i) => fenced[i] ? "" : line);
  const titles = live.flatMap((line, i) => /^# /.test(line) ? [{ line: i + 1, text: line }] : []);
  const name = path.basename(file).match(/^PROJ-(.+)-PRD-(\d+)-[^/]+\.md$/);
  const title = titles[0]?.text.match(/^# PROJ-(.+?)[- ]PRD-(\d+)(?=[:\s]|$)/);
  if (!name || titles.length !== 1 || !title || name[1] !== title[1] || name[2] !== title[2])
    fail(titles[0]?.line ?? 1, "filename and single document title must agree on PROJ/PRD ID");
  const sections = [];
  live.forEach((line, i) => {
    const heading = line.match(/^## (.+?)\s*$/);
    if (heading && !PRD_FORMAT.story.test(line)) sections.push({ name: heading[1], line: i + 1, end: live.length });
  });
  sections.forEach((section, i) => { section.end = (sections[i + 1]?.line ?? live.length + 1) - 1; });
  const required = ["Status", "User Stories", "Edge Cases", "Dependencies", "Technical Requirements"];
  for (const name of [...required, "UI Implementation Notes"]) {
    const matches = sections.filter(s => name === "Status" ? /^Status(?::|$)/.test(s.name) : s.name === name);
    if (matches.length > 1 || (required.includes(name) && matches.length !== 1)) fail(matches[1]?.line ?? 1, `need exactly one ## ${name} section`);
    if (!matches.length) continue;
    const section = matches[0];
    const content = name === "Status" ? section.name.slice("Status".length).replace(/^:/, "").trim() : live.slice(section.line, section.end).join("\n").trim();
    if (!content) fail(section.line, `## ${name} must be nonempty`);
  }
  const stories = parseStories(text, PRD_FORMAT), ids = new Set(), acIds = new Set();
  if (!stories.length) fail(1, "at least one user story is required");
  const storySection = sections.find(s => s.name === "User Stories");
  for (const story of stories) {
    if (story.line <= storySection.line || story.line > storySection.end) fail(story.line, `${story.id} must be under ## User Stories`);
    if (ids.has(story.id)) fail(story.line, `duplicate story ID ${story.id}`);
    ids.add(story.id);
    if (!story.heading.slice(story.id.length).replace(/^\s*[:—–-]?\s*/, "").trim()) fail(story.line, `${story.id} needs a title`);
    const end = live.findIndex((line, i) => i >= story.line && /^(#+)\s/.test(line) && line.match(/^(#+)/)[1].length <= story.level);
    const body = live.slice(story.line, end < 0 ? live.length : end);
    for (const field of ["Given", "When", "Then"]) {
      const values = body.filter(line => new RegExp(`^\\*\\*${field}:?\\*\\*`).test(line)).map(line => line.replace(new RegExp(`^\\*\\*${field}:?\\*\\*\\s*:?\\s*`), "").trim());
      if (!values.length || values.some(v => !v)) fail(story.line, `${story.id} needs a nonempty **${field}** field`);
    }
    if (!story.acs.length) fail(story.line, `${story.id} needs its own acceptance criteria`);
    for (const ac of story.acs) {
      if (acIds.has(ac.id)) fail(ac.line, `duplicate AC ID ${ac.id}`);
      acIds.add(ac.id);
      if (!ac.text.trim()) fail(ac.line, `${ac.id} must be nonempty`);
    }
  }
  // parseStories intentionally ignores orphan ACs; check every live AC line as well.
  const owned = new Set(stories.flatMap(story => story.acs.map(ac => ac.line)));
  live.forEach((line, i) => {
    if (PRD_FORMAT.ac.test(line) && !owned.has(i + 1)) fail(i + 1, "acceptance criterion outside a story");
  });
  return { proj: name[1], id: `PROJ-${name[1]}-PRD-${name[2]}` };
}

function main(args) {
  if (args.length !== 1) { console.error("usage: validate-prds.mjs <prd-directory>"); return 64; }
  const directory = args[0];
  let entries;
  try { entries = fs.readdirSync(directory).filter(name => name.endsWith(".md") && !name.endsWith("-review-decisions.md")).sort().map(name => ({ file: path.join(directory, name), text: fs.readFileSync(path.join(directory, name), "utf8") })); }
  catch (error) { console.error(`${directory}:1: cannot read input: ${error.message}`); return 2; }
  try {
    if (!entries.length) throw new Error(`${directory}:1: at least one PRD is required`);
    const ids = new Set(); let proj;
    for (const { file, text } of entries) {
      const prd = validatePrd(text, file);
      if (ids.has(prd.id)) throw new Error(`${file}:1: duplicate PRD ID ${prd.id}`);
      if (proj !== undefined && proj !== prd.proj) throw new Error(`${file}:1: mixed PROJ set`);
      ids.add(prd.id); proj = prd.proj;
    }
    console.log(`PRD structure passed: ${ids.size} PRD(s)`); return 0;
  } catch (error) { console.error(error.message); return 1; }
}
const isMain = () => { try { return fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; } };
if (isMain()) process.exitCode = main(process.argv.slice(2));
