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

run media-ctl -d /dev/media0 -R "\"${remote_entity}\"[0/0->2/0[1]]"
run media-ctl -d /dev/media0 -R "\"${parent_entity}\"[${parent_sink_pad}/0->0/0[1]]"
run media-ctl -d /dev/media0 -R "\"${csi_entity}\"[0/0->${csi_source_pad}/0[1]]"

run media-ctl -d /dev/media0 -V "\"${sensor_entity}\":0/0 [fmt:UYVY8_1X16/1920x1536]"
run media-ctl -d /dev/media0 -V "\"${remote_entity}\":0/0 [fmt:UYVY8_1X16/1920x1536]"
run media-ctl -d /dev/media0 -V "\"${remote_entity}\":2/0 [fmt:UYVY8_1X16/1920x1536]"
run media-ctl -d /dev/media0 -V "\"${parent_entity}\":${parent_sink_pad}/0 [fmt:UYVY8_1X16/1920x1536]"
run media-ctl -d /dev/media0 -V "\"${parent_entity}\":0/0 [fmt:UYVY8_1X16/1920x1536]"
run media-ctl -d /dev/media0 -V "\"${csi_entity}\":0/0 [fmt:UYVY8_1X16/1920x1536]"
run media-ctl -d /dev/media0 -V "\"${csi_entity}\":${csi_source_pad}/0 [fmt:UYVY8_1X16/1920x1536]"

run media-ctl -d /dev/media0 -l "\"${csi_entity}\":${csi_source_pad} -> \"${capture_entity}\":0[1]"

run v4l2-ctl -d "$video_alias" --set-fmt-video=width=1920,height=1536,pixelformat=UYVY
