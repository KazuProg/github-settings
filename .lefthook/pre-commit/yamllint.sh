#!/usr/bin/env bash
set -euo pipefail

[[ $# -gt 0 ]] || exit 0

uvx yamllint "$@"
