#!/usr/bin/env bash

#set -euo pipefail

ERROR_COUNT=0

pass() {
  echo "[PASS] $1"
}

fail() {
  echo "[FAIL] $1"
  ERROR_COUNT=$((ERROR_COUNT + 1))
}

has_other_rx() {
  local path="$1"
  local perm other
  perm="$(stat -c '%a' "$path")"
  other=$((perm % 10))
  (( (other & 4) != 0 && (other & 1) != 0 ))
}

check_exists() {
  local path="$1"
  local label="$2"
  if [[ -e "$path" ]]; then
    pass "$label exists: $path"
    return 0
  fi
  fail "$label missing: $path"
  return 1
}

check_exists "/usr/lib/libcamhal.so" "Installed camera HAL"
check_exists "/usr/lib/libcamhal/plugins/ipu75xa.so" "Installed camera HAL plugin"
check_exists "/etc/camera/ipu75xa/libcamhal_configs.json" "Installed camera HAL config"

check_exists "/usr/lib/gstreamer-1.0/libgsticamerasrc.so" "Installed icamerasrc plugin"


echo "=== 7_do_post_install.sh check ==="

for path in \
  "/usr/lib/libcamhal" \
  "/usr/lib/libcamhal/plugins"; do
  if check_exists "$path" "Post-install permission target"; then
    if has_other_rx "$path"; then
      pass "others have r+x permission: $path"
    else
      fail "others do not have r+x permission: $path"
    fi
  fi
done

for pattern in \
  "/usr/lib/libgsticamerainterface-1.0.so*" \
  "/usr/lib/gstreamer-1.0/libgsticamerasrc.so*"; do
  shopt -s nullglob
  matches=($pattern)
  shopt -u nullglob

  if ((${#matches[@]} == 0)); then
    fail "Post-install permission target missing: $pattern"
    continue
  fi

  for p in "${matches[@]}"; do
    if has_other_rx "$p"; then
      pass "others have r+x permission: $p"
    else
      fail "others do not have r+x permission: $p"
    fi
  done
done

if check_exists "/etc/camera" "Camera config directory"; then
  if has_other_rx "/etc/camera"; then
    pass "others have r+x permission: /etc/camera"
  else
    fail "others do not have r+x permission: /etc/camera"
  fi
fi

RULE_FILE="/etc/udev/rules.d/99-ipu-psys.rules"
if [[ -f "$RULE_FILE" ]]; then
  if grep -q 'GROUP="video"' "$RULE_FILE" && grep -q 'MODE="0660"' "$RULE_FILE"; then
    pass "Udev rule exists with expected video/mode settings"
  else
    fail "Udev rule exists but expected settings are missing: $RULE_FILE"
  fi
else
  fail "Udev rule missing: $RULE_FILE"
fi

PROFILE_FILE="/etc/profile"
for line in \
  'export LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri' \
  'export LIBVA_DRIVER_NAME=iHD' \
  'export LD_LIBRARY_PATH=/usr/lib:/usr/local/lib:/usr/lib64:/usr/lib/x86_64-linux-gnu' \
  'export GST_GL_PLATFORM=egl' \
  'export GST_GL_API=gles2' \
  'export GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0/'; do
  if grep -Fxq "$line" "$PROFILE_FILE"; then
    pass "Profile contains: $line"
  else
    fail "Missing profile export: $line"
  fi
done

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
echo "Validation summary: ${ERROR_COUNT} fail"
if ((ERROR_COUNT > 0)); then
  exit 1
fi
