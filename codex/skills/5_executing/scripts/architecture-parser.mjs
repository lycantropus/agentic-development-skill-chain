// Pure architecture reader. Line numbers always refer to the original source.
import { fenceMask } from "./document-parser.mjs";

export const ITEM_SECTIONS = { "Cross-Cutting Tech Decisions": "Decision", "Key Flows": "Flow" };

export function parseArchitecture(text) {
  const lines = text.split(/\r?\n/);
  const fenced = fenceMask(lines);
  const sections = [];
  lines.forEach((line, i) => {
    if (fenced[i]) return;
    if (line.startsWith("## ")) sections.push({ heading: line.slice(3).trim(), line: i + 1, lines: [], positions: [], items: [] });
    else if (sections.length) {
      sections.at(-1).lines.push(line);
      sections.at(-1).positions.push(i + 1);
    }
  });
  return sections;
}

// The compiler's existing local rules, shared with the stricter document gate.
export function validateArchitectureItems(sections, file) {
  const fail = (line, message) => { throw new Error(`${file}:${line}: ${message}`); };
  return sections.map(section => {
    const { heading, lines, positions } = section;
    const kind = Object.entries(ITEM_SECTIONS).find(([h]) => heading.startsWith(h))?.[1];
    if (!kind) return section;
    const items = [];
    lines.forEach((line, i) => {
      if (line.startsWith("### ")) {
        const head = line.match(new RegExp(`^### (${kind} \\d+):\\s*(.*)$`));
        if (!head) fail(positions[i], `'${line}' under ## ${heading} must read '### ${kind} N: <title>'`);
        items.push({ id: head[1], title: head[2].trim(), line: positions[i], fields: {} });
        return;
      }
      const field = line.match(/^\*\*(Affects|Summary|Changes baseline):\*\*\s*(.*)$/);
      if (!field || !items.length) return;
      const key = field[1] === "Changes baseline" ? "baseline" : field[1].toLowerCase();
      const item = items.at(-1);
      if (item[key] !== undefined) fail(positions[i], `${item.id} has two **${field[1]}:** lines`);
      item[key] = field[2].trim();
      item.fields[key] = positions[i];
      if (key === "baseline" && !item[key]) fail(positions[i], `${item.id} **Changes baseline:** must be nonempty`);
    });
    if (!items.length && lines.some(l => l.trim()))
      fail(section.line, `## ${heading} has content but no '### ${kind} N: <title>' items — implementers would get none of it`);
    for (const d of items) {
      if (!d.summary || !d.affects) fail(d.line, `${d.id} needs both an **Affects:** and a **Summary:** line`);
      if (!/\ball\b/i.test(d.affects) && !/(?:PRD-\d+|ENG-US-\d+)/.test(d.affects))
        fail(d.fields.affects, `${d.id} **Affects:** names no PRD-n or ENG-US-n and not 'all' — it would reach no wave`);
    }
    return { ...section, items };
  });
}
