#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_ROOT="/tmp/a"
DRIVER_DIR="$SCRIPT_DIR/Intel-MIPI-CSI-Camera-Reference-Driver"
PATCH_SRC="$SCRIPT_DIR/ipu-fix-colorimetry.patch"

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

is_elf_file() {
  local path="$1"
  file -b "$path" 2>/dev/null | grep -q 'ELF'
}

elf_header_signature() {
  local path="$1"
  readelf -h "$path" 2>/dev/null | awk -F: '
    /Class:/ || /Data:/ || /Machine:/ {
      gsub(/^[ \t]+/, "", $2);
      print $1 ":" $2
    }' | sort
}

elf_needed_signature() {
  local path="$1"
  readelf -d "$path" 2>/dev/null | awk '
    /\(NEEDED\)/ {
      gsub(/\[/, "", $NF);
      gsub(/\]/, "", $NF);
      print $NF
    }' | sort -u
}

elf_soname() {
  local path="$1"
  readelf -d "$path" 2>/dev/null | awk '
    /\(SONAME\)/ {
      gsub(/\[/, "", $NF);
      gsub(/\]/, "", $NF);
      print $NF
      exit
    }'
}

elf_exported_symbols_signature() {
  local path="$1"
  nm -D --defined-only "$path" 2>/dev/null | awk '{print $3}' | sort -u
}

check_same_file_warn() {
  local installed="$1"
  local built="$2"
  local label="$3"
  if [[ ! -f "$built" ]]; then
    warn "$label built reference not found: $built"
    return
  fi
  if [[ ! -f "$installed" ]]; then
    warn "$label installed file not found for compare: $installed"
    return
  fi

  if is_elf_file "$installed" && is_elf_file "$built"; then
    local hdr_i hdr_b need_i need_b soname_i soname_b sym_i sym_b
    hdr_i="$(elf_header_signature "$installed")"
    hdr_b="$(elf_header_signature "$built")"
    need_i="$(elf_needed_signature "$installed")"
    need_b="$(elf_needed_signature "$built")"
    soname_i="$(elf_soname "$installed")"
    soname_b="$(elf_soname "$built")"
    sym_i="$(elf_exported_symbols_signature "$installed")"
    sym_b="$(elf_exported_symbols_signature "$built")"

    if [[ "$hdr_i" == "$hdr_b" && "$need_i" == "$need_b" && "$soname_i" == "$soname_b" && "$sym_i" == "$sym_b" ]]; then
      pass "$label is compatible with built output"
    else
      warn "$label differs from built output ABI/signature: $installed vs $built"
    fi
    return
  fi

  if cmp -s "$installed" "$built"; then
    pass "$label matches built output"
  else
    warn "$label does not match built output: $installed vs $built"
  fi
}

echo "=== 2_do_install_camera_bins.sh check ==="
BINS_REF="$REF_ROOT/ipu7-camera-bins"
if [[ ! -d "$BINS_REF" ]]; then
  fail "Reference tree missing: $BINS_REF"
else
  missing_bins=0

  while IFS= read -r src; do
    dst="/usr/lib/$(basename "$src")"
    if [[ ! -e "$dst" ]]; then
      fail "Missing runtime lib from camera-bins: $dst"
      missing_bins=1
    fi
  done < <(find "$BINS_REF"/lib "$BINS_REF"/lib/* -maxdepth 1 -type f -name 'lib*' 2>/dev/null | grep -Ev '/pkgconfig/|/firmware/' | sort -u || true)

  while IFS= read -r src; do
    dst="/lib/firmware/intel/ipu/$(basename "$src")"
    if [[ ! -e "$dst" ]]; then
      fail "Missing firmware from camera-bins: $dst"
      missing_bins=1
    fi
  done < <(find "$BINS_REF"/lib/firmware/intel "$BINS_REF"/lib/firmware/intel/ipu -maxdepth 1 -type f -name '*.bin' 2>/dev/null | sort -u || true)

  while IFS= read -r src; do
    dst="/usr/lib/pkgconfig/$(basename "$src")"
    if [[ ! -e "$dst" ]]; then
      fail "Missing pkgconfig from camera-bins: $dst"
      missing_bins=1
    fi
  done < <(find "$BINS_REF"/lib/pkgconfig "$BINS_REF"/lib/*/pkgconfig -maxdepth 1 -type f 2>/dev/null | sort -u || true)

  while IFS= read -r src; do
    rel="${src#"$BINS_REF"/include/}"
    dst="/usr/include/$rel"
    if [[ ! -e "$dst" ]]; then
      fail "Missing header from camera-bins: $dst"
      missing_bins=1
    fi
  done < <(find "$BINS_REF"/include -type f 2>/dev/null | sort || true)

  if [[ "$missing_bins" -eq 0 ]]; then
    pass "camera-bins files look installed"
  fi
fi

echo "=== 3_do_build_camera_hal.sh check ==="
HAL_REF="$REF_ROOT/ipu7-camera-hal"
if [[ ! -d "$HAL_REF" ]]; then
  warn "Reference tree not found (cannot compare built outputs): $HAL_REF"
fi

check_exists "/usr/lib/libcamhal.so" "Installed camera HAL"
check_exists "/usr/lib/libcamhal/plugins/ipu75xa.so" "Installed camera HAL plugin"
check_exists "/etc/camera/ipu75xa/libcamhal_configs.json" "Installed camera HAL config"

if [[ -d "$HAL_REF" ]]; then
  check_same_file_warn "/usr/lib/libcamhal.so" "$HAL_REF/build/src/hal/hal_adaptor/libcamhal.so.0.0.0" "libcamhal.so"
  check_same_file_warn "/usr/lib/libcamhal/plugins/ipu75xa.so" "$HAL_REF/build/ipu75xa.so" "ipu75xa.so"
  check_same_file_warn "/etc/camera/ipu75xa/libcamhal_configs.json" "$HAL_REF/config/linux/ipu75xa/libcamhal_configs.json" "libcamhal_configs.json"
fi

echo "=== 4_do_build_icamerasrc.sh check ==="
ICAM_REF="$REF_ROOT/icamerasrc"
if [[ ! -d "$ICAM_REF" ]]; then
  warn "Reference tree not found (cannot compare built outputs): $ICAM_REF"
fi

check_exists "/usr/lib/gstreamer-1.0/libgsticamerasrc.so" "Installed icamerasrc plugin"

if [[ -d "$ICAM_REF" ]]; then
  check_same_file_warn "/usr/lib/gstreamer-1.0/libgsticamerasrc.so" "$ICAM_REF/src/.libs/libgsticamerasrc.so" "libgsticamerasrc.so"
fi

echo "=== 5_do_clone_dkms_driver.sh check ==="
if [[ ! -d "$DRIVER_DIR/.git" ]]; then
  warn "Driver repo not found: $DRIVER_DIR"
else
  PATCH_CHECK_FILE="$PATCH_SRC"
  if [[ ! -f "$PATCH_CHECK_FILE" && -f "$DRIVER_DIR/ipu-fix-colorimetry.patch" ]]; then
    PATCH_CHECK_FILE="$DRIVER_DIR/ipu-fix-colorimetry.patch"
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
  warn "Driver repo not found for DKMS build context: $DRIVER_DIR"
fi

DKMS_STATUS="$(sudo dkms status -m ipu-camera-sensor -v 0.1 2>/dev/null || true)"
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

echo ""
echo "Validation summary: ${ERROR_COUNT} fail, ${WARNING_COUNT} warning"
if ((ERROR_COUNT > 0)); then
  exit 1
fi
