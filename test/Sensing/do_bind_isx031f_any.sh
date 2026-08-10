#!/bin/sh

set -eu

dry_run=0
if [ "${1:-}" = "--dry" ]; then
    dry_run=1
    shift
fi

if [ "$dry_run" -eq 0 ]; then
    set -x
fi

v4l2_version_line="$(v4l2-ctl --version | sed -n '1p')"
v4l2_version="$(echo "$v4l2_version_line" | sed -n 's/^v4l2-ctl \([0-9][0-9.]*\).*/\1/p')"
v4l2_major="$(echo "$v4l2_version" | cut -d. -f1)"
v4l2_minor="$(echo "$v4l2_version" | cut -d. -f2)"

if [ -z "$v4l2_version" ] || [ -z "$v4l2_major" ] || [ -z "$v4l2_minor" ]; then
    echo "Failed to parse 'v4l2-ctl --version'. Please upgrade v4l-utils." >&2
    exit 1
fi

if [ "$v4l2_major" -lt 1 ] || { [ "$v4l2_major" -eq 1 ] && [ "$v4l2_minor" -lt 32 ]; }; then
    echo "v4l2-ctl version ${v4l2_version} is too old. Please upgrade v4l-utils to 1.32 or newer." >&2
    exit 1
fi

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 [--dry] <a|b|c|d> <0|2>" >&2
    exit 1
fi

lane="$1"
port="$2"

case "$lane" in
    a)
        parent_sink_pad=4
        csi_source_pad=1
        capture_index_0=0
        capture_index_2=16
        ;;
    b)
        parent_sink_pad=5
        csi_source_pad=2
        capture_index_0=1
        capture_index_2=17
        ;;
    c)
        parent_sink_pad=6
        csi_source_pad=3
        capture_index_0=2
        capture_index_2=18
        ;;
    d)
        parent_sink_pad=7
        csi_source_pad=4
        capture_index_0=3
        capture_index_2=19
        ;;
    *)
        echo "Invalid lane: $lane" >&2
        echo "Usage: $0 [--dry] <a|b|c|d> <0|2>" >&2
        exit 1
        ;;
esac

lane_from_parent_pad() {
    case "$1" in
        4) echo a ;;
        5) echo b ;;
        6) echo c ;;
        7) echo d ;;
    esac
}

lane_parent_sink_pad() {
    case "$1" in
        a) echo 4 ;;
        b) echo 5 ;;
        c) echo 6 ;;
        d) echo 7 ;;
    esac
}

lane_csi_source_pad() {
    case "$1" in
        a) echo 1 ;;
        b) echo 2 ;;
        c) echo 3 ;;
        d) echo 4 ;;
    esac
}

lane_capture_index() {
    lane_name="$1"
    port_name="$2"

    case "${port_name}:${lane_name}" in
        0:a) echo 0 ;;
        0:b) echo 1 ;;
        0:c) echo 2 ;;
        0:d) echo 3 ;;
        2:a) echo 16 ;;
        2:b) echo 17 ;;
        2:c) echo 18 ;;
        2:d) echo 19 ;;
    esac
}

append_lane() {
    lane_name="$1"
    [ -n "$lane_name" ] || return 0

    for existing_lane in $selected_lanes; do
        if [ "$existing_lane" = "$lane_name" ]; then
            return 0
        fi
    done

    if [ -n "$selected_lanes" ]; then
        selected_lanes="$selected_lanes $lane_name"
    else
        selected_lanes="$lane_name"
    fi
}

active_parent_pads() {
    media-ctl -d /dev/media0 -p | awk -v entity="$1" '
        /^- entity [0-9]+: / {
            if (in_entity) {
                exit
            }

            line=$0
            sub(/^- entity [0-9]+: /, "", line)
            name=line
            sub(/ \(.*$/, "", name)
            if (name == entity) {
                in_entity=1
                next
            }
        }
        in_entity && /^[[:space:]]*routes:/ { in_routes=1; next }
        in_entity && in_routes && /^[[:space:]]*pad[0-9]+:/ { exit }
        in_entity && in_routes && /\[ACTIVE\]/ {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            split(line, parts, "/")
            print parts[1]
        }
    '
}

case "$port" in
    0)
        sensor_entity="isx031f ${lane}-0"
        remote_entity="max9x ${lane}-0"
        parent_entity="max9x a"
        csi_entity="Intel IPU7 CSI2 0"
        capture_index="$capture_index_0"
        ;;
    2)
        sensor_entity="isx031f ${lane}-2"
        remote_entity="max9x ${lane}-2"
        parent_entity="max9x c"
        csi_entity="Intel IPU7 CSI2 2"
        capture_index="$capture_index_2"
        ;;
    *)
        echo "Invalid port: $port" >&2
        echo "Usage: $0 [--dry] <a|b|c|d> <0|2>" >&2
        exit 1
        ;;
esac

