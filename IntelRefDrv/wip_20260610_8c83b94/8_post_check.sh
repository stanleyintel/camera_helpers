#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_DIR="$(pwd)"
DRIVER_DIR="$CURRENT_DIR/Intel-MIPI-CSI-Camera-Reference-Driver"
REQUIRED_IASL_VERSION="20260408"

ERROR_COUNT=0
WARNING_COUNT=0

pass() {
  echo "[PASS] $1"
}

warn() {
  echo "[WARN] $1"
  WARNING_COUNT=$((WARNING_COUNT + 1))
}

fail() {
  echo "[FAIL] $1"
  ERROR_COUNT=$((ERROR_COUNT + 1))
}

get_iasl_version() {
  local version_out
  version_out="$(iasl --version 2>&1 || true)"
  grep -Eo 'version[[:space:]]+[0-9]{8}' <<<"$version_out" | awk '{print $2}' | head -n1
}

check_exists() {
  local path="$1"
  local label="$2"
  if sudo test -e "$path"; then
    pass "$label exists: $path"
    return 0
  fi
  fail "$label missing: $path"
  return 1
}

echo "=== 2_do_build_install_acpica.sh check ==="
if ! command -v iasl >/dev/null 2>&1; then
  fail "iasl is not in PATH"
else
  IASL_VERSION="$(get_iasl_version)"
  if [[ -z "$IASL_VERSION" ]]; then
    fail "Unable to parse iasl version from: iasl --version"
  elif ((10#$IASL_VERSION >= 10#$REQUIRED_IASL_VERSION)); then
    pass "iasl version is $IASL_VERSION (required: $REQUIRED_IASL_VERSION or newer)"
  else
    fail "iasl version is too old: $IASL_VERSION (required: $REQUIRED_IASL_VERSION or newer)"
  fi
fi

echo "=== 5_do_clone_dkms_driver.sh check ==="
PATCH_SRC="$SCRIPT_DIR/0002-media-ipu7-sync-acpi-csi2-config-abi.patch"
if [[ ! -d "$DRIVER_DIR/.git" ]]; then
  fail "Driver repo not found: $DRIVER_DIR"
else
  PATCH_CHECK_FILE="$PATCH_SRC"
  if [[ ! -f "$PATCH_CHECK_FILE" && -f "$DRIVER_DIR/0002-media-ipu7-sync-acpi-csi2-config-abi.patch" ]]; then
    PATCH_CHECK_FILE="$DRIVER_DIR/0002-media-ipu7-sync-acpi-csi2-config-abi.patch"
  fi

  if [[ ! -f "$PATCH_CHECK_FILE" ]]; then
    fail "Cannot check patch status: patch file not found"
  elif git -C "$DRIVER_DIR" apply --reverse --check "$PATCH_CHECK_FILE" >/dev/null 2>&1; then
    pass "DKMS patch is applied"
  else
    fail "DKMS patch is not applied"
  fi
fi

echo "=== 6_do_build_dkms.sh check ==="
if [[ ! -d "$DRIVER_DIR/.git" ]]; then
  fail "Driver repo not found for DKMS build context: $DRIVER_DIR"
fi

DKMS_STATUS="$(sudo dkms status -m ipu-camera-sensor -v 0.1 2>/dev/null || true)"
if grep -Eq 'ipu-camera-sensor/0\.1, .*: installed' <<<"$DKMS_STATUS"; then
  pass "DKMS driver is installed"
else
  fail "DKMS installed driver not found in dkms status (ipu-camera-sensor/0.1)"
fi

EXPECTED_MAX96717_PATH="/lib/modules/$(uname -r)/updates/dkms/max96717.ko"
MAX96717_FILENAME="$(modinfo -F filename max96717 2>/dev/null || true)"
if [[ -z "$MAX96717_FILENAME" ]]; then
  fail "modinfo max96717 did not return a filename"
elif [[ "$MAX96717_FILENAME" == "$EXPECTED_MAX96717_PATH" ]]; then
  pass "max96717 filename matches expected DKMS path: $MAX96717_FILENAME"
else
  fail "max96717 filename mismatch: expected $EXPECTED_MAX96717_PATH, got $MAX96717_FILENAME"
fi

echo "=== IPU FW check ==="

check_file_versions_from_strings() {
  local path="$1"
  local label="$2"
  shift 2

  if ! check_exists "$path" "$label"; then
    return
  fi

  local strings_out
  if ! strings_out="$(sudo strings -a "$path" 2>/dev/null)"; then
    fail "Unable to read strings from $label: $path"
    return
  fi

  local ver
  for ver in "$@"; do
    if grep -Fq "$ver" <<<"$strings_out"; then
      pass "$label contains version: $ver"
    else
      fail "$label missing version: $ver"
    fi
  done
}

check_file_versions_from_strings \
  "/usr/lib/firmware/intel/ipu/ipu7ptl_fw.bin" \
  "IPU firmware binary" \
  "1.2.1.260323214446" \
  "1.2.1.260323214441"

if dmesg_log="$(sudo dmesg 2>/dev/null)"; then
  for line in \
    'intel-ipu7 0000:00:05.0: firmware cpd file: intel/ipu/ipu7ptl_fw.bin' \
    'intel-ipu7 0000:00:05.0: Version:  1.2.1.260323214446' \
    'intel-ipu7 0000:00:05.0: Version:  1.2.1.260323214441'; do
    if grep -Fq "$line" <<<"$dmesg_log"; then
      pass "dmesg contains: $line"
    else
      fail "dmesg missing required line: $line"
    fi
  done
else
  fail "Unable to read dmesg with sudo"
fi

echo "=== Other packages check ==="

check_pkg_from_download_01() {
  local pkg="$1"
  if dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -Fxq 'install ok installed'; then
    pass "Package installed: $pkg"
  else
    fail "Package not installed: $pkg"
    return
  fi

  if apt-cache policy "$pkg" | grep -A4 '\*\*\*' | grep -q 'download\.01'; then
    pass "Package source is download.01: $pkg"
  else
    fail "Package source is not download.01: $pkg"
  fi
}

for pkg in libva2 intel-media-va-driver-non-free libigdgmm-dev; do
  check_pkg_from_download_01 "$pkg"
done

echo ""
echo "Validation summary: ${ERROR_COUNT} fail, ${WARNING_COUNT} warning"
if ((ERROR_COUNT > 0)); then
  exit 1
fi
