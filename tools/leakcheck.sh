#!/usr/bin/env bash
# Fails if any maintainer-specific string appears where it could be published.
#
# The patterns are personal data themselves, so they never live in this repo: one fixed string per line in
# $SXLAN_LEAK_PATTERNS (default ~/.config/searxng-lan/leak-patterns.txt). Matching is case-insensitive.
# Hits are reported as location and pattern number, never the pattern text.
#
# usage: tools/leakcheck.sh staged|tree|history|all
#        tools/leakcheck.sh dir <path>   # recursive; unpacks tar/txz/tgz archives (release files, image layers)
set -euo pipefail
export LC_ALL=C

patterns="${SXLAN_LEAK_PATTERNS:-$HOME/.config/searxng-lan/leak-patterns.txt}"
[ -s "$patterns" ] || { echo "leakcheck: no patterns at $patterns; refusing to pass" >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
grep -v -e '^[[:space:]]*$' -e '^#' "$patterns" > "$work/pats" || true
[ -s "$work/pats" ] || { echo "leakcheck: pattern file has no patterns; refusing to pass" >&2; exit 2; }
: > "$work/hits"

# stdin: "<location>:<text>" lines that matched at least one pattern; $1: scope label
report() {
  local line n p
  while IFS= read -r line; do
    n=0
    while IFS= read -r p; do
      n=$((n + 1))
      if printf '%s' "$line" | grep -qiF -- "$p"; then
        printf 'LEAK %s: %s (pattern #%d)\n' "$1" "$(printf '%s' "$line" | cut -d: -f1-2)" "$n" | tee -a "$work/hits"
      fi
    done < "$work/pats"
  done
}

scan_staged() {
  local f
  while IFS= read -r -d '' f; do
    git show ":$f" 2>/dev/null | grep -aniF -f "$work/pats" | sed "s|^|$f:|" | report staged || true
    printf 'path:%s\n' "$f" | grep -aiF -f "$work/pats" | report staged-path || true
  done < <(git diff --cached --name-only -z --diff-filter=d)
}
scan_tree() {
  local f
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    grep -aniF -f "$work/pats" -- "$f" | sed "s|^|$f:|" | report tree || true
    printf 'path:%s\n' "$f" | grep -aiF -f "$work/pats" | report tree-path || true
  done < <(git ls-files -co --exclude-standard -z)
}
scan_history() {
  git log --all -p --format='commit %H%nauthor %an <%ae>%ncommitter %cn <%ce>%n%B' 2>/dev/null \
    | grep -aniF -f "$work/pats" | sed 's/^/history:/' | report history || true
  local e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in *@users.noreply.github.com) ;; *) echo "LEAK history: an author/committer email is not a GitHub noreply address" | tee -a "$work/hits" ;; esac
  done < <(git log --all --format='%ae%n%ce' 2>/dev/null | sort -u)
}
unpack_all() { # $1 dir; unpack every archive found, up to 4 levels (txz -> image tar -> layer tar)
  local depth found f
  for depth in 1 2 3 4; do
    found=0
    while IFS= read -r -d '' f; do
      case "$f" in *.x/*) ;; esac
      [ -e "$f.x" ] && continue
      if tar -tf "$f" >/dev/null 2>&1; then
        mkdir -p "$f.x" && { tar -xf "$f" -C "$f.x" 2>/dev/null || true; }
        found=1
      fi
    done < <(find "$1" -type f -size +0 -print0)
    [ "$found" = 1 ] || break
  done
}
scan_dir() {
  cp -R "$1" "$work/d"
  unpack_all "$work/d"
  grep -raniF -f "$work/pats" "$work/d" | sed "s|$work/d/||" | report dir || true
  (cd "$work/d" && find . | grep -aiF -f "$work/pats" | sed 's/^/path:/') | report dir-path || true
}

case "${1:-}" in
  staged) scan_staged ;;
  tree) scan_tree ;;
  history) scan_history ;;
  all) scan_tree; scan_history ;;
  dir) [ -n "${2:-}" ] || { echo "usage: $0 dir <path>" >&2; exit 2; }; scan_dir "$2" ;;
  *) echo "usage: $0 staged|tree|history|all|dir <path>" >&2; exit 2 ;;
esac

hits=$(wc -l < "$work/hits" | tr -d ' ')
if [ "$hits" -gt 0 ]; then echo "leakcheck $1: $hits hit(s)" >&2; exit 1; fi
echo "leakcheck $1: clean ($(wc -l < "$work/pats" | tr -d ' ') patterns)"
