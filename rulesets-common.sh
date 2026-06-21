#!/usr/bin/env bash
# Shared ruleset paths and helpers for apply.sh and setup.sh.
# Source after cd to the repository root (where this file lives).

SETTINGS_DIR="settings"
RULESETS_DIR="${SETTINGS_DIR}/rulesets"

REQUIRED_RULESETS=("default-branch-protection")

ruleset_definition_file() {
  printf '%s/%s.json' "$RULESETS_DIR" "$1"
}

is_required_ruleset() {
  local name="$1"
  local def
  for def in "${REQUIRED_RULESETS[@]}"; do
    [[ "$def" == "$name" ]] && return 0
  done
  return 1
}
