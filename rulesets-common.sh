#!/usr/bin/env bash
# Shared ruleset paths and helpers for apply.sh and setup.sh.
# Source after cd to the repository root (where this file lives).

SETTINGS_DIR="settings"
RULESETS_DIR="${SETTINGS_DIR}/rulesets"

REQUIRED_RULESETS=()
# shellcheck disable=SC2034 # consumed by setup.sh after sourcing
OPTIONAL_RULESETS=()

_list_ruleset_basenames() {
  local dir="$1"
  local f
  [[ -d "$dir" ]] || return 0
  shopt -s nullglob
  for f in "$dir"/*.json; do
    basename "$f" .json
  done
  shopt -u nullglob
}

_collect_unique() {
  local target="$1"
  shift
  local combined name
  combined="$(
    for dir in "$@"; do
      [[ -n "$dir" ]] && _list_ruleset_basenames "$dir"
    done | awk '!seen[$0]++'
  )"
  eval "${target}=()"
  while IFS= read -r name; do
    [[ -n "$name" ]] && eval "${target}+=(\"\$name\")"
  done <<<"$combined"
}

# Populate REQUIRED_RULESETS / OPTIONAL_RULESETS from
# preset's rulesets/{required,optional} ∪ default's rulesets/{required,optional},
# deduplicated by basename.
discover_rulesets() {
  _collect_unique REQUIRED_RULESETS \
    "${PRESET_RULESETS_DIR:-}/required" \
    "${RULESETS_DIR}/required"
  _collect_unique OPTIONAL_RULESETS \
    "${PRESET_RULESETS_DIR:-}/optional" \
    "${RULESETS_DIR}/optional"
}

ruleset_definition_file() {
  local name="$1"
  local dir
  for dir in \
    "${PRESET_RULESETS_DIR:-}/required" \
    "${PRESET_RULESETS_DIR:-}/optional" \
    "${RULESETS_DIR}/required" \
    "${RULESETS_DIR}/optional"; do
    if [[ -n "$dir" && -f "${dir}/${name}.json" ]]; then
      printf '%s/%s.json' "$dir" "$name"
      return
    fi
  done
  # Fallback path (file not found; caller reports the error).
  printf '%s/%s.json' "${RULESETS_DIR}/required" "$name"
}

is_required_ruleset() {
  local name="$1"
  local def
  for def in "${REQUIRED_RULESETS[@]}"; do
    [[ "$def" == "$name" ]] && return 0
  done
  return 1
}
