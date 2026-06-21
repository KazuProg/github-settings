#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_DIR="${SCRIPT_DIR}/settings"
RULESETS_DIR="${SETTINGS_DIR}/rulesets"

# Basenames under settings/rulesets/ (<name>.json). Add entries when introducing
# additional ruleset definition files.
RULESET_DEFINITIONS=("default-branch-protection")

JQ_FILTER_TO_DESIRED="$(
  cat <<'EOF'
  def fill_from($src):
    if type == "object" then
      to_entries
      | map(
          ($src[.key]) as $child
          | .value = (.value | fill_from($child))
        )
      | from_entries
    else
      $src
    end;
  . as $current | $desired | fill_from($current)
EOF
)"

readonly COLOR_STATUS_OK=90
readonly COLOR_STATUS_WOULD=33
readonly COLOR_STATUS_INFO=36
readonly COLOR_STATUS_SKIP=35

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

print_status() {
  printf '    \033[%sm%s\033[0m\n' "$1" "$2" >&2
}

print_colored_diff() {
  diff --color=always -U999 -u "$1" "$2" 2>/dev/null |
    sed -E $'/\033\\[[0-9;]*m--- /d; /\033\\[[0-9;]*m\\+\\+\\+ /d; /\033\\[[0-9;]*m@@ /d; s/^/    /' ||
    true
}

# Optional third argument: cached API JSON (avoids a duplicate GET).
# settings_source: file path, or "-" to read desired JSON from stdin.
dry_run_json_diff() {
  local api_path="$1"
  local settings_source="$2"
  local current_json="${3:-}"
  local desired_json current_filtered

  if [[ "$settings_source" == "-" ]]; then
    desired_json="$(jq -S .)"
  else
    desired_json="$(jq -S . "${settings_source}")"
  fi
  if [[ -z "$current_json" ]]; then
    current_json="$(gh api "${api_path}")"
  fi
  current_filtered="$(jq -S --argjson desired "$desired_json" "$JQ_FILTER_TO_DESIRED" <<<"$current_json")"
  if [[ "$current_filtered" == "$desired_json" ]]; then
    print_status "$COLOR_STATUS_OK" "(no diff)"
  else
    print_colored_diff <(echo "$current_filtered") <(echo "$desired_json")
  fi
}

# Omit security_and_analysis on private repos without GitHub Advanced Security.
build_general_settings_json() {
  local settings_file="${SETTINGS_DIR}/settings.json"
  if [[ "$(jq -r '.private' <<<"$REPO_JSON")" != "true" ]]; then
    jq '.' "${settings_file}"
    return
  fi
  if [[ "$(jq -r '.security_and_analysis.advanced_security.status // "disabled"' <<<"$REPO_JSON")" == "enabled" ]]; then
    jq '.' "${settings_file}"
    return
  fi
  print_status "$COLOR_STATUS_SKIP" "(skipping secret scanning; private repo without Advanced Security)"
  jq 'del(.security_and_analysis)' "${settings_file}"
}

# PUT endpoint to enable a feature. check: json (.enabled) | http204 (GET succeeds).
enable_feature() {
  local label="$1"
  local endpoint="$2"
  local would_msg="$3"
  local check="${4:-json}"

  echo "--> ${label}"
  if $DRY_RUN; then
    set +e
    case "$check" in
    json)
      local response
      response="$(gh api "${endpoint}" 2>/dev/null)"
      local code=$?
      set -e
      if [[ $code -eq 0 ]] &&
        [[ "$(jq -r '.enabled // false' <<<"$response")" == "true" ]]; then
        print_status "$COLOR_STATUS_OK" "(already enabled)"
      else
        print_status "$COLOR_STATUS_WOULD" "$would_msg"
      fi
      ;;
    http204)
      gh api "${endpoint}" >/dev/null 2>&1
      local code=$?
      set -e
      if [[ $code -eq 0 ]]; then
        print_status "$COLOR_STATUS_OK" "(already enabled)"
      else
        print_status "$COLOR_STATUS_WOULD" "$would_msg"
      fi
      ;;
    esac
  else
    gh api -X PUT "${endpoint}" >/dev/null
  fi
}

skip_feature() {
  local label="$1"
  local reason="$2"
  echo "--> ${label}"
  print_status "$COLOR_STATUS_SKIP" "$reason"
}

is_public_repo() {
  [[ "$(jq -r '.private' <<<"$REPO_JSON")" != "true" ]]
}

