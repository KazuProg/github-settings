#!/usr/bin/env bash
set -euo pipefail

# Post-setup for the github-flow preset.
# Invoked by apply.sh with:
#   $1        = <owner>/<repo>
#   $DRY_RUN  = "true" | "false"

: "${1:?usage: post-setup.sh <owner>/<repo>}"
TARGET="$1"
DRY_RUN="${DRY_RUN:-false}"

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

echo "--> Post-setup (github-flow): bump-level labels"
create_label "major-update" "B60205" "This PR triggers a major version bump"
create_label "minor-update" "FBCA04" "This PR triggers a minor version bump"
create_label "patch-update" "0E8A16" "This PR triggers a patch version bump"
create_label "no-release" "BFD4F2" "Skip the release for this PR"
