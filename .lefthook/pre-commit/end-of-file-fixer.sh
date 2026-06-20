#!/usr/bin/env bash
set -euo pipefail

# Normalize to exactly one trailing newline (non-empty files only).
normalize_eof_to() {
  local src="$1"
  local dst="$2"

  cp -- "$src" "$dst"
  while [[ -s "$dst" ]] && cmp -s <(tail -c1 "$dst") <(printf '\n'); do
    truncate -s -1 "$dst"
  done
  printf '\n' >>"$dst"
}

for file in "$@"; do
  [[ -f "$file" ]] || continue
  if ! grep -Iq . "$file" 2>/dev/null; then
    continue
  fi
  [[ -s "$file" ]] || continue

  normalized="$(mktemp)"
  normalize_eof_to "$file" "$normalized"

  if ! cmp -s "$file" "$normalized"; then
    cp -- "$normalized" "$file"
  fi

  rm -f "$normalized"
done
