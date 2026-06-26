#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--dry] <ipu_tgl|ipu_adl|ipu_mtl>" >&2
}

DRY_RUN=false
POSITIONAL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry) DRY_RUN=true ;;
    *) POSITIONAL_ARGS+=("$arg") ;;
  esac
done

if ((${#POSITIONAL_ARGS[@]} == 0 || ${#POSITIONAL_ARGS[@]} > 1)); then
  usage
  exit 1
fi

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
REPO_DIR="$WORK_DIR/ipu6-camera-hal"
ICAMERASRC_DIR="$WORK_DIR/icamerasrc"
BUILD_SCRIPT="$REPO_DIR/build.sh"

if [[ ! -d "$REPO_DIR" ]]; then
  echo "Missing ipu6-camera-hal. Run ./1_do_clone_sources.sh first." >&2
  exit 1
fi

if [[ ! -d "$ICAMERASRC_DIR" ]]; then
  echo "Missing icamerasrc. Run ./1_do_clone_sources.sh first." >&2
  exit 1
fi

if [[ ! -f "$BUILD_SCRIPT" ]]; then
  echo "Missing build.sh in $REPO_DIR" >&2
  exit 1
fi

run sudo -E apt install -y \
  libexpat-dev \
  automake \
  libtool \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  libdrm-dev

BOARD="${POSITIONAL_ARGS[0]}"

case "$BOARD" in
  ipu_tgl) IPU_VERSION="ipu6" ;;
  ipu_adl) IPU_VERSION="ipu6ep" ;;
  ipu_mtl) IPU_VERSION="ipu6epmtl" ;;
  *)
    echo "Unsupported board: $BOARD" >&2
    usage
    exit 1
    ;;
esac

INSTALL_DIR="$WORK_DIR/out/$BOARD/install"

enter_dir "$WORK_DIR"
run "$BUILD_SCRIPT" --dma --board "$BOARD"
run sudo cp -r "$INSTALL_DIR"/etc* /etc/
run sudo cp -r "$INSTALL_DIR"/usr/include/* /usr/include/
run sudo cp -r "$INSTALL_DIR"/usr/lib/* /usr/lib/
