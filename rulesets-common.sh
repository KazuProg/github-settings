#!/usr/bin/env bash
# Shared ruleset paths and helpers for apply.sh and setup.sh.
# Source after cd to the repository root (where this file lives).

PRESETS_DIR="settings/presets"

REQUIRED_RULESETS=("default-branch-protection")

# Sets SETTINGS_DIR / RULESETS_DIR for the given preset name.
# Call after the preset name is finalized (e.g. after argument parsing).
resolve_preset_dir() {
  local preset="$1"
  SETTINGS_DIR="${PRESETS_DIR}/${preset}"
  RULESETS_DIR="${SETTINGS_DIR}/rulesets"
  if [[ ! -d "$SETTINGS_DIR" ]]; then
    echo "Error: preset not found: ${preset} (expected directory: ${SETTINGS_DIR})" >&2
    exit 1
  fi
}

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
