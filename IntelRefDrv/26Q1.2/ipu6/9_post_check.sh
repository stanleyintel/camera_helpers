#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_DIR="$WORK_DIR/Intel-MIPI-CSI-Camera-Reference-Driver"
PATCH_SRCS=(
  "$SCRIPT_DIR/0001-ipu-fix-colorimetry.patch"
  "$SCRIPT_DIR/0002-dkms-reuse-kernel-tarball.patch"
)
CAMERA_BINS_DIR="$WORK_DIR/ipu6-camera-bins"
HAL_DIR="$WORK_DIR/ipu6-camera-hal"
ICAMERASRC_DIR="$WORK_DIR/icamerasrc"

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

check_min_version() {
  local actual="$1"
  local minimum="$2"
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

has_other_rx() {
  local path="$1"
  local perm other
  perm="$(sudo stat -c '%a' "$path")"
  other=$((perm % 10))
  (( (other & 4) != 0 && (other & 1) != 0 ))
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

check_glob_exists() {
  local pattern="$1"
  local label="$2"
  shopt -s nullglob
  local matches=($pattern)
  shopt -u nullglob
  if ((${#matches[@]} > 0)); then
    pass "$label exists: $pattern"
    return 0
  fi
  fail "$label missing: $pattern"
  return 1
}

check_regular_files_under() {
  local src_root="$1"
  local dst_root="$2"
  local label="$3"

  if [[ ! -d "$src_root" ]]; then
    warn "$label source tree missing: $src_root"
    return
  fi

  local missing=0
  while IFS= read -r src; do
    local rel dst
    rel="${src#"$src_root"/}"
    dst="$dst_root/$rel"
    if sudo test -e "$dst"; then
      pass "$label installed: $dst"
    else
      fail "$label missing: $dst"
      missing=1
    fi
  done < <(find "$src_root" -type f | sort)

  if [[ "$missing" -eq 0 ]]; then
    pass "$label files look installed"
  fi
}

detect_hal_install_dir() {
  local candidate
  for candidate in \
    "$WORK_DIR/out/ipu_mtl/install" \
    "$WORK_DIR/out/ipu_adl/install" \
    "$WORK_DIR/out/ipu_tgl/install"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

echo "=== 2_do_install_camera_bins.sh check ==="

if [[ ! -d "$CAMERA_BINS_DIR" ]]; then
  warn "camera-bins source tree missing: $CAMERA_BINS_DIR"
else
  missing_bins=0

  while IFS= read -r src; do
    dst="/usr/lib/$(basename "$src")"
    if sudo test -e "$dst"; then
      pass "camera-bins runtime lib installed: $dst"
    else
      fail "camera-bins runtime lib missing: $dst"
      missing_bins=1
    fi
  done < <(find "$CAMERA_BINS_DIR"/lib "$CAMERA_BINS_DIR"/lib/* -maxdepth 1 -type f -name 'lib*' 2>/dev/null | grep -Ev '/pkgconfig/|/firmware/' | sort -u || true)

  while IFS= read -r src; do
    dst="/lib/firmware/intel/ipu/$(basename "$src")"
    if sudo test -e "$dst"; then
      pass "camera-bins firmware installed: $dst"
    else
      fail "camera-bins firmware missing: $dst"
      missing_bins=1
    fi
  done < <(find "$CAMERA_BINS_DIR"/lib/firmware/intel "$CAMERA_BINS_DIR"/lib/firmware/intel/ipu -maxdepth 1 -type f -name '*.bin' 2>/dev/null | sort -u || true)

  while IFS= read -r src; do
    dst="/usr/lib/pkgconfig/$(basename "$src")"
    if sudo test -e "$dst"; then
      pass "camera-bins pkgconfig installed: $dst"
    else
      fail "camera-bins pkgconfig missing: $dst"
      missing_bins=1
    fi
  done < <(find "$CAMERA_BINS_DIR"/lib/pkgconfig "$CAMERA_BINS_DIR"/lib/*/pkgconfig -maxdepth 1 -type f 2>/dev/null | sort -u || true)

  while IFS= read -r src; do
    rel="${src#"$CAMERA_BINS_DIR"/include/}"
    dst="/usr/include/$rel"
    if sudo test -e "$dst"; then
      pass "camera-bins header installed: $dst"
    else
      fail "camera-bins header missing: $dst"
      missing_bins=1
    fi
  done < <(find "$CAMERA_BINS_DIR"/include -type f 2>/dev/null | sort || true)

  if [[ "$missing_bins" -eq 0 ]]; then
    pass "camera-bins files look installed"
  fi
fi

echo "=== 3_do_build_camera_hal.sh check ==="

HAL_INSTALL_DIR="$(detect_hal_install_dir || true)"
if [[ -n "$HAL_INSTALL_DIR" ]]; then
  check_regular_files_under "$HAL_INSTALL_DIR/etc" "/etc" "camera-hal config"
  check_regular_files_under "$HAL_INSTALL_DIR/usr/include" "/usr/include" "camera-hal header"
  check_regular_files_under "$HAL_INSTALL_DIR/usr/lib" "/usr/lib" "camera-hal lib"
else
  warn "camera-hal install tree not found under $WORK_DIR/out"
fi

check_glob_exists "/usr/lib/libcamhal.so*" "Installed camera HAL library"
check_glob_exists "/usr/lib/libcamhal/plugins/*.so" "Installed camera HAL plugin"

check_exists "/etc/camera/ipu6epmtl/libcamhal_profile.xml" "Installed ipu6epmtl camera HAL profile"

echo "=== 4_do_build_icamerasrc.sh check ==="
check_exists "/usr/lib/gstreamer-1.0/libgsticamerasrc.so" "Installed icamerasrc plugin"

if [[ -f "$ICAMERASRC_DIR/src/.libs/libgsticamerasrc.so" ]]; then
  if cmp -s /usr/lib/gstreamer-1.0/libgsticamerasrc.so "$ICAMERASRC_DIR/src/.libs/libgsticamerasrc.so"; then
    pass "Installed icamerasrc plugin matches local build output"
  else
    warn "Installed icamerasrc plugin differs from local build output"
  fi
else
  warn "Local icamerasrc build output not found: $ICAMERASRC_DIR/src/.libs/libgsticamerasrc.so"
fi

echo "=== 5_do_clone_dkms_driver.sh check ==="
if [[ ! -d "$DRIVER_DIR/.git" ]]; then
  warn "Driver repo not found: $DRIVER_DIR"
else
  for patch_src in "${PATCH_SRCS[@]}"; do
    PATCH_CHECK_FILE="$patch_src"
    if [[ ! -f "$PATCH_CHECK_FILE" && -f "$DRIVER_DIR/$(basename "$patch_src")" ]]; then
      PATCH_CHECK_FILE="$DRIVER_DIR/$(basename "$patch_src")"
    fi

    if [[ ! -f "$PATCH_CHECK_FILE" ]]; then
      fail "Cannot check patch status: patch file not found: $(basename "$patch_src")"
    elif git -C "$DRIVER_DIR" apply --reverse --check "$PATCH_CHECK_FILE" >/dev/null 2>&1; then
      pass "DKMS patch is applied: $(basename "$patch_src")"
    else
      fail "DKMS patch is not applied: $(basename "$patch_src")"
    fi
  done
fi

echo "=== 6_do_build_dkms.sh check ==="
DKMS_STATUS="$(sudo -E dkms status -m ipu-camera-sensor -v 0.1 2>/dev/null || true)"
if grep -Eq 'ipu-camera-sensor/0\.1, .*: installed' <<<"$DKMS_STATUS"; then
  pass "DKMS driver is installed"
else
  fail "DKMS installed driver not found in dkms status (ipu-camera-sensor/0.1)"
fi

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
  if grep -Fq 'KERNEL=="ipu-psys0"' "$RULE_FILE" && grep -Fq 'GROUP="video"' "$RULE_FILE" && grep -Fq 'MODE="0660"' "$RULE_FILE"; then
    pass "Udev rule exists with expected ipu-psys0 settings"
  else
    fail "Udev rule exists but expected ipu-psys0 settings are missing: $RULE_FILE"
  fi
else
  fail "Udev rule missing: $RULE_FILE"
fi

if grep -Fxq 'options intel-ipu6 isys_freq_override=475' /etc/modprobe.d/ipu.conf 2>/dev/null; then
  pass "IPU6 isys frequency override is configured"
else
  warn "IPU6 isys frequency override is missing from /etc/modprobe.d/ipu.conf"
fi

echo "=== dmesg firmware check ==="
DMESG_LOG="$(dmesg 2>/dev/null || true)"
if [[ -z "$DMESG_LOG" ]]; then
  DMESG_LOG="$(sudo dmesg 2>/dev/null || true)"
fi

if [[ -z "$DMESG_LOG" ]]; then
  fail "Unable to read dmesg"
elif grep -Fq 'FW version: 20250213' <<<"$DMESG_LOG"; then
  pass "dmesg contains expected firmware version: FW version: 20250213"
else
  fail "dmesg missing expected firmware version: FW version: 20250213"
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

echo "=== 8_do_post_build_v4l.sh check ==="
MEDIA_CTL_VERSION="$(media-ctl --version 2>/dev/null | awk '/^media-ctl / {print $2; exit}')"
if [[ -z "$MEDIA_CTL_VERSION" ]]; then
  fail "Unable to get media-ctl version"
elif check_min_version "$MEDIA_CTL_VERSION" "1.31"; then
  pass "media-ctl version is new enough: $MEDIA_CTL_VERSION"
else
  fail "media-ctl version is too old: $MEDIA_CTL_VERSION (need >= 1.31)"
fi

echo "=== Required packages check ==="
for pkg in dkms yavta meson ninja-build graphviz; do
  if dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -Fxq 'install ok installed'; then
    pass "Package installed: $pkg"
  else
    fail "Package not installed: $pkg"
  fi
done

echo ""
echo "Validation summary: ${ERROR_COUNT} fail, ${WARNING_COUNT} warning"
if ((ERROR_COUNT > 0)); then
  exit 1
fi
