#!/bin/sh

set -eux

media-ctl -d /dev/media0 -R '"max9x a-0"[0/0->2/0[1]]'
media-ctl -d /dev/media0 -R '"max9x a"[4/0->0/0[1]]'
media-ctl -d /dev/media0 -R '"Intel IPU7 CSI2 0"[0/0->1/0[1]]'

media-ctl -d /dev/media0 -V '"isx031f a-0":0/0 [fmt:UYVY8_1X16/1920x1536]'
media-ctl -d /dev/media0 -V '"max9x a-0":0/0 [fmt:UYVY8_1X16/1920x1536]'
media-ctl -d /dev/media0 -V '"max9x a-0":2/0 [fmt:UYVY8_1X16/1920x1536]'
media-ctl -d /dev/media0 -V '"max9x a":4/0 [fmt:UYVY8_1X16/1920x1536]'
media-ctl -d /dev/media0 -V '"max9x a":0/0 [fmt:UYVY8_1X16/1920x1536]'
media-ctl -d /dev/media0 -V '"Intel IPU7 CSI2 0":0/0 [fmt:UYVY8_1X16/1920x1536]'
media-ctl -d /dev/media0 -V '"Intel IPU7 CSI2 0":1/0 [fmt:UYVY8_1X16/1920x1536]'

media-ctl -d /dev/media0 -l '"Intel IPU7 CSI2 0":1 -> "Intel IPU7 ISYS Capture 0":0[1]'

v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1536,pixelformat=UYVY

# Test commands:
## yavta
### yavta -c10 -f UYVY -s 1920x1536 --file=/tmp/isx031f-1-#.uyvy /dev/video0

## v4l2src (colormetry issue)
###  gst-launch-1.0 -e -v v4l2src device=/dev/video0 ! video/x-raw,width=1920,height=1536,format=UYVY,pixel-aspect-ratio=1/1,framerate=30/1 ! videoconvert ! xvimagesink

