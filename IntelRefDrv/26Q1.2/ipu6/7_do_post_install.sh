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

chmod_other_rx_glob() {
  local pattern="$1"
  shopt -s nullglob
  local matches=($pattern)
  shopt -u nullglob

  if ((${#matches[@]} == 0)); then
    echo "ERROR: no matches for $pattern" >&2
    exit 1
  fi

  run sudo chmod o+rx "${matches[@]}"
}

run /bin/rm -rf "$HOME/.cache/gstreamer-1.0"
run sudo -E apt install -y yavta meson ninja-build graphviz

run sudo chmod o+rx /usr/lib/libcamhal
run sudo chmod o+rx /usr/lib/libcamhal/plugins/
chmod_other_rx_glob /usr/lib/libgsticamerainterface-1.0.so*
chmod_other_rx_glob /usr/lib/libgsticamerainterface-1.0.so.*
chmod_other_rx_glob /usr/lib/gstreamer-1.0/libgsticamerasrc.so*
run sudo chmod -R o+rx /etc/camera/

if [ ! -f /etc/udev/rules.d/99-ipu-psys.rules ]; then
  run sudo sh -c 'cat > /etc/udev/rules.d/99-ipu-psys.rules << "EOL"
KERNEL=="ipu-psys0", ACTION=="add", GROUP="video", MODE="0660"
EOL'
fi

if ! grep -Fxq 'options intel-ipu6 isys_freq_override=475' /etc/modprobe.d/ipu.conf 2>/dev/null; then
  run sudo sh -c 'mkdir -p /etc/modprobe.d && printf "%s\n" "options intel-ipu6 isys_freq_override=475" >> /etc/modprobe.d/ipu.conf'
fi

if ! grep -q "^export GST_PLUGIN_PATH=" /etc/profile 2>/dev/null; then
  run sudo sh -c 'cat >> /etc/profile << "EOL"
export LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri
export LIBVA_DRIVER_NAME=iHD
export LD_LIBRARY_PATH=/usr/lib:/usr/local/lib:/usr/lib64:/usr/lib/x86_64-linux-gnu
export GST_GL_PLATFORM=egl
export GST_GL_API=gles2
export GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0/
EOL'
fi

echo ""
echo ""
echo "post install done"
echo ""
echo "next: run ./8_do_post_build_v4l.sh"
echo "after that, reboot manually before ./9_post_check.sh"
