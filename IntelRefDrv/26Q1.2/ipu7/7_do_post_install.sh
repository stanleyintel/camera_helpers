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

run sudo -E apt install -y v4l-utils

run sudo chmod o+rx /usr/lib/libcamhal
run sudo chmod o+rx /usr/lib/libcamhal/plugins/
run sudo chmod o+rx /usr/lib/libgsticamerainterface-1.0.so*
run sudo chmod o+rx /usr/lib/gstreamer-1.0/libgsticamerasrc.so*
run sudo chmod -R o+rx /etc/camera/


if [ ! -f /etc/udev/rules.d/99-ipu-psys.rules ]; then
  run sudo sh -c 'cat > /etc/udev/rules.d/99-ipu-psys.rules << "EOL"
KERNEL=="ipu7-psys0", GROUP="video", MODE="0660"
EOL'
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
echo "reboot system in 1 min."
echo "ctrl-c if you want to reboot by yourself later"

run sleep 60

run sudo reboot
