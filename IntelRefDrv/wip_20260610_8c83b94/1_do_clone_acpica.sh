#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry) DRY_RUN=true ;;
    *)
      echo "Unsupported argument: $arg" >&2
      echo "Usage: $0 [--dry]" >&2
      exit 1
      ;;
  esac
done

run() {
  printf ''
  printf '%q ' "$@"
  printf '\n'
  if ! $DRY_RUN; then
    "$@"
  fi
}

WORK_DIR="$(pwd)"
REPO_URL="https://github.com/acpica/acpica.git"
REPO_DIR="acpica"
LOCAL_BRANCH="20260408"
TAG_NAME="20260408"
REPO_PATH="$WORK_DIR/$REPO_DIR"

if [[ -d "$REPO_PATH/.git" ]]; then
  run git -C "$REPO_PATH" fetch --all --tags --prune
elif [[ -e "$REPO_PATH" ]]; then
  echo "ERROR: path exists and is not a git repo: $REPO_PATH" >&2
  exit 1
else
  run git clone "$REPO_URL" "$REPO_PATH"
fi

run git -C "$REPO_PATH" checkout -B "$LOCAL_BRANCH" "tags/$TAG_NAME"