capture_entity="Intel IPU7 ISYS Capture ${capture_index}"
video_node="/dev/video${capture_index}"
video_alias="/dev/video-isx031f-${lane}-${port}"

# Mapping derived from:
#   config/ipu75xa/sensors/isx031f-{1..8}.json
# where:
#   a/b/c/d on port 0 -> isx031f-{1,2,3,4}
#   a/b/c/d on port 2 -> isx031f-{5,6,7,8}
#
# This script only programs the selected path:
#   isx031f <lane>-<port> -> max9x <lane>-<port> -> max9x <a|c>
#   -> Intel IPU7 CSI2 <0|2> -> Intel IPU7 ISYS Capture <N>

run() {
    if [ "$dry_run" -eq 1 ]; then
        printf '%s\n' "$*"
    else
        "$@"
    fi
}

selected_lanes=""
for active_parent_pad in $(active_parent_pads "$parent_entity"); do
    append_lane "$(lane_from_parent_pad "$active_parent_pad")"
done
append_lane "$lane"

parent_routes=""
csi_routes=""
stream_id=0
for configured_lane in a b c d; do
    lane_selected=0
    for selected_lane in $selected_lanes; do
        if [ "$selected_lane" = "$configured_lane" ]; then
            lane_selected=1
            break
        fi
    done

    if [ "$lane_selected" -ne 1 ]; then
        continue
    fi

    configured_sensor_entity="isx031f ${configured_lane}-${port}"
    configured_remote_entity="max9x ${configured_lane}-${port}"
    configured_parent_sink_pad="$(lane_parent_sink_pad "$configured_lane")"
    configured_csi_source_pad="$(lane_csi_source_pad "$configured_lane")"
    configured_capture_index="$(lane_capture_index "$configured_lane" "$port")"
    configured_capture_entity="Intel IPU7 ISYS Capture ${configured_capture_index}"

    if [ -n "$parent_routes" ]; then
        parent_routes="${parent_routes},"
        csi_routes="${csi_routes},"
    fi
    parent_routes="${parent_routes}${configured_parent_sink_pad}/${stream_id}->0/${stream_id}[1]"
    csi_routes="${csi_routes}0/${stream_id}->${configured_csi_source_pad}/${stream_id}[1]"

    stream_id=$((stream_id + 1))
done

run media-ctl -d /dev/media0 -R "\"${parent_entity}\"[${parent_routes}]"
run media-ctl -d /dev/media0 -R "\"${csi_entity}\"[${csi_routes}]"

stream_id=0
for configured_lane in a b c d; do
    lane_selected=0
    for selected_lane in $selected_lanes; do
        if [ "$selected_lane" = "$configured_lane" ]; then
            lane_selected=1
            break
        fi
    done

    if [ "$lane_selected" -ne 1 ]; then
        continue
    fi

    configured_sensor_entity="isx031f ${configured_lane}-${port}"
    configured_remote_entity="max9x ${configured_lane}-${port}"
    configured_parent_sink_pad="$(lane_parent_sink_pad "$configured_lane")"
    configured_csi_source_pad="$(lane_csi_source_pad "$configured_lane")"
    configured_capture_index="$(lane_capture_index "$configured_lane" "$port")"
    configured_capture_entity="Intel IPU7 ISYS Capture ${configured_capture_index}"

    run media-ctl -d /dev/media0 -R "\"${configured_remote_entity}\"[0/0->2/${stream_id}[1]]"

    run media-ctl -d /dev/media0 -V "\"${configured_sensor_entity}\":0/0 [fmt:UYVY8_1X16/1920x1536]"
    run media-ctl -d /dev/media0 -V "\"${configured_remote_entity}\":0/0 [fmt:UYVY8_1X16/1920x1536]"
    run media-ctl -d /dev/media0 -V "\"${configured_remote_entity}\":2/${stream_id} [fmt:UYVY8_1X16/1920x1536]"
    run media-ctl -d /dev/media0 -V "\"${parent_entity}\":${configured_parent_sink_pad}/${stream_id} [fmt:UYVY8_1X16/1920x1536]"
    run media-ctl -d /dev/media0 -V "\"${parent_entity}\":0/${stream_id} [fmt:UYVY8_1X16/1920x1536]"
    run media-ctl -d /dev/media0 -V "\"${csi_entity}\":0/${stream_id} [fmt:UYVY8_1X16/1920x1536]"
    run media-ctl -d /dev/media0 -V "\"${csi_entity}\":${configured_csi_source_pad}/${stream_id} [fmt:UYVY8_1X16/1920x1536]"

    run media-ctl -d /dev/media0 -l "\"${csi_entity}\":${configured_csi_source_pad} -> \"${configured_capture_entity}\":0[1]"

    stream_id=$((stream_id + 1))
done

run v4l2-ctl -d "$video_node" --set-fmt-video=width=1920,height=1536,pixelformat=UYVY
run sudo ln -sfn "$video_node" "$video_alias"
