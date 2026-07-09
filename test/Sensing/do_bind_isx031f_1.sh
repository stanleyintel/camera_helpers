#!/bin/sh

set -eux

MEDIA_CTL=${MEDIA_CTL:-/usr/local/bin/media-ctl}
V4L2_CTL=${V4L2_CTL:-/usr/local/bin/v4l2-ctl}
MEDIA_DEV=${MEDIA_DEV:-/dev/media0}
VIDEO_NODE=${VIDEO_NODE:-/dev/video0}

"$MEDIA_CTL" -d "$MEDIA_DEV" -R '"max9x a-0"[0/0->2/0[1]]'
"$MEDIA_CTL" -d "$MEDIA_DEV" -R '"max9x a"[4/0->0/0[1]]'
"$MEDIA_CTL" -d "$MEDIA_DEV" -R '"Intel IPU7 CSI2 0"[0/0->1/0[1]]'

"$MEDIA_CTL" -d "$MEDIA_DEV" -V '"isx031f a-0":0/0 [fmt:UYVY8_1X16/1920x1536]'
"$MEDIA_CTL" -d "$MEDIA_DEV" -V '"max9x a-0":0/0 [fmt:UYVY8_1X16/1920x1536]'
"$MEDIA_CTL" -d "$MEDIA_DEV" -V '"max9x a-0":2/0 [fmt:UYVY8_1X16/1920x1536]'
"$MEDIA_CTL" -d "$MEDIA_DEV" -V '"max9x a":4/0 [fmt:UYVY8_1X16/1920x1536]'
"$MEDIA_CTL" -d "$MEDIA_DEV" -V '"max9x a":0/0 [fmt:UYVY8_1X16/1920x1536]'
"$MEDIA_CTL" -d "$MEDIA_DEV" -V '"Intel IPU7 CSI2 0":0/0 [fmt:UYVY8_1X16/1920x1536]'
"$MEDIA_CTL" -d "$MEDIA_DEV" -V '"Intel IPU7 CSI2 0":1/0 [fmt:UYVY8_1X16/1920x1536]'

"$MEDIA_CTL" -d "$MEDIA_DEV" -l '"Intel IPU7 CSI2 0":1 -> "Intel IPU7 ISYS Capture 0":0[1]'

"$V4L2_CTL" -d "$VIDEO_NODE" --set-fmt-video=width=1920,height=1536,pixelformat=UYVY

# Test commands:
## yavvta
#  yavta -c10 -f UYVY /dev/video0

## v4l2src
#  gst-launch-1.0 -e -v v4l2src device=/dev/video0 ! video/x-raw,width=1920,height=1536,format=UYVY,pixel-aspect-ratio=1/1,framerate=30/1 ! videoconvert ! xvimagesink

