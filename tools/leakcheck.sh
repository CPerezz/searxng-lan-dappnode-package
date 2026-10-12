#!/usr/bin/env bash
# Fails if any maintainer-specific string appears where it could be published.
#
# The patterns are personal data themselves, so they never live in this repo: one fixed string per line in
# $SXLAN_LEAK_PATTERNS (default ~/.config/searxng-lan/leak-patterns.txt). Matching is case-insensitive.
# Hits are reported as location and pattern number, never the pattern text.
#
# usage: tools/leakcheck.sh staged|tree|history|all
#        tools/leakcheck.sh release <build-dir>   # what this repo puts into a release: metadata files, each image's
#                                                 # config (env, labels, history) and the files our Dockerfiles copy in.
#                                                 # Upstream base layers are not scanned: their contents aren't ours.
set -euo pipefail
export LC_ALL=C

patterns="${SXLAN_LEAK_PATTERNS:-$HOME/.config/searxng-lan/leak-patterns.txt}"
[ -s "$patterns" ] || { echo "leakcheck: no patterns at $patterns; refusing to pass" >&2; exit 2; }
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT   # unpacked image layers contain read-only dirs
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
# Files our Dockerfiles copy into the images (gateway/Dockerfile, searxng/Dockerfile). /usr/bin/caddy is the
# upstream binary with only its file capability stripped, so it isn't ours to scan.
OWN_FILES="etc/caddy/Caddyfile usr/local/bin/gateway-entrypoint usr/local/searxng/searxng-lan-settings.yml usr/local/bin/searxng-lan-entrypoint"
scan_release() {
  local d="$1" f img blob own
  for f in "$d"/*; do
    case "$f" in *.txz|*.tar.xz) continue ;; esac
    grep -aniF -f "$work/pats" -- "$f" | sed "s|^|$(basename "$f"):|" | report release || true
  done
  for f in "$d"/*.txz; do
    img="$work/img" && rm -rf "$img" && mkdir -p "$img"
    xz -dc "$f" | tar -x -C "$img"
    for blob in $(grep -o '"Config":"[^"]*"' "$img/manifest.json" | cut -d'"' -f4); do
      grep -aniF -f "$work/pats" -- "$img/$blob" | sed "s|^|$(basename "$f"):image-config:|" | report release || true
    done
    for blob in $(grep -o '"Layers":\[[^]]*\]' "$img/manifest.json" | grep -o 'blobs/sha256/[0-9a-f]*'); do
      for own in $OWN_FILES; do
        tar -xOf "$img/$blob" "$own" 2>/dev/null | grep -aniF -f "$work/pats" | sed "s|^|$(basename "$f"):/$own:|" | report release || true
      done
    done
    chmod -R u+w "$img" 2>/dev/null; rm -rf "$img"
  done
}

case "${1:-}" in
  staged) scan_staged ;;
  tree) scan_tree ;;
  history) scan_history ;;
  all) scan_tree; scan_history ;;
  release) [ -d "${2:-}" ] || { echo "usage: $0 release <build-dir>" >&2; exit 2; }; scan_release "$2" ;;
  *) echo "usage: $0 staged|tree|history|all|release <build-dir>" >&2; exit 2 ;;
esac

hits=$(wc -l < "$work/hits" | tr -d ' ')
if [ "$hits" -gt 0 ]; then echo "leakcheck $1: $hits hit(s)" >&2; exit 1; fi
echo "leakcheck $1: clean ($(wc -l < "$work/pats" | tr -d ' ') patterns)"
