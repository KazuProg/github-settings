#!/usr/bin/env bash
set -euo pipefail

for file in "$@"; do
  [[ -f "$file" ]] || continue
  if ! grep -Iq . "$file" 2>/dev/null; then
    continue
  fi
  if sed --version >/dev/null 2>&1; then
    sed -i 's/[[:space:]]*$//' "$file"
  else
    sed -i '' 's/[[:space:]]*$//' "$file"
  fi
done
