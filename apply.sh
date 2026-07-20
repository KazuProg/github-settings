#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=rulesets-common.sh
source rulesets-common.sh

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

# Fetch current state for all endpoints and build a JSON matching settings.json shape.
build_unified_current_json() {
  local actions_perms actions_selected allowed
  local response imm pvr da dsu

  actions_perms="$(gh api "repos/${TARGET}/actions/permissions")"
  allowed="$(jq -r '.allowed_actions' <<<"$actions_perms")"
  if [[ "$allowed" == "selected" ]]; then
    actions_selected="$(gh api "repos/${TARGET}/actions/permissions/selected-actions")"
  else
    actions_selected="null"
  fi

  if response="$(gh api "repos/${TARGET}/immutable-releases" 2>/dev/null)"; then
    imm="$(jq -r '.enabled // false' <<<"$response")"
  else
    imm=false
  fi

  if is_public_repo; then
    if response="$(gh api "repos/${TARGET}/private-vulnerability-reporting" 2>/dev/null)"; then
      pvr="$(jq -r '.enabled // false' <<<"$response")"
    else
      pvr=false
    fi
  else
    pvr=null
  fi

  if gh api "repos/${TARGET}/vulnerability-alerts" >/dev/null 2>&1; then
    da=true
  else
    da=false
  fi

  if response="$(gh api "repos/${TARGET}/automated-security-fixes" 2>/dev/null)"; then
    dsu="$(jq -r '.enabled // false' <<<"$response")"
  else
    dsu=false
  fi

  jq -n \
    --argjson general "$REPO_JSON" \
    --argjson actions_perms "$actions_perms" \
    --argjson actions_selected "$actions_selected" \
    --argjson imm "$imm" \
    --argjson pvr "$pvr" \
    --argjson da "$da" \
    --argjson dsu "$dsu" \
    '{
      general: $general,
      actions: { permissions: $actions_perms, selected: $actions_selected },
      features: {
        immutable_releases: $imm,
        private_vulnerability_reporting: $pvr,
        dependabot_alerts: $da,
        dependabot_security_updates: $dsu
      }
    }'
}

# Build settings.json content with per-repo adjustments applied (private repo, GHAS, etc.).
build_unified_desired_json() {
  local settings_file="$SETTINGS_FILE"
  local desired
  desired="$(jq '.' "$settings_file")"

  if [[ "$(jq -r '.private' <<<"$REPO_JSON")" == "true" ]] &&
    [[ "$(jq -r '.security_and_analysis.advanced_security.status // "disabled"' <<<"$REPO_JSON")" != "enabled" ]]; then
    desired="$(jq 'del(.general.security_and_analysis)' <<<"$desired")"
  fi

  if ! is_public_repo; then
    desired="$(jq '.features.private_vulnerability_reporting = null' <<<"$desired")"
  fi

  if [[ "$(jq -r '.actions.permissions.allowed_actions' <<<"$desired")" != "selected" ]]; then
    desired="$(jq '.actions.selected = null' <<<"$desired")"
  fi

  printf '%s' "$desired"
}

show_unified_dry_run_diff() {
  local desired current filtered
  desired="$(build_unified_desired_json | jq -S .)"
  current="$(build_unified_current_json)"
  filtered="$(jq -S --argjson desired "$desired" "$JQ_FILTER_TO_DESIRED" <<<"$current")"
  if [[ "$filtered" == "$desired" ]]; then
    print_status "$COLOR_STATUS_OK" "(no diff)"
  else
    print_colored_diff <(echo "$filtered") <(echo "$desired")
  fi
}

# Omit security_and_analysis on private repos without GitHub Advanced Security.
build_general_settings_json() {
  local settings_file="$SETTINGS_FILE"
  if [[ "$(jq -r '.private' <<<"$REPO_JSON")" != "true" ]]; then
    jq '.general' "${settings_file}"
    return
  fi
  if [[ "$(jq -r '.security_and_analysis.advanced_security.status // "disabled"' <<<"$REPO_JSON")" == "enabled" ]]; then
    jq '.general' "${settings_file}"
    return
  fi
  print_status "$COLOR_STATUS_SKIP" "(skipping secret scanning; private repo without Advanced Security)"
  jq '.general | del(.security_and_analysis)' "${settings_file}"
}

apply_feature_from_settings() {
  local label="$1"
  local features_key="$2"
  local endpoint="$3"
  local settings_file="$SETTINGS_FILE"
  local enabled
  enabled="$(jq -r ".features.${features_key} // false" "$settings_file")"
  if [[ "$enabled" == "true" ]]; then
    enable_feature "$label" "$endpoint"
  else
    skip_feature "$label" "(skipped; disabled in settings.json)"
  fi
}

# PUT endpoint to enable a feature.
enable_feature() {
  local label="$1"
  local endpoint="$2"
  echo "--> ${label}"
  gh api -X PUT "${endpoint}" >/dev/null
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
    return 2
  fi
  echo "Error: failed to query rulesets API:" >&2
  echo "$response" >&2
  exit 1
}

