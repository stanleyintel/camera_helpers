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

enter_dir() {
  printf 'cd %q\n' "$1"
  if ! $DRY_RUN; then
    cd "$1"
  fi
}

confirm_uninstall_old_acpica_tools() {
  local current_version="$1"

  if $DRY_RUN; then
    echo "dry-run: acpica-tools version $current_version is older than required $REQUIRED_VERSION"
    echo "dry-run: would ask whether to uninstall acpica-tools and continue"
    run sudo -E apt remove -y acpica-tools
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "ERROR: acpica-tools version $current_version is older than required $REQUIRED_VERSION" >&2
    echo "ERROR: interactive confirmation is required to uninstall acpica-tools" >&2
    exit 1
  fi

  while true; do
    read -r -p "acpica-tools version $current_version is older than required $REQUIRED_VERSION. Uninstall acpica-tools now? [y/N] " reply
    case "$reply" in
      [Yy]|[Yy][Ee][Ss])
        run sudo -E apt remove -y acpica-tools
        return 0
        ;;
      ""|[Nn]|[Nn][Oo])
        echo "stop: please uninstall acpica-tools first, then rerun this script" >&2
        exit 1
        ;;
      *)
        echo "please answer y or n"
        ;;
    esac
  done
}

get_iasl_version() {
  local version_out
  version_out="$(iasl --version 2>&1 || true)"
  grep -Eo 'version[[:space:]]+[0-9]{8}' <<<"$version_out" | awk '{print $2}' | head -n1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
ACPICA_DIR="$WORK_DIR/acpica"
REQUIRED_VERSION="20260408"

if command -v iasl >/dev/null 2>&1; then
  CURRENT_VERSION="$(get_iasl_version)"
  if [[ -z "$CURRENT_VERSION" ]]; then
    echo "ERROR: unable to parse iasl version from: iasl --version" >&2
    exit 1
  fi

  if dpkg-query -W -f='${Status}\n' acpica-tools 2>/dev/null | grep -Fxq 'install ok installed'; then
    if ((10#$CURRENT_VERSION >= 10#$REQUIRED_VERSION)); then
      echo "pass: acpica-tools version $CURRENT_VERSION is already installed; nothing to build or install"
      exit 0
    fi

    confirm_uninstall_old_acpica_tools "$CURRENT_VERSION"
  fi

  if ((10#$CURRENT_VERSION >= 10#$REQUIRED_VERSION)); then
    echo "pass: iasl version $CURRENT_VERSION is already available; nothing to build or install"
    exit 0
  fi
fi

if [[ ! -d "$ACPICA_DIR/.git" ]]; then
  echo "ERROR: acpica repo not found: $ACPICA_DIR" >&2
  echo "please run $SCRIPT_DIR/1_do_clone_acpica.sh first from this same working directory" >&2
  exit 1
fi

enter_dir "$ACPICA_DIR"

#run sudo -E apt update
run sudo -E apt install build-essential git flex bison
run make clean
run make
run sudo make install

if $DRY_RUN; then
  echo "dry-run: skipped installed iasl version verification"
  exit 0
fi

if ! command -v iasl >/dev/null 2>&1; then
  echo "ERROR: iasl is not in PATH after install" >&2
  exit 1
fi

CURRENT_VERSION="$(get_iasl_version)"
if [[ -z "$CURRENT_VERSION" ]]; then
  echo "ERROR: unable to parse iasl version from: iasl --version" >&2
  exit 1
fi

if ((10#$CURRENT_VERSION < 10#$REQUIRED_VERSION)); then
  echo "ERROR: installed iasl version $CURRENT_VERSION is older than required $REQUIRED_VERSION" >&2
  exit 1
fi

echo "acpica tools install verified: iasl version $CURRENT_VERSION"
