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
REPO_DIR="$WORK_DIR/ipu6-camera-bins"

if [[ ! -d "$REPO_DIR" ]]; then
  echo "Missing ipu6-camera-bins. Run ./1_do_clone_sources.sh first." >&2
  exit 1
fi

shopt -s nullglob
runtime_libs=()
for pattern in "$REPO_DIR"/lib/lib* "$REPO_DIR"/lib/*/lib*; do
  for path in $pattern; do
    [[ -e "$path" ]] || continue
    [[ "$path" == */pkgconfig/* || "$path" == */firmware/* ]] && continue
    runtime_libs+=("$path")
  done
done

firmware_bins=()
for pattern in "$REPO_DIR"/lib/firmware/intel/*.bin "$REPO_DIR"/lib/firmware/intel/ipu/*.bin; do
  for path in $pattern; do
    [[ -e "$path" ]] || continue
    firmware_bins+=("$path")
  done
done

pkgconfigs=()
for pattern in "$REPO_DIR"/lib/pkgconfig/* "$REPO_DIR"/lib/*/pkgconfig/*; do
  for path in $pattern; do
    [[ -e "$path" ]] || continue
    pkgconfigs+=("$path")
  done
done

if ((${#runtime_libs[@]} == 0 || ${#firmware_bins[@]} == 0 || ${#pkgconfigs[@]} == 0)); then
  echo "ipu6-camera-bins layout does not match the expected 26Q1.2 release structure." >&2
  exit 1
fi

run sudo mkdir -p /lib/firmware/intel/ipu
run sudo cp -r "${firmware_bins[@]}" /lib/firmware/intel/ipu/
run sudo cp -P "${runtime_libs[@]}" /usr/lib/

run sudo mkdir -p /usr/include /usr/lib/pkgconfig
run sudo cp -r "$REPO_DIR"/include/* /usr/include/
run sudo cp -r "${pkgconfigs[@]}" /usr/lib/pkgconfig/
