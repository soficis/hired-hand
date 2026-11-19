#!/usr/bin/env bash
# Fail if any file that would be published matches a private pattern or contains non-ASCII bytes.
# Patterns come from $SCRUB_PATTERNS; the default is the public list.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pat="${SCRUB_PATTERNS:-tools/ci-scrub-patterns.txt}"
[[ -f "$pat" ]] || { echo "scrub-check: pattern file $pat not found" >&2; exit 2; }
mapfile -t files < <(git ls-files --cached --others --exclude-standard | grep -v '^tools/scrub-check\.sh$')
((${#files[@]})) || { echo "scrub-check: no files"; exit 0; }
rc=0
while IFS= read -r p || [[ -n "$p" ]]; do
  p="${p%$'\r'}"; [[ -z "$p" || "$p" == \#* ]] && continue
  if hits="$(grep -n -i -E -- "$p" "${files[@]}" 2>/dev/null)"; then
    echo "scrub-check: pattern [$p]:"; printf '%s\n' "$hits" | head -20; rc=1
  fi
done < "$pat"
if hits="$(LC_ALL=C grep -n -P '[^\x00-\x7F]' "${files[@]}" 2>/dev/null)"; then
  echo "scrub-check: non-ASCII bytes:"; printf '%s\n' "$hits" | head -20; rc=1
fi
# Git Bash grep strips CR in text mode, so count CR bytes with tr instead.
for f in "${files[@]}"; do
  [[ "$f" == *.ps1 || ! -f "$f" ]] && continue
  if (( $(tr -cd '\r' < "$f" | wc -c) > 0 )); then echo "scrub-check: CR bytes in $f"; rc=1; fi
done
((rc)) && echo "scrub-check: FAILED" >&2 || echo "scrub-check: clean (${#files[@]} files)"
exit "$rc"
