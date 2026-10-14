#!/usr/bin/env node
// Print one story's section of a wave plan verbatim: from its `## <US-ID>`
// heading up to the next `## ` heading (fenced code blocks are skipped).
// Exits 1 when the ID has no section or more than one.
//   node story-slice.mjs <wave-plan.md> <US-ID>
import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

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

function main() {
  const [planPath, id] = process.argv.slice(2);
  if (!planPath || !id) {
    console.error("usage: node story-slice.mjs <wave-plan.md> <US-ID>");
    process.exit(2);
  }
  try {
    process.stdout.write(slice(readFileSync(planPath, "utf8"), id));
  } catch (error) {
    if (error.count === undefined) throw error;
    console.error(`story-slice: ${id} has ${error.count} sections in ${planPath} (need exactly 1)`);
    process.exit(1);
  }
}

// Run the CLI only when started directly (symlink-safe), not when imported.
// argv[1] is no path under `node -e`; an unresolvable one means "imported".
const isMain = () => { try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; } };
if (isMain()) main();
