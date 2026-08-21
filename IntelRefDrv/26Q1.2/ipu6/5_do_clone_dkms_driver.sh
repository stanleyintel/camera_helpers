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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
DRIVER_DIR="$WORK_DIR/Intel-MIPI-CSI-Camera-Reference-Driver"
RELEASE_BRANCH="release/26Q1.2"
REPO_URL="https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver.git"
PATCHES=(
  "$SCRIPT_DIR/0001-ipu-fix-colorimetry.patch"
  "$SCRIPT_DIR/0002-dkms-reuse-kernel-tarball.patch"
)

if [[ -d "$DRIVER_DIR/.git" ]]; then
  echo "already cloned: $DRIVER_DIR"
  exit 0
fi

if [[ -e "$DRIVER_DIR" ]]; then
  echo "ERROR: path exists and is not a git repo: $DRIVER_DIR" >&2
  exit 1
fi

for patch_src in "${PATCHES[@]}"; do
  if [[ ! -f "$patch_src" ]]; then
    echo "ERROR: patch not found: $patch_src" >&2
    exit 1
  fi
done

run git clone "$REPO_URL" -b "$RELEASE_BRANCH" "$DRIVER_DIR"
run git -C "$DRIVER_DIR" submodule update --init --recursive

apply_patch_if_needed() {
  local patch_src="$1"
  local patch_dst="$DRIVER_DIR/$(basename "$patch_src")"

  run cp -f "$patch_src" "$patch_dst"

  if $DRY_RUN; then
    run git -C "$DRIVER_DIR" apply --check "$patch_dst"
    run git -C "$DRIVER_DIR" apply "$patch_dst"
    echo "dry-run: skipped patch state detection and apply execution for $patch_dst"
    return 0
  fi

  if git -C "$DRIVER_DIR" apply --check "$patch_dst" >/dev/null 2>&1; then
    run git -C "$DRIVER_DIR" apply "$patch_dst"
    echo "patch applied: $patch_dst"
  elif git -C "$DRIVER_DIR" apply --reverse --check "$patch_dst" >/dev/null 2>&1; then
    echo "patch already applied, skip: $patch_dst"
  else
    echo "ERROR: patch cannot be applied cleanly: $patch_dst" >&2
    exit 1
  fi
}

for patch_src in "${PATCHES[@]}"; do
  apply_patch_if_needed "$patch_src"
done
