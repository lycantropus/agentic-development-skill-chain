#!/usr/bin/env bash
# curation.sh — the two gates over the curated context (CONCEPT.md §3, §5).
#
#   curation.sh caps [--require-baseline] [repo-root]
#     Hard FORM gate. Caps (deterministic definitions of the §5 limits):
#       docs/PRODUCT.md        <= 30 non-blank lines   ("half page")
#       docs/ARCHITECTURE.md   <= 200 lines
#       docs/DESIGN-SYSTEM.md  <= 80 lines    (injected into every frontend bundle)
#       docs/review-checklist.md <= 80 lines (reviewers / QA, read by path)
#       docs/GUIDELINES.md § Traps <= 10 top-level list entries
#       docs/GUIDELINES.md     <= 120 lines   (injected into every tier-1 bundle)
#       docs/security-baseline.md <= 60 lines (backend / generic bundles)
#       docs/test-conventions.md  <= 60 lines (every tier-1 bundle)
#       src/**/agent.md        <= 100 lines each
#       AGENTS.md (root)       <= 40 non-blank lines   (existing 7_documentation cap)
#     This checks FORM only. TRUTH (stale claims, cap-gaming — shrinking docs by
#     deleting true load-bearing statements) is checked by the cross-review P7
#     pass. Curation must shrink before P7 completes.
#       --require-baseline  missing capped docs are breaches instead of warnings
#                           (used by seal; normal P7 runs on repos without an
#                           intake baseline must not hard-fail)
#     Exit: 0 all caps ok · 1 any breach
#
#   curation.sh seal [repo-root]
#     Seal gate for the 0b_intake bootstrap. The intake may only seal (= commit
#     the initial curation baseline) when:
#       (a) every baseline file exists,
#       (b) NO provenance markers remain — [extracted: ...], [assumed], [gap: ...]
#           are working-draft syntax; every one of them was either resolved in the
#           interview/checkpoint or must still be worked through,
#       (c) the interview + checkpoint reconcile left D-BOOTSTRAP decisions,
#       (d) the file caps hold (caps --require-baseline) — interview output is
#           curated, not dumped.
#     Exit: 0 sealable · 1 not sealable (report on stdout)
set -euo pipefail

usage() { awk 'NR > 1 { if (!/^#/) exit; print }' "${BASH_SOURCE[0]}"; }

caps() (
  REQUIRE_BASELINE=0
  ROOT="."
  for arg in "$@"; do
    case "$arg" in
      --require-baseline) REQUIRE_BASELINE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) ROOT="$arg" ;;
    esac
  done
  cd "$ROOT"

  BREACH=0

  nonblank() { grep -c -v '^[[:space:]]*$' "$1" || true; }
  total()    { wc -l < "$1" | tr -d ' '; }

  check() { # <file> <count> <cap> <unit>
    local file="$1" count="$2" cap="$3" unit="$4"
    if [ "$count" -le "$cap" ]; then
      echo "OK      $file ${count}/${cap} ${unit}"
    else
      echo "BREACH  $file ${count}/${cap} ${unit} — curate: shrink before sealing"
      BREACH=1
    fi
  }

  missing() { # <file>
    if [ "$REQUIRE_BASELINE" -eq 1 ]; then
      echo "BREACH  $1 missing (required baseline file)"
      BREACH=1
    else
      echo "WARN    $1 missing — no baseline yet (not a breach; run 0a/0c for a new build, 0b_intake for an existing codebase)"
    fi
  }

  if [ -f docs/PRODUCT.md ]; then
    check docs/PRODUCT.md "$(nonblank docs/PRODUCT.md)" 30 "non-blank lines"
  else
    missing docs/PRODUCT.md
  fi

  if [ -f docs/ARCHITECTURE.md ]; then
    check docs/ARCHITECTURE.md "$(total docs/ARCHITECTURE.md)" 200 "lines"
  else
    missing docs/ARCHITECTURE.md
  fi

  # Only capped when it exists: projects without a UI never create it, and a
  # missing design system is not a curation breach.
  if [ -f docs/DESIGN-SYSTEM.md ]; then
    check docs/DESIGN-SYSTEM.md "$(total docs/DESIGN-SYSTEM.md)" 80 "lines"
  fi

  if [ -f AGENTS.md ]; then
    check AGENTS.md "$(nonblank AGENTS.md)" 40 "non-blank lines"
  else
    missing AGENTS.md
  fi

  # GUIDELINES, security-baseline and test-conventions go into every tier-1
  # bundle; without a cap their growth surfaces only as a blocked role at P0.
  # Capped only when they exist (backend-only or pre-intake repos lack some).
  [ -f docs/GUIDELINES.md ]        && check docs/GUIDELINES.md        "$(total docs/GUIDELINES.md)"        120 "lines"
  [ -f docs/security-baseline.md ] && check docs/security-baseline.md "$(total docs/security-baseline.md)"  60 "lines"
  [ -f docs/test-conventions.md ]  && check docs/test-conventions.md  "$(total docs/test-conventions.md)"   60 "lines"

  if [ -f docs/review-checklist.md ]; then
    check docs/review-checklist.md "$(total docs/review-checklist.md)" 80 "lines"
  else
    missing docs/review-checklist.md
  fi
  if [ -f docs/GUIDELINES.md ]; then
    # Top-level Markdown bullets or numbered items; continuations/nested bullets
    # are part of the same entry. A top-level marker may be indented 0–3
    # spaces; markers at/after its content column are nested, not new Traps.
    # Stop at the next level-1/2 heading.
    traps="$(awk '
      { sub(/\r$/, "") }
      /^## Traps[[:space:]]*$/ { active=1; have_top=0; next }
      /^##?[[:space:]]/ { active=0 }
      active {
        item=$0; sub(/^ */, "", item)
        indent=length($0)-length(item)
        marker=match(item, /^([-*+]|[0-9]+[.)])[ 	]+/)
        if (marker && indent <= 3 &&
            (!have_top || indent < content_indent)) {
          count++; have_top=1; content_indent=indent+RLENGTH
        } else if (!marker && item ~ /[^[:space:]]/ && indent < content_indent) have_top=0
      }
      END { print count+0 }
    ' docs/GUIDELINES.md)"
    check 'docs/GUIDELINES.md § Traps' "$traps" 10 "entries"
  fi

  if [ -d src ]; then
    while IFS= read -r f; do
      check "$f" "$(total "$f")" 100 "lines"
    done < <(find src -type f -name agent.md | sort)
  fi

  if [ "$BREACH" -eq 0 ]; then
    echo "✓ curation caps ok"
  else
    echo "❌ curation caps BREACHED — P7 must not seal until every file above fits its cap" >&2
  fi
  exit "$BREACH"
)

