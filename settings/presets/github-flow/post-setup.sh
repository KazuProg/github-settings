#!/usr/bin/env bash
set -euo pipefail

# Post-setup for the github-flow preset.
# Invoked by apply.sh with:
#   $1        = <owner>/<repo>
#   $DRY_RUN  = "true" | "false"

: "${1:?usage: post-setup.sh <owner>/<repo>}"
TARGET="$1"
DRY_RUN="${DRY_RUN:-false}"

if ! [[ "$TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Error: invalid target format. Expected: <owner>/<repo>" >&2
  exit 1
fi

DEPLOY_KEY_TITLE="release-bot"
DEPLOY_KEY_SECRET_NAME="RELEASE_DEPLOY_KEY"
BYPASS_RULESET_NAME="Default Branch Protection"

RELEASE_KEY_TMP_DIR=""
cleanup_release_key_tmp_dir() {
  [[ -n "$RELEASE_KEY_TMP_DIR" ]] && rm -rf -- "$RELEASE_KEY_TMP_DIR"
}
trap cleanup_release_key_tmp_dir EXIT

create_label() {
  local name="$1"
  local color="$2"
  local description="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '    (would create/update label) %s (#%s)\n' "$name" "$color" >&2
    return
  fi
  gh label create "$name" \
    --repo "$TARGET" \
    --color "$color" \
    --description "$description" \
    --force >/dev/null
  printf '    (created/updated label) %s\n' "$name" >&2
}

find_deploy_key_id() {
  gh api "repos/${TARGET}/keys" |
    jq -r --arg title "$DEPLOY_KEY_TITLE" '.[] | select(.title == $title) | .id' |
    head -n1
}

find_ruleset_id() {
  local name="$1"
  gh api "repos/${TARGET}/rulesets?includes_parents=false" |
    jq -r --arg name "$name" '.[] | select(.source_type == "Repository" and .name == $name) | .id' |
    head -n1
}

# Add "any repository deploy key" as a bypass actor on the ruleset that
# blocks direct pushes to the default branch, without touching its other
# fields. Per GitHub's ruleset schema, actor_id must be null for actor_type
# DeployKey (it bypasses for all deploy keys on the repo, not one specific key).
add_deploy_key_bypass_actor() {
  local ruleset_id current already_present updated

  ruleset_id="$(find_ruleset_id "$BYPASS_RULESET_NAME")"
  if [[ -z "$ruleset_id" ]]; then
    echo "Warning: ruleset '${BYPASS_RULESET_NAME}' not found; skipping bypass actor registration" >&2
    return
  fi

  current="$(gh api "repos/${TARGET}/rulesets/${ruleset_id}")"
  already_present="$(
    jq '[.bypass_actors[]? | select(.actor_type == "DeployKey")] | length' <<<"$current"
  )"
  if [[ "$already_present" -gt 0 ]]; then
    printf '    (bypass actor already registered on %s)\n' "$BYPASS_RULESET_NAME" >&2
    return
  fi

  updated="$(
    jq '
      {name, target, enforcement, conditions, rules,
       bypass_actors: ((.bypass_actors // []) + [{actor_type: "DeployKey", actor_id: null, bypass_mode: "always"}])}
    ' <<<"$current"
  )"
  printf '%s' "$updated" | gh api -X PUT "repos/${TARGET}/rulesets/${ruleset_id}" --input - >/dev/null
  printf '    (added bypass actor to %s)\n' "$BYPASS_RULESET_NAME" >&2
}

setup_release_deploy_key() {
  local existing_key_id
  existing_key_id="$(find_deploy_key_id)"

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "$existing_key_id" ]]; then
      printf '    (deploy key already registered, id=%s)\n' "$existing_key_id" >&2
    else
      printf '    (would generate + register deploy key, set %s secret, add bypass actor)\n' "$DEPLOY_KEY_SECRET_NAME" >&2
    fi
    return
  fi

  if [[ -n "$existing_key_id" ]]; then
    printf '    (deploy key already registered, id=%s)\n' "$existing_key_id" >&2
  else
    RELEASE_KEY_TMP_DIR="$(mktemp -d)"
    ssh-keygen -t ed25519 -N "" -f "${RELEASE_KEY_TMP_DIR}/release-deploy-key" -C "release-bot@${TARGET}" -q

    existing_key_id="$(
      gh api "repos/${TARGET}/keys" \
        -f title="$DEPLOY_KEY_TITLE" \
        -f key="$(cat -- "${RELEASE_KEY_TMP_DIR}/release-deploy-key.pub")" \
        -F read_only=false \
        --jq .id
    )"

    gh secret set "$DEPLOY_KEY_SECRET_NAME" --repo "$TARGET" <"${RELEASE_KEY_TMP_DIR}/release-deploy-key"

    rm -rf -- "$RELEASE_KEY_TMP_DIR"
    RELEASE_KEY_TMP_DIR=""
    printf '    (created deploy key, id=%s)\n' "$existing_key_id" >&2
  fi

  add_deploy_key_bypass_actor
}

echo "--> Post-setup (github-flow): bump-level labels"
create_label "major-update" "B60205" "This PR triggers a major version bump"
create_label "minor-update" "FBCA04" "This PR triggers a minor version bump"
create_label "patch-update" "0E8A16" "This PR triggers a patch version bump"
create_label "no-release" "BFD4F2" "Skip the release for this PR"

echo "--> Post-setup (github-flow): release deploy key"
setup_release_deploy_key