ruleset_id_in_index() {
  local name="$1"
  local index_json="$2"
  jq -r --arg name "$name" '
    [.[] | select(.source_type == "Repository" and .name == $name)] | first | .id // empty
  ' <<<"$index_json"
}

show_ruleset_dry_run_diff() {
  local name="$1"
  local desired_raw="$2"
  local existing_id="$3"
  local desired current filtered

  desired="$(jq -S . <<<"$desired_raw")"

  if [[ -z "$existing_id" ]]; then
    print_status "$COLOR_STATUS_WOULD" "(would create: ${name})"
    print_colored_diff /dev/null <(echo "$desired")
    return
  fi

  print_status "$COLOR_STATUS_WOULD" "(would update: ${name}, id=${existing_id})"
  if ! current="$(gh api "repos/${TARGET}/rulesets/${existing_id}" 2>/dev/null)"; then
    print_status "$COLOR_STATUS_SKIP" "(failed to fetch current ruleset; skipping diff)"
    return
  fi
  filtered="$(jq -S --argjson desired "$desired" "$JQ_FILTER_TO_DESIRED" <<<"$current")"
  if [[ "$filtered" == "$desired" ]]; then
    print_status "$COLOR_STATUS_OK" "(no diff)"
  else
    print_colored_diff <(echo "$filtered") <(echo "$desired")
  fi
}