seal() (
  ROOT="${1:-.}"
  cd "$ROOT"

  FAIL=0

  # Nine baseline files: seven below plus the two UI-only files checked next.
  BASELINE=(
    docs/PRODUCT.md
    docs/ARCHITECTURE.md
    docs/GUIDELINES.md
    docs/review-checklist.md
    docs/security-baseline.md
    docs/test-conventions.md
    AGENTS.md
  )
  for f in "${BASELINE[@]}"; do
    if [ -f "$f" ]; then
      echo "OK      $f exists"
    else
      echo "MISSING $f — the intake must draft every baseline file (a thin file with a pointer beats an absent one)"
      FAIL=1
    fi
  done

  if [ -f docs/review-checklist.md ]; then
    for heading in '## Antipatterns' '## Known Debt'; do
      if ! awk -v heading="$heading" '
        { sub(/\r$/, ""); line=$0; sub(/^ ? ? ?/, "", line) }
        match(line, /^(```+|~~~+)/) {
          marker=substr(line, 1, RLENGTH); tail=substr(line, RLENGTH+1)
          if (!fence) { fence=substr(marker, 1, 1); width=length(marker) }
          else if (substr(marker, 1, 1)==fence && length(marker)>=width && tail ~ /^[[:space:]]*$/) fence=""
          next
        }
        !fence { sub(/[[:space:]]*$/, "", line); if (line==heading) found=1 }
        END { exit !found }
      ' docs/review-checklist.md; then
        echo "MISSING docs/review-checklist.md $heading — required checklist section"
        FAIL=1
      fi
    done
  fi

  # DESIGN-SYSTEM.md and components.md are UI-only baseline files: a backend-only
  # repo never has a component directory and must not be blocked from sealing
  # because of it (mirrors caps' own DESIGN-SYSTEM.md optionality).
  HAS_COMPONENTS=false
  if [ -d src/components ]; then
    HAS_COMPONENTS=true
  elif find src/features -maxdepth 2 -type d -name components 2>/dev/null | grep -q .; then
    HAS_COMPONENTS=true
  fi
  if [ "$HAS_COMPONENTS" = true ]; then
    for f in docs/DESIGN-SYSTEM.md docs/components.md; do
      if [ -f "$f" ]; then
        echo "OK      $f exists"
      else
        echo "MISSING $f — components exist under src/ but $f was not drafted"
        FAIL=1
      fi
    done
  else
    echo "OK      docs/DESIGN-SYSTEM.md, docs/components.md not required — no src/components or src/features/*/components found (backend-only repo)"
  fi

  # (b) residual provenance markers — drafts carry them, the sealed baseline never does
  MARKERS="$(grep -rn -e '\[extracted:' -e '\[assumed\]' -e '\[gap' docs/ AGENTS.md 2>/dev/null || true)"
  if [ -n "$MARKERS" ]; then
    echo "MARKERS residual provenance markers found — resolve them via interview + checkpoint, then strip:"
    echo "$MARKERS" | sed 's/^/          /'
    FAIL=1
  else
    echo "OK      no residual provenance markers"
  fi

  # (c) reconcile evidence — the interview + checkpoint loop must have run;
  # never seal undiscussed drafts as a baseline
  if [ -f specs/intake/decisions.md ] && grep -q 'D-BOOTSTRAP-' specs/intake/decisions.md; then
    echo "OK      specs/intake/decisions.md carries D-BOOTSTRAP reconcile decisions"
  else
    echo "MISSING specs/intake/decisions.md with D-BOOTSTRAP-<NN> entries — no evidence of the interview/checkpoint reconcile"
    FAIL=1
  fi

  # (d) file caps — the FORM gate above, run as its own process so its exit code counts
  if ! bash "${BASH_SOURCE[0]}" caps --require-baseline .; then
    FAIL=1
  fi

  if [ "$FAIL" -eq 0 ]; then
    echo "✓ intake baseline is sealable — commit it: docs: intake baseline — initial curated docs"
  else
    echo "❌ intake baseline NOT sealable — fix the items above first" >&2
  fi
  exit "$FAIL"
)

sub="${1:-}"; [ $# -eq 0 ] || shift
case "$sub" in
  caps | seal) "$sub" "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 64 ;;
esac
