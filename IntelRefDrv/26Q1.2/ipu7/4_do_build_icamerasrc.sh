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

WORK_DIR="$(pwd)"
REPO_DIR="$WORK_DIR/icamerasrc"

if [[ ! -d "$REPO_DIR" ]]; then
  echo "Missing icamerasrc. Run ./1_do_clone_sources.sh first." >&2
  exit 1
fi

run sudo -E apt install -y \
  libdrm-dev \
  libva-dev \
  libgstreamer-plugins-bad1.0-dev

enter_dir "$REPO_DIR"

export CHROME_SLIM_CAMHAL=ON

CONFIGURE_ARGS=(--prefix=/usr --enable-gstdrmformat=yes)

run ./autogen.sh
run ./configure "${CONFIGURE_ARGS[@]}"
run make -j"$(nproc)"
run sudo make install
