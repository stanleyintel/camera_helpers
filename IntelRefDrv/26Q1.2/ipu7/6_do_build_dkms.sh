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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
DRIVER_DIR="$WORK_DIR/Intel-MIPI-CSI-Camera-Reference-Driver"

if [[ ! -d "$DRIVER_DIR/.git" ]]; then
  echo "ERROR: driver repo not found: $DRIVER_DIR" >&2
  echo "please run $SCRIPT_DIR/5_do_clone_dkms_driver.sh first from this same working directory" >&2
  exit 1
fi

enter_dir "$DRIVER_DIR"
KERNEL_RELEASE="$(uname -r)"

echo ""
echo ""
echo "clean previous build"
run sudo dkms uninstall ipu-camera-sensor/0.1 || true
run sudo dkms remove ipu-camera-sensor/0.1 || true
run sudo /bin/rm -rf /usr/src/ipu-camera-sensor-0.1
run sudo /bin/rm -rf /var/lib/dkms/ipu-camera-sensor

echo ""
echo ""
echo "start build"
run sudo -E dkms add .
run sudo -E dkms build -m ipu-camera-sensor -v 0.1
run sudo -E dkms install -m ipu-camera-sensor -v 0.1 --force

echo ""
echo ""
echo "finish"

if $DRY_RUN; then
  run sudo dkms status -m ipu-camera-sensor -v 0.1
  echo "dry-run: skipped dkms build/install verification"
  exit 0
fi

DKMS_STATUS="$(sudo dkms status -m ipu-camera-sensor -v 0.1 || true)"
echo "$DKMS_STATUS"

if ! grep -Eq "ipu-camera-sensor/0\.1, ${KERNEL_RELEASE}.*: installed" <<<"$DKMS_STATUS"; then
  echo "ERROR: dkms build/install verification failed for kernel ${KERNEL_RELEASE}" >&2
  exit 1
fi

echo "dkms build/install verified for kernel ${KERNEL_RELEASE}"