upsert_ruleset() {
  local name="$1"
  local json="$2"
  local existing_id created current_bypass
  existing_id="$(ruleset_id_in_index "$name" "$RULESETS_INDEX")"

  if $DRY_RUN; then
    show_ruleset_dry_run_diff "$name" "$json" "$existing_id"
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
    # Preserve manually-managed bypass_actors (e.g. release Deploy Keys) unless
    # the definition explicitly specifies them; PUT replaces the whole ruleset.
    if ! jq -e 'has("bypass_actors")' <<<"$json" >/dev/null; then
      current_bypass="$(gh api "repos/${TARGET}/rulesets/${existing_id}" --jq '.bypass_actors // []')"
      json="$(jq --argjson bypass_actors "$current_bypass" '. + {bypass_actors: $bypass_actors}' <<<"$json")"
    fi
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

append_with_rulesets() {
  local raw="$1"
  local part file
  IFS=',' read -ra parts <<<"$raw"
  for part in "${parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    if [[ -z "$part" ]]; then
      continue
    fi
    file="$(ruleset_definition_file "$part")"
    if [[ ! -f "$file" ]]; then
      echo "Error: ruleset not found: ${file}" >&2
      exit 1
    fi
    if is_required_ruleset "$part"; then
      echo "Error: ${part} is a required ruleset (always applied)" >&2
      exit 1
    fi
    WITH_RULESETS+=("$part")
  done
}

apply_rulesets_from_settings() {
  local def file applied=false rc

  set +e
  RULESETS_INDEX="$(fetch_rulesets_index)"
  rc=$?
  set -e
  if [[ $rc -eq 2 ]]; then
    print_status "$COLOR_STATUS_SKIP" "(skipped; rulesets require GitHub Pro on private repos)"
    return
  fi

  for def in "${REQUIRED_RULESETS[@]}"; do
    file="$(ruleset_definition_file "$def")"
    if [[ ! -f "$file" ]]; then
      echo "Error: required ruleset not found: ${file}" >&2
      exit 1
    fi
    applied=true
    apply_rulesets_in_file "$file" "$def"
  done

  if ((${#WITH_RULESETS[@]} > 0)); then
    for def in "${WITH_RULESETS[@]}"; do
      applied=true
      apply_rulesets_in_file "$(ruleset_definition_file "$def")" "$def"
    done
  fi

  if ! $applied; then
    print_status "$COLOR_STATUS_SKIP" "(no ruleset definitions configured)"
  fi
}

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <owner>/<repo> [--preset <name>] [--dry-run] [--no-post-setup] [--with-rulesets <name>[,<name>...]]

Apply repo-setup GitHub repository settings to the target repository.

With --dry-run, no API write is performed. Settings steps show an actual
diff against the live repository. Enable-only steps report whether each
feature is already enabled.

Presets (--preset):
  Subdirectories under settings/presets/ (e.g. "internal-tool"). A preset
  supplies its own settings.json (deep-merged over settings/settings.json)
  and optionally rulesets/ and post-setup.sh.

Optional rulesets (--with-rulesets):
  Basenames under settings/rulesets/ not listed in REQUIRED_RULESETS.
  When a preset is selected, same-basename files under the preset's
  rulesets/ override the default definition, but the required / optional
  set itself comes from settings/rulesets/.

Post-setup:
  If the selected preset ships an executable post-setup.sh, it runs after
  the ruleset step. Pass --no-post-setup to skip it.

Feature toggles (immutable releases, private vulnerability reporting,
Dependabot alerts / security updates) are controlled by the "features"
section of settings/settings.json.

Requires gh (authenticated with the 'repo' scope) and jq.
The target repository must already exist.

Repository-type skips (reported during apply):
  - Secret scanning: private repos without Advanced Security
  - Private vulnerability reporting: public repos only
  - Features disabled via settings/settings.json (features.*)
  - Rulesets: skipped on private repos on GitHub Free (requires Pro)
EOF
  exit 1
}

resolve_preset() {
  local name="$1"
  local preset_dir="settings/presets/${name}"
  if [[ ! -d "$preset_dir" ]]; then
    echo "Error: preset not found: ${name} (expected ${preset_dir})" >&2
    exit 1
  fi
  PRESET_DIR="$preset_dir"

  if [[ -f "${preset_dir}/settings.json" ]]; then
    SETTINGS_FILE="${preset_dir}/settings.json"
  fi

  if [[ -d "${preset_dir}/rulesets" ]]; then
    PRESET_RULESETS_DIR="${preset_dir}/rulesets"
  fi
}

TARGET=""
PRESET=""
DRY_RUN=false
NO_POST_SETUP=false
WITH_RULESETS=()
RAW_WITH_RULESETS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    ;;
  --preset)
    if [[ $# -lt 2 ]]; then
      echo "Error: --preset requires a value" >&2
      exit 1
    fi
    PRESET="$2"
    shift 2
    ;;
  --dry-run)
    DRY_RUN=true
    shift
    ;;
  --no-post-setup)
    NO_POST_SETUP=true
    shift
    ;;
  --with-rulesets)
    if [[ $# -lt 2 ]]; then
      echo "Error: --with-rulesets requires a value" >&2
      exit 1
    fi
    if [[ -n "$RAW_WITH_RULESETS" ]]; then
      RAW_WITH_RULESETS="${RAW_WITH_RULESETS},$2"
    else
      RAW_WITH_RULESETS="$2"
    fi
    shift 2
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

if ! [[ "$TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Error: invalid target format. Expected: <owner>/<repo>" >&2
  exit 1
fi

require_command gh
require_command jq

SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
PRESET_DIR=""
PRESET_RULESETS_DIR=""

if [[ -n "$PRESET" ]]; then
  resolve_preset "$PRESET"
fi

discover_rulesets

if [[ -n "$RAW_WITH_RULESETS" ]]; then
  append_with_rulesets "$RAW_WITH_RULESETS"
fi

REPO_JSON="$(gh api "repos/${TARGET}" 2>/dev/null)" || {
  echo "Error: repository not found: ${TARGET}" >&2
  exit 1
}

REPO_VISIBILITY="public"
[[ "$(jq -r '.private' <<<"$REPO_JSON")" == "true" ]] && REPO_VISIBILITY="private"

echo "==> Applying repo-setup to: ${TARGET} (${REPO_VISIBILITY})"
if [[ -n "$PRESET" ]]; then
  echo "    Preset: ${PRESET}"
fi

run_post_setup() {
  local script="${PRESET_DIR}/post-setup.sh"
  if [[ -z "$PRESET_DIR" ]]; then
    return
  fi
  if [[ ! -e "$script" ]]; then
    return
  fi
  if [[ ! -x "$script" ]]; then
    echo "Warning: ${script} exists but is not executable; skipping" >&2
    return
  fi
  if $NO_POST_SETUP; then
    skip_feature "Post-setup (${script})" "(skipped; --no-post-setup)"
    return
  fi
  echo "--> Post-setup (${script})"
  DRY_RUN="$DRY_RUN" "$script" "$TARGET"
}

if $DRY_RUN; then
  echo "    DRY-RUN MODE (no API writes)"
  echo "--> Settings diff"
  show_unified_dry_run_diff
  echo "--> Rulesets"
  apply_rulesets_from_settings
  run_post_setup
  echo "==> Done."
  exit 0
fi

echo "--> General settings"
build_general_settings_json | gh api -X PATCH "repos/${TARGET}" --input - >/dev/null

echo "--> Actions permissions"
jq -c '.actions.permissions' "$SETTINGS_FILE" |
  gh api -X PUT "repos/${TARGET}/actions/permissions" --input - >/dev/null

ALLOWED_ACTIONS="$(jq -r '.actions.permissions.allowed_actions' "$SETTINGS_FILE")"
if [[ "$ALLOWED_ACTIONS" == "selected" ]]; then
  echo "--> Actions allowed actions (selected)"
  jq -c '.actions.selected' "$SETTINGS_FILE" |
    gh api -X PUT "repos/${TARGET}/actions/permissions/selected-actions" --input - >/dev/null
fi

apply_feature_from_settings \
  "Release immutability" \
  "immutable_releases" \
  "repos/${TARGET}/immutable-releases"

if is_public_repo; then
  apply_feature_from_settings \
    "Private vulnerability reporting" \
    "private_vulnerability_reporting" \
    "repos/${TARGET}/private-vulnerability-reporting"
else
  skip_feature "Private vulnerability reporting" "(skipped; public repositories only)"
fi

apply_feature_from_settings \
  "Dependabot alerts" \
  "dependabot_alerts" \
  "repos/${TARGET}/vulnerability-alerts"

apply_feature_from_settings \
  "Dependabot security updates" \
  "dependabot_security_updates" \
  "repos/${TARGET}/automated-security-fixes"

echo "--> Rulesets"
apply_rulesets_from_settings

run_post_setup

echo "==> Done."
