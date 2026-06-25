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
RELEASE_BRANCH="release/26Q1.2"

clone_or_checkout() {
  local repo_url="$1"
  local repo_dir="$2"
  local commit_id="$3"
  local repo_path="$WORK_DIR/$repo_dir"

  if [[ -d "$repo_path/.git" ]]; then
    run git -C "$repo_path" fetch --all --tags --prune
  elif [[ -e "$repo_path" ]]; then
    echo "Path already exists and is not a git repo: $repo_path" >&2
    exit 1
  else
    run git clone "$repo_url" "$repo_path"
  fi

  run git -C "$repo_path" checkout -B "$RELEASE_BRANCH" "$commit_id"
  run git -C "$repo_path" submodule update --init --recursive
}

clone_or_checkout https://github.com/intel/ipu7-camera-bins.git ipu7-camera-bins 2ef0857570b2dde3c2072fdacf22fdfff1a89bf2
clone_or_checkout https://github.com/intel/ipu7-camera-hal.git ipu7-camera-hal 3b9388ecdb682b6e7e9f57a4192b4612bfb43410
clone_or_checkout https://github.com/intel/icamerasrc.git icamerasrc 4fb31db76b618aae72184c59314b839dedb42689
