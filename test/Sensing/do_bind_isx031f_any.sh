#!/bin/bash

set -euo pipefail

dry_run=0
if [[ "${1:-}" == "--dry" ]]; then
    dry_run=1
    shift
fi

if [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--dry]" >&2
    exit 1
fi

if (( dry_run == 0 )); then
    set -x
fi

mdev="$(v4l2-ctl --list-devices | awk '
    /^ipu7/ { in_ipu=1; next }
    in_ipu && /\/dev\/media/ {
        gsub(/^[[:space:]]+/, "", $0)
        print
        exit
    }
')"

if [[ -z "$mdev" ]]; then
    echo "No IPU7 media device found." >&2
    exit 1
fi

capdev_count="$(v4l2-ctl -d "$mdev" -A | wc -l)"
if (( capdev_count - 2 > 48 )); then
    capture_stride=16
else
    capture_stride=8
fi

run() {
    if (( dry_run )); then
        printf '%q' "$1"
        shift
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
    else
        "$@"
    fi
}

des_node() {
    case "$1" in
        0) echo "max9x a" ;;
        1) echo "max9x b" ;;
        2) echo "max9x c" ;;
        3) echo "max9x d" ;;
        4) echo "max9x e" ;;
        5) echo "max9x f" ;;
        *)
            echo "Unsupported port: $1" >&2
            exit 1
            ;;
    esac
}

fmt='[fmt:UYVY8_1X16/1920x1536]'
declare -A lane_index=([a]=0 [b]=1 [c]=2 [d]=3)

mapfile -t cameras < <(
    media-ctl -d "$mdev" -p |
    sed -n 's/.*: isx031f \([a-d]-[0-9]\+\) (.*/\1/p' |
    sort -u -t- -k2,2n -k1,1
)

if (( ${#cameras[@]} == 0 )); then
    echo "No isx031f cameras found on ${mdev}." >&2
    exit 1
fi

declare -A stream_count
declare -A des_routes
declare -A csi_routes
declare -A camera_stream
ports=()

for camera in "${cameras[@]}"; do
    lane="${camera%%-*}"
    port="${camera##*-}"
    index="${lane_index[$lane]}"
    stream="${stream_count[$port]:-0}"

    if [[ -z "${stream_count[$port]+x}" ]]; then
        ports+=("$port")
    fi

    if [[ -n "${des_routes[$port]:-}" ]]; then
        des_routes[$port]+=","
        csi_routes[$port]+=","
    fi

    des_routes[$port]+="$((index + 4))/${stream}->0/${stream}[1]"
    csi_routes[$port]+="0/${stream}->$((index + 1))/${stream}[1]"
    camera_stream[$camera]="$stream"
    stream_count[$port]=$((stream + 1))
done

for camera in "${cameras[@]}"; do
    lane="${camera%%-*}"
    port="${camera##*-}"
    index="${lane_index[$lane]}"
    capture_index=$((port * capture_stride + index))

    run media-ctl -d "$mdev" -l "\"$(des_node "$port")\":0 -> \"Intel IPU7 CSI2 ${port}\":0[1]"
    run media-ctl -d "$mdev" -l "\"Intel IPU7 CSI2 ${port}\":$((index + 1)) -> \"Intel IPU7 ISYS Capture ${capture_index}\":0[1]"
done

for port in "${ports[@]}"; do
    run media-ctl -d "$mdev" -R "\"$(des_node "$port")\"[${des_routes[$port]}]"
    run media-ctl -d "$mdev" -R "\"Intel IPU7 CSI2 ${port}\"[${csi_routes[$port]}]"
done

for camera in "${cameras[@]}"; do
    lane="${camera%%-*}"
    port="${camera##*-}"
    index="${lane_index[$lane]}"
    stream="${camera_stream[$camera]}"
    capture_index=$((port * capture_stride + index))
    video_node="/dev/video${capture_index}"
    alias_node="/dev/video-isx031f-${camera}"

    run media-ctl -d "$mdev" -R "\"max9x ${camera}\"[0/0->2/${stream}[1]]"
    run media-ctl -d "$mdev" -V "\"isx031f ${camera}\":0/0 ${fmt}"
    run media-ctl -d "$mdev" -V "\"max9x ${camera}\":0/0 ${fmt}"
    run media-ctl -d "$mdev" -V "\"max9x ${camera}\":2/${stream} ${fmt}"
    run media-ctl -d "$mdev" -V "\"$(des_node "$port")\":$((index + 4))/${stream} ${fmt}"
    run media-ctl -d "$mdev" -V "\"$(des_node "$port")\":0/${stream} ${fmt}"
    run media-ctl -d "$mdev" -V "\"Intel IPU7 CSI2 ${port}\":0/${stream} ${fmt}"
    run media-ctl -d "$mdev" -V "\"Intel IPU7 CSI2 ${port}\":$((index + 1))/${stream} ${fmt}"
    run v4l2-ctl -d "$video_node" --set-fmt-video=width=1920,height=1536,pixelformat=UYVY
    run sudo ln -sfn "$video_node" "$alias_node"
done

for port in "${ports[@]}"; do
    if (( stream_count[$port] > 1 )); then
        for ((stream = 0; stream < stream_count[$port]; stream++)); do
            run media-ctl -d "$mdev" -V "\"Intel IPU7 CSI2 ${port}\":0/${stream} ${fmt}"
        done
    fi
done
