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
REPO_DIR="$WORK_DIR/ipu7-camera-hal"

if [[ ! -d "$REPO_DIR" ]]; then
  echo "Missing ipu7-camera-hal. Run ./1_do_clone_sources.sh first." >&2
  exit 1
fi

run sudo apt install -y \
  libexpat-dev \
  libjsoncpp-dev \
  automake \
  libtool \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev

BUILD_DIR="$REPO_DIR/build"
run rm -rf "$BUILD_DIR"
run mkdir -p "$BUILD_DIR"
enter_dir "$BUILD_DIR"

run cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_CAMHAL_ADAPTOR=ON \
  -DBUILD_CAMHAL_PLUGIN=ON \
  -DIPU_VERSIONS="ipu7x;ipu75xa" \
  -DUSE_STATIC_GRAPH=ON \
  -DUSE_STATIC_GRAPH_AUTOGEN=ON \
  "$REPO_DIR"

run make -j"$(nproc)"
run sudo make install
