#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <a|b|c|d> <0|2>" >&2
    exit 1
fi

lane="$1"
port="$2"

case "$lane" in
    a)
        capture_index_0=0
        capture_index_2=16
        ;;
    b)
        capture_index_0=1
        capture_index_2=17
        ;;
    c)
        capture_index_0=2
        capture_index_2=18
        ;;
    d)
        capture_index_0=3
        capture_index_2=19
        ;;
    *)
        echo "Invalid lane: $lane" >&2
        echo "Usage: $0 <a|b|c|d> <0|2>" >&2
        exit 1
        ;;
esac

case "$port" in
    0)
        capture_index="$capture_index_0"
        ;;
    2)
        capture_index="$capture_index_2"
        ;;
    *)
        echo "Invalid port: $port" >&2
        echo "Usage: $0 <a|b|c|d> <0|2>" >&2
        exit 1
        ;;
esac

exec ffplay -f v4l2 -input_format uyvy422 -video_size 1920x1536 -framerate 30 "/dev/video${capture_index}"
