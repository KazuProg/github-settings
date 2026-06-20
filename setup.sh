#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY="${SCRIPT_DIR}/apply.sh"

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

echo "==> Planned command:"
printf "    ./apply.sh %q\n" "$TARGET"
echo ""

DRY_RUN_RAN=false
if prompt_yes_no "Run --dry-run first?" y; then
  DRY_RUN_RAN=true
  echo ""
  "$APPLY" "$TARGET" --dry-run
  echo ""
fi

if prompt_yes_no "Apply now?" n; then
  echo ""
  "$APPLY" "$TARGET"
else
  if $DRY_RUN_RAN; then
    echo "Skipped apply (dry-run only)."
  else
    echo "Aborted before apply."
  fi
fi
