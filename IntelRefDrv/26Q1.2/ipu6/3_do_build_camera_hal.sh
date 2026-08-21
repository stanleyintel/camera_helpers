#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--dry] [ipu_arl|ipu_mtl|ipu_adl|ipu_tgl]" >&2
}

DRY_RUN=false
POSITIONAL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry) DRY_RUN=true ;;
    *) POSITIONAL_ARGS+=("$arg") ;;
  esac
done

if ((${#POSITIONAL_ARGS[@]} > 1)); then
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

REQUESTED_BOARD="${POSITIONAL_ARGS[0]:-ipu_arl}"

case "$REQUESTED_BOARD" in
  ipu_tgl)
    BUILD_BOARD="ipu_tgl"
    INSTALL_SUBDIR="ipu_tgl"
    ;;
  ipu_adl)
    BUILD_BOARD="ipu_adl"
    INSTALL_SUBDIR="ipu_adl"
    ;;
  ipu_mtl|ipu_arl)
    BUILD_BOARD="ipu_mtl"
    INSTALL_SUBDIR="ipu_mtl"
    ;;
  *)
    echo "Unsupported board: $REQUESTED_BOARD" >&2
    usage
    exit 1
    ;;
esac

INSTALL_DIR="$WORK_DIR/out/$INSTALL_SUBDIR/install"
IPU6EPMTL_CONFIG_DIR="$REPO_DIR/config/linux/ipu6epmtl"
IPU6EPMTL_TARGET_DIR="/etc/camera/ipu6epmtl"
IPU6EPMTL_PROFILE_XML="$IPU6EPMTL_TARGET_DIR/libcamhal_profile.xml"
IPU6EPMTL_PROFILE_BACKUP_XML="$IPU6EPMTL_TARGET_DIR/libcamhal_profile.xml.org"

enter_dir "$WORK_DIR"
run bash "$BUILD_SCRIPT" --dma --board "$BUILD_BOARD"
run sudo cp -r "$INSTALL_DIR"/etc* /etc/
run sudo cp -r "$INSTALL_DIR"/usr/include/* /usr/include/
run sudo cp -r "$INSTALL_DIR"/usr/lib/* /usr/lib/

if [[ "$INSTALL_SUBDIR" == "ipu_mtl" && -d "$IPU6EPMTL_CONFIG_DIR" ]]; then
  run sudo mkdir -p /etc/camera

  if [[ -f "$IPU6EPMTL_PROFILE_XML" ]]; then
    echo "WARNING: existing profile found: $IPU6EPMTL_PROFILE_XML"

    if $DRY_RUN; then
      echo "dry-run: would ask before copying $IPU6EPMTL_CONFIG_DIR and would back up the current profile to $IPU6EPMTL_PROFILE_BACKUP_XML"
    else
      read -r -p "Copy the full ipu6epmtl config and back up the current profile to $IPU6EPMTL_PROFILE_BACKUP_XML? [y/N] " answer
      case "$answer" in
        y|Y|yes|YES)
          backup_tmp="$(mktemp)"
          run sudo cp -f "$IPU6EPMTL_PROFILE_XML" "$backup_tmp"
          run sudo rm -rf "$IPU6EPMTL_TARGET_DIR"
          run sudo cp -r "$IPU6EPMTL_CONFIG_DIR" /etc/camera/
          run sudo cp -f "$backup_tmp" "$IPU6EPMTL_PROFILE_BACKUP_XML"
          rm -f "$backup_tmp"
          echo "Backed up the previous profile to $IPU6EPMTL_PROFILE_BACKUP_XML"
          ;;
        *)
          echo "Skip copying $IPU6EPMTL_CONFIG_DIR"
          ;;
      esac
    fi
  else
    run sudo rm -rf "$IPU6EPMTL_TARGET_DIR"
    run sudo cp -r "$IPU6EPMTL_CONFIG_DIR" /etc/camera/
  fi
fi
