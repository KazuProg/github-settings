#!/usr/bin/env bash
set -euo pipefail

for file in "$@"; do
  jq empty "$file"
done
