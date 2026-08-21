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

MIN_VERSION="1.31"

run() {
  printf ''
  printf '%q ' "$@"
  printf '\n'
  if ! $DRY_RUN; then
    "$@"
  fi
}

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
    if $DRY_RUN; then
      echo "dry-run: would prompt to remove apt v4l-utils before building a newer one"
      run sudo -E apt remove -y v4l-utils
    else
      read -r -p "Remove apt v4l-utils and build a newer one now? [y/N] " answer
      case "$answer" in
        y|Y|yes|YES)
          run sudo -E apt remove -y v4l-utils
          ;;
        *)
          echo "ERROR: Please manually remove v4l-utils and run this script again."
          exit 1
          ;;
      esac
    fi
  else
    echo "An existing media-ctl binary was found, but v4l-utils is not installed by apt."
    if $DRY_RUN; then
      echo "dry-run: would prompt to build v4l-utils from source and override the existing media-ctl binary"
    else
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
fi

if [ -e v4l-utils ]; then
  echo "ERROR: ./v4l-utils already exists. Remove or rename it and run this script again."
  exit 1
fi

run git clone https://git.linuxtv.org/v4l-utils.git/
if ! $DRY_RUN; then
  cd v4l-utils
else
  echo "cd v4l-utils"
fi

run meson setup build/
run ninja -C build/
run sudo ninja -C build/ install

if $DRY_RUN; then
  echo "dry-run: skipped post-install media-ctl version verification"
  exit 0
fi

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