fetch_rulesets_index() {
  local response
  if response="$(gh api --paginate "repos/${TARGET}/rulesets?includes_parents=false" 2>&1)"; then
    printf '%s' "$response"
    return 0
  fi
  if echo "$response" | grep -q "Upgrade to GitHub Pro"; then
    cat >&2 <<EOF
Error: Rulesets API is not available for ${TARGET}.
       GitHub Free does not support rulesets on private repositories.
       Either upgrade to GitHub Pro or make ${TARGET} public.
EOF
  else
    echo "Error: failed to query rulesets API:" >&2
    echo "$response" >&2
  fi
  exit 1
}

ruleset_id_in_index() {
  local name="$1"
  local index_json="$2"
  jq -r --arg name "$name" '
    [.[] | select(.source_type == "Repository" and .name == $name)] | first | .id // empty
  ' <<<"$index_json"
}

upsert_ruleset() {
  local name="$1"
  local json="$2"
  local existing_id created
  existing_id="$(ruleset_id_in_index "$name" "$RULESETS_INDEX")"

  if $DRY_RUN; then
    if [[ -z "$existing_id" ]]; then
      print_status "$COLOR_STATUS_WOULD" "(would create: ${name})"
    else
      print_status "$COLOR_STATUS_WOULD" "(would update: ${name}, id=${existing_id})"
    fi
    return
  fi

  if [[ -z "$existing_id" ]]; then
    created="$(printf '%s' "$json" | gh api -X POST "repos/${TARGET}/rulesets" --input -)"
    RULESETS_INDEX="$(jq --argjson created "$created" '
      . + [{
        id: $created.id,
        name: $created.name,
        source_type: "Repository"
      }]
    ' <<<"$RULESETS_INDEX")"
    print_status "$COLOR_STATUS_OK" "(created: ${name})"
  else
    printf '%s' "$json" | gh api -X PUT "repos/${TARGET}/rulesets/${existing_id}" --input - >/dev/null
    print_status "$COLOR_STATUS_OK" "(updated: ${name}, id=${existing_id})"
  fi
}

apply_rulesets_in_file() {
  local file="$1"
  local label="$2"
  local count i rs_json rs_name

  if [[ ! -f "$file" ]]; then
    echo "Error: ruleset definition not found: ${file}" >&2
    exit 1
  fi
  if ! jq -e '.rulesets | type == "array"' "$file" >/dev/null; then
    echo "Error: ${file} must contain a \"rulesets\" array" >&2
    exit 1
  fi

  count="$(jq '.rulesets | length' "$file")"
  if [[ "$count" -eq 0 ]]; then
    echo "    ${label}: (no rulesets defined)"
    return
  fi

  for ((i = 0; i < count; i++)); do
    rs_json="$(jq -c ".rulesets[$i]" "$file")"
    rs_name="$(jq -r ".rulesets[$i].name" "$file")"
    echo "    ${rs_name} (${label}.json)"
    upsert_ruleset "$rs_name" "$rs_json"
  done
}

apply_rulesets_from_settings() {
  local def

  if [[ ${#RULESET_DEFINITIONS[@]} -eq 0 ]]; then
    print_status "$COLOR_STATUS_SKIP" "(no ruleset definitions configured)"
    return
  fi

  RULESETS_INDEX="$(fetch_rulesets_index)"

  for def in "${RULESET_DEFINITIONS[@]}"; do
    apply_rulesets_in_file "${RULESETS_DIR}/${def}.json" "$def"
  done
}

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <owner>/<repo> [--dry-run]

Apply repo-setup GitHub repository settings to the target repository.

With --dry-run, no API write is performed. Settings steps show an actual
diff against the live repository. Enable-only steps report whether each
feature is already enabled.

Requires gh (authenticated with the 'repo' scope) and jq.
The target repository must already exist.

Repository-type skips (reported during apply):
  - Secret scanning: private repos without Advanced Security
  - Private vulnerability reporting: public repos only
  - Rulesets: private repos on GitHub Free (requires Pro or public repo)
EOF
  exit 1
}

TARGET=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    ;;
  --dry-run)
    DRY_RUN=true
    shift
    ;;
  --*)
    echo "Error: unknown option: $1" >&2
    exit 1
    ;;
  *)
    if [[ -z "$TARGET" ]]; then
      TARGET="$1"
      shift
    else
      echo "Error: unexpected argument: $1" >&2
      exit 1
    fi
    ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  usage
fi

require_command gh
require_command jq

