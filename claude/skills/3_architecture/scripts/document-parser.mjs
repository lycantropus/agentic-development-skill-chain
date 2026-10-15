// Pure document readers; importing this module performs no I/O.
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

const clean = (value) => value.trim().replace(/^`|`$/g, "");
export function fenceMask(lines) {
  let fence = null;
  return lines.map((line) => {
    const [, indent, marker, info] = line.match(/^( {0,3})(`{3,}|~{3,})(.*)$/) ?? [];
    if (marker && !fence) { fence = { marker, indent: indent.length }; return fence; }
    if (marker && marker[0] === fence?.marker[0] && marker.length >= fence.marker.length && !info.trim()) { const closed = fence; fence = null; return closed; }
    return fence ?? false;
  });
}

const cells = (line) => line.trim().replace(/^\||\|$/g, "").split("|").map((cell) => cell.trim());

// Rows of the `## User Stories in this Wave` table with raw (trimmed) cells, or null
// without such a table. Columns resolve by header name; a missing column is undefined.
// The lower-cased header names are on the (non-enumerable) `columns` property.
export function parseStoryTable(text) {
  const lines = text.split(/\r?\n/);
  const fenced = fenceMask(lines);
  const live = (i) => !fenced[i];
  const heading = lines.findIndex((line, i) => live(i) && /^## User Stories in this Wave\s*$/.test(line));
  if (heading < 0) return null;
  let head = heading + 1;
  while (head < lines.length && !(live(head) && /^(\||## )/.test(lines[head]))) head++;
  if (!lines[head]?.startsWith("|") || !live(head + 1) || !/^\|?[\s:|-]*-[\s:|-]*$/.test(lines[head + 1] ?? "")) return null;
  const names = cells(lines[head]).map((name) => name.toLowerCase().replace(/\s+/g, " "));
  const column = (name) => names.indexOf(name);
  const col = { id: column("us id"), scope: column("scope"), agentType: column("agent type"), complexity: column("complexity"), canStart: column("can start when") };
  const rows = Object.defineProperty([], "columns", { value: names });
  for (let i = head + 2; i < lines.length && live(i) && lines[i].startsWith("|"); i++) {
    const row = cells(lines[i]);
    const pick = (index) => (index < 0 ? undefined : row[index]);
    rows.push({ id: pick(col.id), scope: pick(col.scope), agentType: pick(col.agentType), complexity: pick(col.complexity), canStart: pick(col.canStart), line: i + 1 });
  }
  return rows;
}

const PLAN_FORMAT = {
  story: /^## (PROJ-[A-Za-z0-9-]+-PRD-\d+-US-\d+)(?::|\s|$)/,
  ac: /^- \[.\] ([A-Za-z0-9][A-Za-z0-9._-]*AC-[A-Za-z0-9._-]+):\s*(.*)$/,
};
// PRDs (2_requirements-engineer template): `### US-<Z>: …` (or `## US-<Z> — …`), `- [ ] AC-<N>: …`.
export const PRD_FORMAT = {
  story: /^#+ (US-\d+)(?!\d)/,
  ac: /^- \[.\] (AC-[A-Za-z0-9._-]+):\s*(.*)$/,
};

// Story sections (default: `## PROJ-<X>-PRD-<Y>-US-<Z>`) with Scope/Agent, Split and ACs, raw and in
// file order. A section ends at the next heading of the same or a higher level; an AC runs until the
// next AC line, heading, `**Label:**` line, `---` rule or unindented code fence. A fence indented by
// two or more spaces belongs to the list item and stays part of the AC text.
export function parseStories(text, format = PLAN_FORMAT) {
  const lines = text.split(/\r?\n/);
  const fenced = fenceMask(lines);
  const stories = [];
  let story = null, ac = null;
  const closeAc = () => {
    if (ac) ac.text = ac.text.replace(/\n+$/, "");
    ac = null;
  };
  lines.forEach((line, i) => {
    if (fenced[i]) {
      if (ac && fenced[i].indent >= 2) ac.text += `\n${line.replace(/\s+$/, "")}`;
      else closeAc();
      return;
    }
    const level = line.match(/^(#+)\s/)?.[1].length;
    const id = level && line.match(format.story)?.[1];
    if (id || (story && level <= story.level)) {
      closeAc();
      story = id ? { id, heading: line.replace(/^#+\s*/, "").trim(), line: i + 1, level, scope: null, agent: null, split: null, acs: [] } : null;
      if (story) stories.push(story);
      return;
    }
    if (!story) return;
    const acMatch = line.match(format.ac);
    if (acMatch) {
      closeAc();
      ac = { id: acMatch[1], text: acMatch[2].replace(/\s+$/, ""), line: i + 1 };
      story.acs.push(ac);
      return;
    }
    const boundary = /^#|^\*\*[^*]+:\*\*|^---+\s*$/.test(line);
    if (boundary) closeAc();
    const scope = line.match(/^\*\*Scope:\*\*\s*(.*)$/);
    if (scope && story.scope === null) {
      const [name, ...agent] = scope[1].split(/→|->/);
      story.scope = name.trim();
      story.agent = agent.length ? agent.join("→").trim() : null;
    }
    const split = line.match(/^\*\*Split:\*\*\s*`?([^\s+`]+)/);
    if (split && story.split === null) story.split = split[1];
    if (ac && !boundary) ac.text += `\n${line.replace(/\s+$/, "")}`;
  });
  closeAc();
  return stories;
}

const ROLES = ["implementer", "frontend-implementer", "backend-implementer"];
const ROLE_ALIASES = { "fullstack-implementer": "implementer", "full-stack-implementer": "implementer" };
const SIMPLE_SCOPES = ["frontend", "backend", "full-stack"];
const SPLITS = ["none", "contract", "fan-out"];
const normalizeRole = (value) => {
  const role = clean(value).replace(/^skillchain-/, "");
  return ROLE_ALIASES[role] ?? role;
};

// One record per story of a wave plan: the worker role comes from the table's
// `Agent Type` column (normalized), checked fail-closed against the story
// sections. A plan without that column (legacy) maps every story to
// `implementer` with `fallback: true`. Throws an Error naming story and plan.
export function resolveStories(text, planFile) {
  const fail = (id, message) => { throw new Error(`${planFile}: ${id}: ${message}`); };
  const stories = parseStories(text);
  const sections = new Map();
  for (const story of stories) {
    if (sections.has(story.id)) fail(story.id, `duplicate story section (lines ${sections.get(story.id).line} and ${story.line})`);
    sections.set(story.id, story);
  }
  const splitOf = (story) => {
    const split = story.split === null ? "none" : clean(story.split).toLowerCase();
    if (!SPLITS.includes(split)) fail(story.id, `unsupported **Split:** '${story.split}' (expected ${SPLITS.join("|")})`);
    return split;
  };
  const rows = parseStoryTable(text);
  if (!rows?.columns.includes("agent type")) {
    if (stories.length === 0) fail("-", "no story table with an Agent Type column and no story section");
    return stories.map((story) => {
      const row = rows?.find((entry) => clean(entry.id ?? "") === story.id);
      return { id: story.id, scope: story.scope, role: "implementer", agentType: null, complexity: row?.complexity ?? null, canStart: row?.canStart ?? null, split: splitOf(story), fallback: true };
    });
  }
  const resolved = new Map();
  for (const row of rows) {
    const id = clean(row.id ?? "");
    if (resolved.has(id)) fail(id, `duplicate row in the story table (line ${row.line})`);
    const section = sections.get(id);
    if (!section) fail(id, `story table row (line ${row.line}) has no story section`);
    const role = normalizeRole(row.agentType ?? "");
    if (!ROLES.includes(role)) fail(id, `unsupported Agent Type '${row.agentType ?? "(missing cell)"}' (one of ${ROLES.join(", ")}, optional skillchain- prefix)`);
    // Only the first token after the arrow is the agent; trailing prose
    // ("→ implementer. Backend scope shipped in Wave 2.") is not compared.
    const sectionRole = section.agent === null ? null : normalizeRole(section.agent.split(/[\s.(,;]/)[0]);
    if (ROLES.includes(sectionRole) && sectionRole !== role)
      fail(id, `Agent Type '${row.agentType}' contradicts the section's **Scope:** agent '${section.agent}'`);
    const tableScope = clean(row.scope ?? "").toLowerCase();
    const sectionScope = (section.scope ?? "").toLowerCase();
    if (SIMPLE_SCOPES.includes(tableScope) && SIMPLE_SCOPES.includes(sectionScope) && tableScope !== sectionScope)
      fail(id, `table Scope '${tableScope}' contradicts the section's **Scope:** '${sectionScope}'`);
    const split = splitOf(section);
    if (split === "contract" && [tableScope, sectionScope].some((scope) => scope === "frontend" || scope === "backend"))
      fail(id, `Split: contract contradicts the single-sided Scope '${[tableScope, sectionScope].find((scope) => scope === "frontend" || scope === "backend")}'`);
    resolved.set(id, { id, scope: clean(row.scope ?? "") || section.scope, role, agentType: clean(row.agentType), complexity: row.complexity ?? null, canStart: row.canStart ?? null, split });
  }
  for (const story of stories) if (!resolved.has(story.id)) fail(story.id, "story section has no row in the story table");
  return stories.map((story) => resolved.get(story.id));
}
