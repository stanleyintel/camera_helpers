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

clone_or_checkout https://github.com/intel/ipu6-camera-bins.git ipu6-camera-bins 0b102acf2d95f86ec85f0299e0dc779af5fdfb81
clone_or_checkout https://github.com/intel/ipu6-camera-hal.git ipu6-camera-hal a647a0a0c660c1e43b00ae9e06c0a74428120f3a
clone_or_checkout https://github.com/intel/icamerasrc.git icamerasrc 4fb31db76b618aae72184c59314b839dedb42689
