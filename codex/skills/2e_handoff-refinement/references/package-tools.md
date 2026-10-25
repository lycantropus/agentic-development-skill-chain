# Mechanical package checks

Run the installed skill's `scripts/package-tools.mjs` with Node. Commands print
JSON to stdout; save results outside the received copy. They do not classify
requirements, assign ownership, edit state or approve product changes.

- `copy <source-directory> <new-destination>` copies every regular file byte for
  byte, including images, and verifies SHA-256 before/after. It refuses existing
  targets and symlinks; the destination parent must already exist. Partial output after failure is not a valid received copy.
- `inventory <directory>` hashes all files. Output uses relative paths as stable
  source IDs; prefix only the `path` with the run's received directory when placing
  entries in `external-handoff.json`. Preserve IDs in extracted requirement records.
- `ranges <received-directory> <baseline@version> <selections.json>` extracts exact
  inclusive multiline ranges without normalizing CRLF/trailing spaces. Selections
  are `[{"path":"prd.md","sourceId":"AC-12a","startLine":10,"endLine":16}]`.
  Output is ready for `requirements` with empty ownership. Duplicate source/criterion
  identities fail. The lead selects and checks complete ranges against the full
  source; this avoids pretending a regex can infer arbitrary Markdown AC boundaries.
  Include every affected identity in whole-deliverable ownership questions.
- `links <detached-round-directory>` checks inline Markdown links/images, reference
  definitions and HTML href/src paths remain inside the detached round and exist.
  It rejects machine-local paths and symlinks; HTTPS targets are reported separately
  for manual accessibility and immutable-pin verification. Fragment anchors and
  uncommon Markdown syntax need manual review. Use simple supported link syntax in
  generated returns. Copy only the round to a new directory before running this.
- `source-status <source-checkout> <packaged-source-commit>` reports examined HEAD,
  changed paths and working-tree changes without modifying the frozen package.
  Run before recommending a baseline and again after a long review. Inspect changes
  for behavior relevance; source movement is not itself approval or permission to
  replace received ACs. If the source pin cannot be established, report that gap.

The inventory proves preservation of supplied files, not that the supplier included
every promised file. The lead still compares the manifest, prototype promise, complete
source scope and portable return evidence.
