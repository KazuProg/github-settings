#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
APPLY="./apply.sh"

# shellcheck source=rulesets-common.sh
source rulesets-common.sh

discover_optional_ruleset_definitions() {
  local f label names=()
  OPTIONAL_RULESET_DEFINITIONS=()

  shopt -s nullglob
  for f in "${RULESETS_DIR}"/*.json; do
    label="$(basename "$f" .json)"
    if is_required_ruleset "$label"; then
      continue
    fi
    names+=("$label")
  done
  if ((${#names[@]} > 0)); then
    while IFS= read -r line; do
      OPTIONAL_RULESET_DEFINITIONS+=("$line")
    done < <(printf '%s\n' "${names[@]}" | sort)
  fi
  shopt -u nullglob
}

ruleset_prompt_label() {
  local def="$1"
  jq -r '.rulesets[0].name // "'"$def"'"' "$(ruleset_definition_file "$def")"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

if [[ ! -x "$APPLY" ]]; then
  echo "Error: apply.sh not found or not executable: $APPLY" >&2
  exit 1
fi

prompt_required() {
  # prompt_required <prompt> <var_name> <regex> <error_msg>
  local prompt="$1"
  local var_name="$2"
  local regex="$3"
  local err="$4"
  local value
  while true; do
    read -rp "$prompt" value || {
      echo
      exit 130
    }
    if [[ "$value" =~ $regex ]]; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    echo "  ! $err" >&2
  done
}

prompt_yes_no() {
  # prompt_yes_no <prompt> <default: y|n>
  local prompt="$1"
  local default="$2"
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  local ans
  read -rp "$prompt $hint " ans || {
    echo
    exit 130
  }
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

require_command gh
require_command jq

OPTIONAL_RULESET_DEFINITIONS=()
discover_optional_ruleset_definitions

echo "==> repo-setup interactive setup"
echo ""

prompt_required \
  "Target repository (owner/repo): " \
  TARGET \
  '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$' \
  "Invalid format. Expected: owner/repo"

REPO_VISIBILITY="$(gh api "repos/${TARGET}" --jq 'if .private then "private" else "public" end' 2>/dev/null)" || {
  echo "  ! Repository not found: ${TARGET}" >&2
  echo "    Create the repository on GitHub first, then run this script again." >&2
  exit 1
}
echo "  -> ${TARGET} (${REPO_VISIBILITY})"
echo ""

build_apply_args() {
  APPLY_ARGS=("$TARGET")
  if ((${#ENABLED_OPTIONAL_RULESETS[@]} > 0)); then
    local joined
    joined="$(
      IFS=,
      echo "${ENABLED_OPTIONAL_RULESETS[*]}"
    )"
    APPLY_ARGS+=(--with-rulesets "$joined")
  fi
}

ENABLED_OPTIONAL_RULESETS=()

echo "==> Optional rulesets"
if ((${#OPTIONAL_RULESET_DEFINITIONS[@]} == 0)); then
  echo "  (none)"
else
  for def in "${OPTIONAL_RULESET_DEFINITIONS[@]}"; do
    label="$(ruleset_prompt_label "$def")"
    if prompt_yes_no "  Enable ${label}?" n; then
      ENABLED_OPTIONAL_RULESETS+=("$def")
    fi
  done
fi
echo ""

build_apply_args

echo "==> Planned command:"
printf -v APPLY_CMD './apply.sh'
for arg in "${APPLY_ARGS[@]}"; do
  APPLY_CMD+=" $(printf '%q' "$arg")"
done
printf "    %s\n" "$APPLY_CMD"
echo ""

DRY_RUN_RAN=false
if prompt_yes_no "Run --dry-run first?" y; then
  DRY_RUN_RAN=true
  echo ""
  "$APPLY" "${APPLY_ARGS[@]}" --dry-run
  echo ""
fi

if prompt_yes_no "Apply now?" n; then
  echo ""
  "$APPLY" "${APPLY_ARGS[@]}"
else
  if $DRY_RUN_RAN; then
    echo "Skipped apply (dry-run only)."
  else
    echo "Aborted before apply."
  fi
fi
