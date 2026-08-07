#!/usr/bin/env bash
set -euo pipefail

MIN_VERSION="1.31"

get_media_ctl_version() {
  media-ctl --version 2>/dev/null | awk '/^media-ctl / {print $2; exit}'
}

has_apt_v4l_utils() {
  dpkg-query -W -f='${Status}\n' v4l-utils 2>/dev/null | grep -Fxq 'install ok installed'
}

if command -v media-ctl >/dev/null 2>&1; then
  CURRENT_VERSION="$(get_media_ctl_version || true)"

  if [ -z "$CURRENT_VERSION" ]; then
    echo "ERROR: media-ctl exists but media-ctl --version did not return a usable version."
    exit 1
  fi

  if dpkg --compare-versions "$CURRENT_VERSION" ge "$MIN_VERSION"; then
    echo "Current v4l-utils version is good: $CURRENT_VERSION"
    exit 0
  fi

  echo "The current installed v4l-utils is too old: $CURRENT_VERSION"
  if has_apt_v4l_utils; then
    read -r -p "Remove apt v4l-utils and build a newer one now? [y/N] " answer
    case "$answer" in
      y|Y|yes|YES)
        sudo -E apt remove -y v4l-utils
        ;;
      *)
        echo "ERROR: Please manually remove v4l-utils and run this script again."
        exit 1
        ;;
    esac
  else
    echo "An existing media-ctl binary was found, but v4l-utils is not installed by apt."
    read -r -p "Build v4l-utils from source and override the existing media-ctl binary? [y/N] " answer
    case "$answer" in
      y|Y|yes|YES)
        ;;
      *)
        echo "ERROR: Please handle the existing media-ctl binary manually and run this script again."
        exit 1
        ;;
    esac
  fi
fi

if [ -e v4l-utils ]; then
  echo "ERROR: ./v4l-utils already exists. Remove or rename it and run this script again."
  exit 1
fi

git clone https://git.linuxtv.org/v4l-utils.git/
cd v4l-utils

meson setup build/
ninja -C build/
sudo ninja -C build/ install

INSTALLED_VERSION="$(get_media_ctl_version || true)"

if [ -z "$INSTALLED_VERSION" ]; then
  echo "ERROR: media-ctl --version did not return a usable version after install."
  exit 1
fi

if dpkg --compare-versions "$INSTALLED_VERSION" ge "$MIN_VERSION"; then
  echo "Installed v4l-utils version is good: $INSTALLED_VERSION"
else
  echo "ERROR: Installed v4l-utils version is still too old: $INSTALLED_VERSION"
  exit 1
fi