if ! [[ "$TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Error: invalid target format. Expected: <owner>/<repo>" >&2
  exit 1
fi

REPO_JSON="$(gh api "repos/${TARGET}" 2>/dev/null)" || {
  echo "Error: repository not found: ${TARGET}" >&2
  exit 1
}

REPO_VISIBILITY="public"
[[ "$(jq -r '.private' <<<"$REPO_JSON")" == "true" ]] && REPO_VISIBILITY="private"

echo "==> Applying repo-setup to: ${TARGET} (${REPO_VISIBILITY})"
if $DRY_RUN; then
  echo "    DRY-RUN MODE (no API writes)"
fi

echo "--> 1/8 General settings"
GENERAL_SETTINGS_JSON="$(build_general_settings_json)"
if $DRY_RUN; then
  echo "$GENERAL_SETTINGS_JSON" | dry_run_json_diff "repos/${TARGET}" "-" "$REPO_JSON"
else
  echo "$GENERAL_SETTINGS_JSON" | gh api -X PATCH "repos/${TARGET}" --input - >/dev/null
fi

enable_feature \
  "2/8 Enable release immutability" \
  "repos/${TARGET}/immutable-releases" \
  "(would enable release immutability)"

echo "--> 3/8 Actions permissions"
ACTIONS_PERMISSIONS_JSON=""
CURRENT_ALLOWED_ACTIONS=""
if $DRY_RUN; then
  ACTIONS_PERMISSIONS_JSON="$(gh api "repos/${TARGET}/actions/permissions")"
  CURRENT_ALLOWED_ACTIONS="$(jq -r '.allowed_actions' <<<"$ACTIONS_PERMISSIONS_JSON")"
  dry_run_json_diff \
    "repos/${TARGET}/actions/permissions" \
    "${SETTINGS_DIR}/actions.json" \
    "$ACTIONS_PERMISSIONS_JSON"
else
  gh api -X PUT "repos/${TARGET}/actions/permissions" --input "${SETTINGS_DIR}/actions.json" >/dev/null
fi

ALLOWED_ACTIONS="$(jq -r '.allowed_actions' "${SETTINGS_DIR}/actions.json")"
if [[ "$ALLOWED_ACTIONS" == "selected" ]]; then
  echo "--> 4/8 Actions allowed actions (selected)"
  if $DRY_RUN; then
    [[ -n "$CURRENT_ALLOWED_ACTIONS" ]] ||
      CURRENT_ALLOWED_ACTIONS="$(gh api "repos/${TARGET}/actions/permissions" | jq -r '.allowed_actions')"
    if [[ "$CURRENT_ALLOWED_ACTIONS" == "selected" ]]; then
      dry_run_json_diff \
        "repos/${TARGET}/actions/permissions/selected-actions" \
        "${SETTINGS_DIR}/actions-selected.json"
    else
      print_status "$COLOR_STATUS_INFO" "(selected-actions API unavailable while allowed_actions is \"${CURRENT_ALLOWED_ACTIONS}\")"
      print_status "$COLOR_STATUS_WOULD" "(would apply after step 3 sets allowed_actions to \"selected\")"
      print_colored_diff /dev/null <(jq -S . "${SETTINGS_DIR}/actions-selected.json")
    fi
  else
    gh api -X PUT "repos/${TARGET}/actions/permissions/selected-actions" \
      --input "${SETTINGS_DIR}/actions-selected.json" >/dev/null
  fi
else
  echo "--> 4/8 Actions allowed actions (selected)"
  print_status "$COLOR_STATUS_OK" "(skipped; allowed_actions is \"${ALLOWED_ACTIONS}\")"
fi

if is_public_repo; then
  enable_feature \
    "5/8 Enable private vulnerability reporting" \
    "repos/${TARGET}/private-vulnerability-reporting" \
    "(would enable private vulnerability reporting)"
else
  skip_feature \
    "5/8 Enable private vulnerability reporting" \
    "(skipped; public repositories only)"
fi

enable_feature \
  "6/8 Enable Dependabot alerts" \
  "repos/${TARGET}/vulnerability-alerts" \
  "(would enable Dependabot vulnerability alerts)" \
  http204

enable_feature \
  "7/8 Enable Dependabot security updates" \
  "repos/${TARGET}/automated-security-fixes" \
  "(would enable Dependabot automated security fixes)"

echo "--> 8/8 Rulesets"
apply_rulesets_from_settings

echo "==> Done."
