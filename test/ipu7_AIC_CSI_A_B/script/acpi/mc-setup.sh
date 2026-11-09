#!/bin/bash
#
# Copyright (C) 2026 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Discover the GMSL camera topology purely from ACPI/sysfs and program
# the media graph with media-ctl. Supports a *mixed* set of sensors behind
# a single deserializer (e.g. CAM0=D4XX on CH00, CAM1=ISX031 on CH01).
#
# ACPI namespace layout assumed (from SSDT):
#     \_SB.PCxx.DESn                             -- deserializer
#       \_SB.PCxx.DESn.CHmm                      -- channel (no HID)
#         \_SB.PCxx.DESn.CHmm.SERk                -- serializer
#           \_SB.PCxx.DESn.CHmm.SERk.CAMk          -- camera (single-PHY SER)
#
# Multi-PHY serializers (e.g. MAX9295D on a ZED X, 2 PHYs) instead carry one
# camera per sub-channel, one level deeper:
#         \_SB.PCxx.DESn.CHmm.SERk                -- serializer
#           \_SB.PCxx.DESn.CHmm.SERk.CHpp         -- sub-channel / PHY p (no HID)
#             \_SB.PCxx.DESn.CHmm.SERk.CHpp.CAMp  -- camera (sensor)
#
# Every ACPI device exposes:
#   /sys/bus/acpi/devices/<HID>:<UID>/path        -- ACPI namespace path
#   /sys/bus/acpi/devices/<HID>:<UID>/physical_node*/video4linux/v4l-subdev*/name
#                                                 -- "<entity_prefix> <bus>-<addr>"
#
# Known sensor / SerDes HIDs:
#   INTC10CD = D4XX camera   (entity prefixes: "DS5 mux", "D4XX depth/rgb/ir/imu")
#   INTC113C = ISX031 camera (entity prefix:   "isx031")
#   INTC10C0 = AR0234 camera (entity prefix:   "ar0234")
#   OVTI13B1 = OV13B10 camera (entity prefix: "ov13b10")
#   INTC1138 = MAX9295 serializer               (entity prefix: "max96717")
#   INTC1140 = MAX9295D serializer (ZED X)      (2 PHYs, entity prefix: "max96717")
#   INTC1141 = MAX96717 serializer (M3A)        (1 PHY,  entity prefix: "max96717")
#   INTC1137 = MAX9296A deserializer            (entity prefix: "max9296a")
#   INTC1139 = MAX96724 deserializer            (entity prefix: "max96724")

# =============================================================================
# Environment variable overrides (all optional)
# =============================================================================
# Discovery filters:
#   DES_HID=<hid>            Restrict discovery to one deserializer HID
#                            (e.g. INTC1137 or INTC1139). Default: unset (all).
#   DES_BUSADDR=<bus>-<addr> Restrict to one I2C bus-addr (e.g. 1-0027).
#                            Default: unset (all).
#
# Per-DES link count caps (override MAX_LINKS_BY_PREFIX):
#   MAX_LINKS_max96724       Default: 4
#   MAX_LINKS_max9296a       Default: 2
#
# IPU7 CSI2 RX source-pad cap:
#   IPU_CSI2_SRC_PADS        Default: 16 (use 8 without the D4XX IPU7 patch).
#
# Dual-output deserializer (one DES with two CSI2Bus source ports, e.g. MAX96724
# PHY0 -> IPU CSI2 0 and PHY2 -> IPU CSI2 1). Outputs are numbered per DES in
# ascending DES source-pad order (out 0 = lowest pad). By default links are
# split evenly: link l -> out (l * num_outputs / DES_MAX_LINKS), i.e. links
# 0,1 -> out 0 and links 2,3 -> out 1 for a 4-link DES with two outputs.
#   DES_LINK_OUT="D:L:O ..." Override output O for link L of DES D
#                            (e.g. DES_LINK_OUT="0:1:1 0:2:0").
#
# ZED X (AR0234 behind a multi-PHY serializer):
#   ZEDX_FRAME_SYNC          Written to /sys/module/ar0234/parameters/frame_sync
#                            when a ZED X camera is configured. Default: 1.
#                            Set empty to leave the module parameter untouched.
#
# Example:
#   DES_HID=INTC1139 ./mc-setup.sh \
#       link=0,stream=depth,res=1280x720,format=UYVY8_1X16 \
#       link=1,stream=depth
#
# =============================================================================
# USER CONFIGURATION
# =============================================================================
# Edit the tables below to add a new sensor MODEL, a new HID -> entity PREFIX
# mapping, or a new stream FORMAT. Everything further down is generic and
# dispatches off these tables.
#
# To add a new sensor model:
#   1. Add its ACPI HID -> model name in SENSOR_MODEL.
#   2. Add its ACPI HID -> v4l-subdev entity prefix in SENSOR_PREFIX.
#   3. For multi-stream models, list the stream tokens in MODEL_STREAMS and
#      select their defaults in MODEL_DEFAULT_STREAMS (and, optionally,
#      MODEL_OPTIONAL_DEFAULT_STREAMS).
#   4. For each new stream token, set STREAM_NODE (and STREAM_MUXPAD if it
#      flows through a d4xx-style mux).
#   5. If your new media-bus code isn't covered, extend MBUS_TO_PIXFMT.
#   6. If the sensor needs custom media-ctl wiring beyond a plain serializer
#      pass-through (e.g. a mux subdev), extend the per-model case statements
#      in the programming passes further down -- the tables alone are enough
#      for simple "serializer-only" sensors.
# -----------------------------------------------------------------------------

# ---- ACPI HID -> v4l entity prefix / sensor model ---------------------------
declare -A SENSOR_MODEL=(
    [INTC10CD]=d4xx
    [INTC113C]=isx031
    [INTC10C0]=ar0234
    [OVTI13B1]=ov13b10
)
declare -A SENSOR_PREFIX=(
    [INTC10CD]="DS5 mux"
    [INTC113C]="isx031"
    [INTC10C0]="ar0234"
    [OVTI13B1]="ov13b10"
)

# ---- Direct MIPI sensor HIDs (no GMSL deserializer) ------------------------
declare -A MIPI_SENSOR_HID=(
    [INTC113C]=isx031
    [OVTI13B1]=ov13b10
)

# ---- Serializer / Deserializer HID -> v4l entity prefix ---------------------
declare -A SER_PREFIX=(
    [INTC1138]="max96717"
    [INTC1140]="max96717"
    [INTC1141]="max96717"
)

# Number of camera-facing PHYs (sink pads) of a serializer model; its source
# pad number equals this count. Serializers with more than one PHY carry one
# camera per ACPI sub-channel (SERk.CHpp.CAMp).
declare -A SER_NUM_PHYS=(
    [INTC1138]=1
    [INTC1140]=2
    [INTC1141]=1
)
declare -A DES_PREFIX=(
    [INTC1137]="max9296a"
    [INTC1139]="max96724"
)

# Max number of CHxx links per deserializer, keyed by DES entity prefix.
# Override per model via env, e.g. MAX_LINKS_max9296a=2.
declare -A MAX_LINKS_BY_PREFIX=(
    [max96724]=${MAX_LINKS_max96724:-4}
    [max9296a]=${MAX_LINKS_max9296a:-2}
)

# ---- Per-model stream definitions -------------------------------------------
# MODEL_STREAMS: stream tokens selectable for multi-stream models.
# MODEL_DEFAULT_STREAMS: streams enabled for those models when no `stream=` is
# given on the CLI.
# MODEL_OPTIONAL_DEFAULT_STREAMS: streams appended to those defaults only while
# the deserializer still has a free source_stream (max 4) and the stream's
# capture node is unused, so multi-camera setups keep working unchanged.
declare -A MODEL_STREAMS=(
    [d4xx]="depth rgb ir imu"
)
declare -A MODEL_DEFAULT_STREAMS=(
    [d4xx]="depth rgb"
)
declare -A MODEL_OPTIONAL_DEFAULT_STREAMS=(
    [d4xx]="ir imu"
)

fixed_stream_for_model() {
    case "$1" in
        isx031|ar0234|ov13b10) echo single ;;
        *) return 1 ;;
    esac
}

# STREAM_NODE: per-stream capture-node index (also used as the v4l2
# source_stream id on the mux/serializer chain -- d4xx in particular asserts
# this matches the sensor's hard-coded vc_id, so pick stable values).
declare -A STREAM_NODE=(
    [depth]=0
    [rgb]=1
    [ir]=2
    [imu]=3
    [single]=0
)

# Capture-node placement is independent of STREAM_NODE. Depth and IMU share
# bank 0..3; RGB and IR share bank 4..7. Rotating IR and IMU by two links gives
# this D4XX camera 1..4 mapping:
#   depth=0,1,2,3  rgb=4,5,6,7  ir=6,7,4,5  imu=2,3,0,1
CSI2_NODE_BANK_SIZE=4
declare -A STREAM_CAPTURE_BASE=(
    [depth]=0
    [rgb]=4
    [ir]=4
    [imu]=0
    [single]=0
)
declare -A STREAM_LINK_ROTATION=(
    [depth]=0
    [rgb]=0
    [ir]=2
    [imu]=2
    [single]=0
)

# STREAM_MUXPAD: sink pad on a d4xx-style mux subdev. Only needed for streams
# that flow through such a mux, usually a 3D sensor.
declare -A STREAM_MUXPAD=(
    [depth]=1
    [rgb]=2
    [ir]=3
    [imu]=4
)

# ---- Media-bus -> V4L2 pixelformat fourcc (used on capture nodes) -----------
declare -A MBUS_TO_PIXFMT=(
    [FIXED]="Z16 "
    [UYVY8_1X16]="UYVY"
    [YUYV8_1X16]="YUYV"
    [RGB888_1X24]="BGR3"
    [VYUY8_1X16]="Y8I "   # IR -> interleaved 8-bit greyscale
    [Y8_1X8]="GREY"
    [SGRBG10_1X10]="BA10"  # AR0234 RAW Bayer SGRBG 10-bit
)
mbus_to_pixfmt() { echo "${MBUS_TO_PIXFMT[$1]:-}"; }

declare -A STREAM_FORMAT_MAP=(
    [d4xx_depth_FIXED]=UYVY8_1X16
)

# =============================================================================
# end of USER CONFIGURATION
# =============================================================================

# -------- low-level helpers ---------------------------------------------------

# Find the lowest "ISYS Capture N" index linked from a given CSI2 entity.
# Reads media-ctl topology from stdin.
capture_base_of_csi2() {
    awk -v csi="$1" '
        /^- entity / {
            n = ""
            if (match($0, /Intel IPU[0-9]+ ISYS Capture [0-9]+/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/.*Capture /, "", s)
                n = s + 0
            }
        }
        n != "" && index($0, "<- \"" csi "\":") {
            if (m == "" || n < m) m = n
        }
        END { if (m != "") print m }
    '
}

# Read "bus-addr" (e.g. 18-0010) from any v4l-subdev whose name starts with
# the given prefix, under any physical_node* of an ACPI sysfs dir.
acpi_busaddr() {
    local acpi_dir=$1 prefix=$2
    local f
    for f in "$acpi_dir"/physical_node*/video4linux/v4l-subdev*/name; do
        [ -e "$f" ] || continue
        local name; name=$(cat "$f")
        local ba; ba=$(printf '%s\n' "$name" | grep -oP "^${prefix} \K[0-9]+-[0-9a-f]+" | head -1)
        [ -n "$ba" ] && { echo "$ba"; return 0; }
    done
    return 1
}

# Find the ACPI sysfs dir whose `path` file matches a given namespace path.
# Echo "<HID>:<UID> <sysfs_dir>" or return 1.
acpi_find_by_path() {
    local target=$1
    local d p
    for d in /sys/bus/acpi/devices/*; do
        p=$(cat "$d/path" 2>/dev/null) || continue
        if [ "$p" = "$target" ]; then
            echo "$(basename "$d") $d"
            return 0
        fi
    done
    return 1
}

# List immediate ACPI children of a namespace path: print "<child_path>"
# sorted by the trailing component (so CH00 < CH01).
acpi_children_of() {
    local parent=$1
    local d p
    for d in /sys/bus/acpi/devices/*; do
        p=$(cat "$d/path" 2>/dev/null) || continue
        case "$p" in
            "$parent".*) ;;
            *) continue ;;
        esac
        # only direct children (one extra dot-segment)
        local rest=${p#"$parent".}
        case "$rest" in *.*) continue ;; esac
        echo "$p"
    done | sort -u
}

# HID/UID of an ACPI sysfs dir
acpi_hid() { cat "$1/hid" 2>/dev/null; }

# Wrappers around `media-ctl` that print the exact failing arg on error so
# link-setup, routing and format-propagation issues are easy to pin down.
# Each wrapper preserves the underlying `media-ctl` exit status so callers
# checking $? still see the failure.
mc_l() {
    local rc
    media-ctl -l "$1"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  ^^ failed: media-ctl -l $1" >&2
    fi
    return "$rc"
}

mc_R() {
    local rc
    media-ctl -R "$1"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  ^^ failed: media-ctl -R $1" >&2
    fi
    return "$rc"
}

mc_v() {
    local rc
    media-ctl -V "$1"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  ^^ failed: media-ctl -V $1" >&2
    fi
    return "$rc"
}

# Print the serializer sink pad that a camera's immutable media link lands on.
# A board can wire camera order differently from the ACPI sub-channel order,
# so the live graph, not the ACPI name, decides the PHY / sink pad.
media_ser_sink_pad() {
    local ser_entity=$1 cam_entity=$2
    media-ctl -p 2>/dev/null | awk -v cam="$cam_entity" -v ser="$ser_entity" '
        /^- entity / { in_cam = index($0, ": " cam " (") ? 1 : 0; next }
        in_cam && index($0, "-> \"" ser "\":") {
            sub(/^.*-> "[^"]+":/, "")
            sub(/ .*/, "")
            print
            found = 1
            exit
        }
        END { exit !found }'
}

# -------- topology discovery --------------------------------------------------

# Per-DES MAX_LINKS (indexed by DES index 'd'), populated during discovery
# from MAX_LINKS_BY_PREFIX (declared in the USER CONFIGURATION block).
declare -a DES_MAX_LINKS=()

# Locate every deserializer present on the system. Echoes one sysfs dir per
# line. Honours DES_HID=<hid> (filter to a specific HID) and DES_BUSADDR=
# (filter to a specific bus-addr e.g. "1-0027").
find_all_deserializers() {
    local want_hid=${DES_HID:-}
    local want_ba=${DES_BUSADDR:-}
    local hid d ba prefix
    for hid in "${!DES_PREFIX[@]}"; do
        [ -n "$want_hid" ] && [ "$want_hid" != "$hid" ] && continue
        prefix=${DES_PREFIX[$hid]}
        for d in /sys/bus/acpi/devices/${hid}:*; do
            [ -d "$d" ] || continue
            if [ -n "$want_ba" ]; then
                ba=$(acpi_busaddr "$d" "$prefix") || continue
                [ "$ba" = "$want_ba" ] || continue
            fi
            echo "$d"
        done
    done
}

# Per-DES arrays (indexed by deserializer index 'd', 0..N-1):
declare -a DES_PATH=() DES_BA=() DES_PREFIX_NAME=() DES_SRC_PAD=()
declare -a IPU_CSI2_ENTITY=() IPU_BASE=() CAPTURE_BASE=()
# Per-DES outputs (DES source pad -> IPU CSI2). Keys are "<d>_<o>".
# DES_SRC_PAD/IPU_CSI2_ENTITY/IPU_BASE/CAPTURE_BASE[d] mirror output 0.
declare -a DES_NOUT=()
declare -A OUT_SRC_PAD=() OUT_CSI2=() OUT_IPU_BASE=() OUT_CAPBASE=()
NUM_DES=0

# get IPU CSI2 ISYS Capture  /dev/video initial offset
PREFIX=$(v4l2-ctl --list-devices | grep ipu | grep PCI | sed 's/^\(ipu[6|7]\).*/\1/' | tr '[:lower:]' '[:upper:]')
VID_DEV_OFFSET=$(media-ctl -e "Intel $PREFIX ISYS Capture 0" | awk -F'video' '{print $2}')

# Per-link associative arrays keyed by "d_l" (deserializer index, link index).
# The serializer is shared by every PHY on a link, so it is keyed per link.
declare -A SER_PATH=() SER_BA=() SER_PFX=() SER_HID=() SER_NPHYS=()
# Per-camera associative arrays keyed by "d_l_p" (DES idx, link idx, PHY idx);
# single-PHY serializers always use p=0.
declare -A CAM_PATH=() CAM_BA=()
declare -A CAM_HID=() CAM_MODEL=() CAM_PREFIX=()
# CAM_SER_PAD: serializer sink pad the camera is linked to.
# CAM_SID: sensor source stream id (only set when it is not STREAM_NODE[s]).
declare -A CAM_SER_PAD=() CAM_SID=()
# PHYS_OF[d_l] holds a space-separated list of valid PHY indices on a link.
declare -A PHYS_OF=()
# LINKS_OF[d] holds a space-separated list of valid link indices on DES d.
declare -A LINKS_OF=()

# Register camera $3 (ACPI path) as PHY $4 of link key $2 on DES $1.
# Echo nothing; return 1 (after a warning) when the camera is unusable.
discover_one_cam() {
    local d=$1 key=$2 cam_path=$3 p=$4 ser_hid=$5
    local l=${key#*_} ckey="${key}_${p}" cam_dir cam_hid cam_name cam_pfx cam_ba ser_pad
    local where="DES${d} link ${l}"
    (( SER_NUM_PHYS[$ser_hid] > 1 )) && where+=" PHY ${p}"

    read -r _ cam_dir < <(acpi_find_by_path "$cam_path") || {
        echo "WARN: ${where}: camera ACPI dev for '$cam_path' not present in sysfs; skipping" >&2
        return 1
    }
    cam_hid=$(acpi_hid "$cam_dir")
    if [ -z "${SENSOR_MODEL[$cam_hid]:-}" ]; then
        cam_name=$(cat "$cam_dir"/physical_node*/video4linux/v4l-subdev*/name 2>/dev/null | head -1)
        echo "WARN: ${where}: unsupported camera HID '$cam_hid' at $cam_path${cam_name:+ (subdev: $cam_name)}; skipping" >&2
        echo "      add an entry to SENSOR_MODEL[${cam_hid}] / SENSOR_PREFIX[${cam_hid}] to enable it" >&2
        return 1
    fi
    cam_pfx=${SENSOR_PREFIX[$cam_hid]}
    cam_ba=$(acpi_busaddr "$cam_dir" "$cam_pfx") || {
        echo "WARN: ${where}: camera at $cam_path has no v4l-subdev (driver loaded?); skipping" >&2
        return 1
    }
    ser_pad=0
    if (( SER_NUM_PHYS[$ser_hid] > 1 )); then
        ser_pad=$(media_ser_sink_pad "${SER_PFX[$key]} ${SER_BA[$key]}" "${cam_pfx} ${cam_ba}") || {
            echo "WARN: ${where}: no media link from '${cam_pfx} ${cam_ba}' to '${SER_PFX[$key]} ${SER_BA[$key]}'; skipping" >&2
            return 1
        }
    fi

    CAM_PATH[$ckey]=$cam_path
    CAM_PREFIX[$ckey]=$cam_pfx
    CAM_BA[$ckey]=$cam_ba
    CAM_HID[$ckey]=$cam_hid
    CAM_MODEL[$ckey]=${SENSOR_MODEL[$cam_hid]}
    CAM_SER_PAD[$ckey]=$ser_pad
    return 0
}

discover_one_des() {
    local d=$1 des_dir=$2
    local des_hid des_path des_ba des_prefix
    des_hid=$(acpi_hid "$des_dir")
    des_prefix=${DES_PREFIX[$des_hid]}
    des_path=$(cat "$des_dir/path")
    des_ba=$(acpi_busaddr "$des_dir" "$des_prefix") || {
        echo "WARN: deserializer ${des_hid} at ${des_path} has no v4l-subdev (driver loaded?); skipping" >&2
        return 1
    }

    DES_PATH[$d]=$des_path
    DES_BA[$d]=$des_ba
    DES_PREFIX_NAME[$d]=$des_prefix
    # DES_SRC_PAD[$d] is filled in later by detect_gmsl_csi2() based on the
    # live media topology (which reflects the DES_CSI_LOCAL_PORT value the
    # SSDT/_CRS published in the CSI2Bus resource).
    DES_MAX_LINKS[$d]=${MAX_LINKS_BY_PREFIX[$des_prefix]:-4}

    local i ch ser_path ser_dir ser_hid cam_path ch_name key subch p phys
    local found=0
    local links=""
    while IFS= read -r ch; do
        [ -z "$ch" ] && continue

        ch_name=${ch##*.}
        if [[ $ch_name =~ ^CH([0-9]+)$ ]]; then
            i=$((10#${BASH_REMATCH[1]}))
        else
            echo "WARN: DES${d}: cannot parse channel index from '$ch'; skipping" >&2
            continue
        fi
        if (( i >= DES_MAX_LINKS[d] )); then
            echo "WARN: DES${d}: link ${i} (${ch}) exceeds max supported links (${DES_MAX_LINKS[$d]}) for ${des_prefix}; skipping" >&2
            continue
        fi
        key="${d}_${i}"

        ser_path=$(acpi_children_of "$ch" | head -1)
        [ -z "$ser_path" ] && {
            echo "WARN: DES${d} link ${i} (${ch}) has no serializer child; skipping" >&2
            continue
        }
        read -r _ ser_dir < <(acpi_find_by_path "$ser_path") || {
            echo "WARN: DES${d} link ${i}: serializer ACPI dev for '$ser_path' not present in sysfs; skipping" >&2
            continue
        }
        ser_hid=$(acpi_hid "$ser_dir")
        [ -n "${SER_PREFIX[$ser_hid]:-}" ] || {
            echo "WARN: DES${d} link ${i}: unsupported serializer HID '$ser_hid' at $ser_path; skipping" >&2
            continue
        }
        SER_PFX[$key]=${SER_PREFIX[$ser_hid]}
        SER_BA[$key]=$(acpi_busaddr "$ser_dir" "${SER_PFX[$key]}") || {
            echo "WARN: DES${d} link ${i}: serializer at $ser_path has no v4l-subdev (driver loaded?); skipping" >&2
            unset 'SER_PFX[$key]' 'SER_BA[$key]'
            continue
        }

        # A single-PHY serializer carries its camera as a direct ACPI child
        # (PHY 0); a multi-PHY one carries one camera per CHpp sub-channel.
        phys=""
        if (( ${SER_NUM_PHYS[$ser_hid]:-1} > 1 )); then
            while IFS= read -r subch; do
                [ -z "$subch" ] && continue
                [[ ${subch##*.} =~ ^CH([0-9]+)$ ]] || continue
                p=$((10#${BASH_REMATCH[1]}))
                cam_path=$(acpi_children_of "$subch" | head -1)
                [ -n "$cam_path" ] || continue
                discover_one_cam "$d" "$key" "$cam_path" "$p" "$ser_hid" \
                    && phys+="${phys:+ }${p}"
            done < <(acpi_children_of "$ser_path")
        else
            cam_path=$(acpi_children_of "$ser_path" | head -1)
            if [ -n "$cam_path" ]; then
                discover_one_cam "$d" "$key" "$cam_path" 0 "$ser_hid" && phys=0
            fi
        fi
        [ -n "$phys" ] || {
            echo "WARN: DES${d} link ${i}: serializer at $ser_path has no usable camera; skipping" >&2
            unset 'SER_PFX[$key]' 'SER_BA[$key]'
            continue
        }

        SER_PATH[$key]=$ser_path
        SER_HID[$key]=$ser_hid
        SER_NPHYS[$key]=${SER_NUM_PHYS[$ser_hid]:-1}
        PHYS_OF[$key]=$phys
        links+="${links:+ }${i}"
        found=$((found + 1))
    done < <(acpi_children_of "$des_path")

    LINKS_OF[$d]=$links
    [ "$found" -gt 0 ] || {
        echo "WARN: DES${d} (${des_path}): no supported cameras discovered; skipping" >&2
        unset 'DES_PATH[$d]' 'DES_BA[$d]' 'DES_PREFIX_NAME[$d]' 'DES_SRC_PAD[$d]'
        unset 'LINKS_OF[$d]'
        return 1
    }
    return 0
}

discover() {
    local des_dirs=()
    mapfile -t des_dirs < <(find_all_deserializers)
    if [ "${#des_dirs[@]}" -gt 0 ]; then
        local d=0 dir
        for dir in "${des_dirs[@]}"; do
            if discover_one_des "$d" "$dir"; then
                d=$((d + 1))
            fi
        done
        NUM_DES=$d
    fi
    if [ "$NUM_DES" -eq 0 ] && [ "${#des_dirs[@]}" -gt 0 ]; then
        echo "WARN: ${#des_dirs[@]} deserializer ACPI device(s) found" \
             "but none are usable (driver loaded?)" >&2
    fi
    # Discover direct MIPI cameras (skips sensors already behind a DES).
    discover_mipi_cameras
    [ "$NUM_DES" -gt 0 ] || [ "$NUM_MIPI" -gt 0 ] || {
        echo "ERROR: no deserializer or direct MIPI camera found" >&2
        return 1
    }
    return 0
}

# ---- Direct MIPI camera support ---------------------------------------------
declare -a MIPI_BA=() MIPI_PREFIX=() MIPI_MODEL=() MIPI_CSI2=() MIPI_CAP=()
NUM_MIPI=0

discover_mipi_cameras() {
    local hid model prefix d ba path idx=0
    for hid in "${!MIPI_SENSOR_HID[@]}"; do
        model=${MIPI_SENSOR_HID[$hid]}
        prefix=${SENSOR_PREFIX[$hid]}
        for d in /sys/bus/acpi/devices/${hid}:*; do
            [ -d "$d" ] || continue
            # Skip sensors already discovered behind a deserializer.
            path=$(cat "$d/path" 2>/dev/null) || continue
            local skip=0 di
            for ((di = 0; di < NUM_DES; di++)); do
                case "$path" in "${DES_PATH[$di]}."*) skip=1; break ;; esac
            done
            [ "$skip" -eq 1 ] && continue
            ba=$(acpi_busaddr "$d" "$prefix") || continue
            MIPI_BA[$idx]=$ba; MIPI_PREFIX[$idx]=$prefix; MIPI_MODEL[$idx]=$model
            idx=$((idx + 1))
        done
    done
    NUM_MIPI=$idx
    [ "$NUM_MIPI" -gt 0 ] && echo "Discovered $NUM_MIPI direct MIPI camera(s)"
}

detect_mipi_csi2() {
    [ "$NUM_MIPI" -eq 0 ] && return 0
    local topo i cam csi2 base
    topo=$(media-ctl -p 2>/dev/null) || return 1
    for ((i = 0; i < NUM_MIPI; i++)); do
        cam="${MIPI_PREFIX[$i]} ${MIPI_BA[$i]}"
        csi2=$(awk -v c="$cam" '
            /- entity.*: / { f = index($0, ": " c " (") ? 1 : 0 }
            f && /-> "Intel IPU[0-9]+ CSI2 [0-9]+"/ {
                gsub(/.*-> "|":.*/, "")
                print
                exit
            }
        ' <<<"$topo")
        [ -z "$csi2" ] && { echo "ERROR: no CSI2 link for $cam" >&2; return 1; }
        MIPI_CSI2[$i]=$csi2
        MIPI_CAP[$i]=$(capture_base_of_csi2 "$csi2" <<<"$topo")
        if [ -z "${MIPI_CAP[$i]}" ]; then
            echo "ERROR: MIPI${i}: could not find any 'ISYS Capture' entity linked from '$csi2'" >&2
            return 1
        fi
    done
}

setup_mipi_cameras() {
    [ "$NUM_MIPI" -eq 0 ] && return 0
    echo -e "\nConfiguring direct MIPI cameras..."
    local i model cam csi2 node vid_node fmt size s sid detected pixfmt w h ipu
    for ((i = 0; i < NUM_MIPI; i++)); do
        model=${MIPI_MODEL[$i]}
        cam=${MIPI_BA[$i]}
        csi2=${MIPI_CSI2[$i]}
        node=${MIPI_CAP[$i]}
	vid_node=$(( nodes + VID_DEV_OFFSET ))
        s=$(fixed_stream_for_model "$model") \
            || die "no stream configuration for MIPI${i} $model"
        sid=${STREAM_NODE[$s]}
        detected=$(sensor_active_format "$model" "$cam" "$s" "$sid") || \
            die "cannot read active format from MIPI${i} ${model} sensor"
        read -r fmt size <<<"$detected"
        echo "  ${MIPI_PREFIX[$i]} $cam -> $csi2 -> /dev/video$vid_node ($fmt/$size)"
        mc_v "\"${MIPI_PREFIX[$i]} ${cam}\":0 [fmt:${fmt}/${size} field:none]"
        mc_v "\"${csi2}\":0 [fmt:${fmt}/${size} field:none]"
        mc_v "\"${csi2}\":1 [fmt:${fmt}/${size} field:none]"
        ipu=${csi2% CSI2 *}
        mc_l "\"${csi2}\":1 -> \"${ipu} ISYS Capture ${node}\":0[1]"
        pixfmt=$(mbus_to_pixfmt "$fmt")
        w=${size%x*}
        h=${size#*x}
        [ -n "$pixfmt" ] &&
            v4l2-ctl -d "/dev/video${vid_node}" \
                --set-fmt-video="width=${w},height=${h},pixelformat=${pixfmt}" \
                >/dev/null
    done
}

# For each DES, locate every "Intel IPUx CSI2 N" entity wired to one of its
# source pads, the DES source pad number itself (which mirrors the CSI2Bus
# LocalPort in the SSDT; a DES may declare two CSI2Bus resources), and the
# absolute capture-node base (lowest "ISYS Capture <N>" index linked to that
# CSI2). The DES->CSI2 links are IMMUTABLE so the live media topology is the
# source of truth. Outputs are ordered by ascending DES source pad.
detect_gmsl_csi2() {
    local topo
    topo=$(media-ctl -p 2>/dev/null) || {
        echo "ERROR: failed to read media topology via 'media-ctl -p'" >&2
        return 1
    }
    local d o des_entity csi2 src_pad line lines key
    for ((d = 0; d < NUM_DES; d++)); do
        des_entity="${DES_PREFIX_NAME[$d]} ${DES_BA[$d]}"
        # Extract "<src_pad> <csi2_entity>" lines from the entity block.
        lines=$(awk -v des="$des_entity" '
            /^- entity / { in_des=0 }
            index($0, "- entity") && index($0, ": " des " (") { in_des=1; next }
            in_des && match($0, /pad[0-9]+:/) {
                p = substr($0, RSTART+3, RLENGTH-4)
                cur_pad = p + 0
            }
            in_des && match($0, /-> "Intel IPU[0-9]+ CSI2 [0-9]+"/) {
                s = substr($0, RSTART+4, RLENGTH-5)
                gsub(/"/, "", s)
                print cur_pad, s
            }' <<<"$topo" | sort -n -k1,1 -u)
        if [ -z "$lines" ]; then
            echo "ERROR: DES${d}: could not find an 'Intel IPUx CSI2 N' link from '$des_entity'" >&2
            return 1
        fi
        o=0
        while read -r line; do
            src_pad=${line%% *}
            csi2=${line#* }
            key="${d}_${o}"
            OUT_SRC_PAD[$key]=$src_pad
            OUT_CSI2[$key]=$csi2
            OUT_IPU_BASE[$key]=${csi2% CSI2 *}
            OUT_CAPBASE[$key]=$(capture_base_of_csi2 "$csi2" <<<"$topo")
            if [ -z "${OUT_CAPBASE[$key]}" ]; then
                echo "ERROR: DES${d}: could not find any 'ISYS Capture' entity linked from '$csi2'" >&2
                return 1
            fi
            o=$(( o + 1 ))
        done <<<"$lines"
        DES_NOUT[$d]=$o
        DES_SRC_PAD[$d]=${OUT_SRC_PAD[${d}_0]}
        IPU_CSI2_ENTITY[$d]=${OUT_CSI2[${d}_0]}
        IPU_BASE[$d]=${OUT_IPU_BASE[${d}_0]}
        CAPTURE_BASE[$d]=${OUT_CAPBASE[${d}_0]}
    done
    build_link_out || return 1
    return 0
}

# LINK_OUT["<d>_<l>"] = DES output index used by link l of DES d.
declare -A LINK_OUT=()
build_link_out() {
    local d l o n m tok
    for ((d = 0; d < NUM_DES; d++)); do
        n=${DES_NOUT[$d]}
        m=${DES_MAX_LINKS[$d]:-4}
        for ((l = 0; l < m; l++)); do
            LINK_OUT["${d}_${l}"]=$(( l * n / m ))
        done
    done
    for tok in ${DES_LINK_OUT:-}; do
        if ! [[ $tok =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
            echo "ERROR: DES_LINK_OUT: bad token '$tok' (expected D:L:O)" >&2
            return 1
        fi
        d=${BASH_REMATCH[1]} l=${BASH_REMATCH[2]} o=${BASH_REMATCH[3]}
        if (( d >= NUM_DES )) || (( l >= ${DES_MAX_LINKS[$d]:-4} )) ||
            (( o >= DES_NOUT[$d] )); then
            echo "ERROR: DES_LINK_OUT: '$tok' out of range" >&2
            return 1
        fi
        LINK_OUT["${d}_${l}"]=$o
    done
    return 0
}

# Output index / key of CFG entry $1 ("<d>_<o>").
cfg_out() { echo "${LINK_OUT[${CFG_DES[$1]}_${CFG_LINKS[$1]}]:-0}"; }
cfg_okey() { echo "${CFG_DES[$1]}_$(cfg_out "$1")"; }

# -------- pretty print --------------------------------------------------------

print_topology() {
    echo "Discovered topology:"
    local d l p o key okey ckey vid_node
    for ((d = 0; d < NUM_DES; d++)); do
	vid_node=$(( CAPTURE_BASE[$d] + VID_DEV_OFFSET ))
        printf "  DES%d  %-34s %s %s -> %s (capture base /dev/video%s)\n" \
            "$d" "${DES_PATH[$d]}" "${DES_PREFIX_NAME[$d]}" "${DES_BA[$d]}" \
            "${IPU_CSI2_ENTITY[$d]}" "$vid_node"
        if (( DES_NOUT[$d] > 1 )); then
            for ((o = 0; o < DES_NOUT[$d]; o++)); do
                okey="${d}_${o}"
                printf "    OUT%d  DES pad %s -> %s (capture base /dev/video%s), links:" \
                    "$o" "${OUT_SRC_PAD[$okey]}" "${OUT_CSI2[$okey]}" \
                    "$(( OUT_CAPBASE[$okey] + VID_DEV_OFFSET ))"
                for l in ${LINKS_OF[$d]}; do
                    [ "${LINK_OUT[${d}_${l}]}" = "$o" ] && printf " %s" "$l"
                done
                echo
            done
        fi
        for l in ${LINKS_OF[$d]}; do
            key="${d}_${l}"
            printf "    SER%d  %-34s %s %s\n" \
                "$l" "${SER_PATH[$key]}" "${SER_PFX[$key]}" "${SER_BA[$key]}"
            for p in ${PHYS_OF[$key]}; do
                ckey="${key}_${p}"
                if (( SER_NPHYS[$key] > 1 )); then
                    printf "    CAM%d.%d %-33s %s %s  (model=%s, hid=%s, ser pad %s)\n" \
                        "$l" "$p" "${CAM_PATH[$ckey]}" "${CAM_PREFIX[$ckey]}" \
                        "${CAM_BA[$ckey]}" "${CAM_MODEL[$ckey]}" "${CAM_HID[$ckey]}" \
                        "${CAM_SER_PAD[$ckey]}"
                else
                    printf "    CAM%d  %-34s %s %s  (model=%s, hid=%s)\n" \
                        "$l" "${CAM_PATH[$ckey]}" "${CAM_PREFIX[$ckey]}" "${CAM_BA[$ckey]}" \
                        "${CAM_MODEL[$ckey]}" "${CAM_HID[$ckey]}"
                fi
            done
        done
    done
    for ((i = 0; i < NUM_MIPI; i++)); do
	vid_node=$(( MIPI_CAP[$i] + VID_DEV_OFFSET ))
        printf "  MIPI%d  %s %s -> %s (capture /dev/video%s)\n" \
            "$i" "${MIPI_PREFIX[$i]}" "${MIPI_BA[$i]}" \
            "${MIPI_CSI2[$i]}" "$vid_node"
    done
    echo ""
}

# -------- per-sensor media-ctl programming -----------------------------------
#
# CLI:
#     mc-setup.sh                                      # default per-model streams, all DES
#
# Sample syntax (Items in [] are optional.)
#     mc-setup.sh [des=D,]link=N[,stream=<csv>][,res=WxH][,format=MBUS_CODE][,fps=FPS]
#
# Sample Single Stream Use Case can omit stream.
#     mc-setup.sh des=D,link=N,res=WxH,format=MBUS_CODE,fps=FPS
#
# Sample Multi Stream Use Case
#     mc-setup.sh des=D,link=N,stream=[TOKEN,res=WxH,format=MBUS_CODE,fps=FPS],\
#                                      [TOKEN,res=WxH,format=MBUS_CODE,fps=FPS] ...
#
# TOKEN is only applicable for multi-stream sensors as specified in MODEL_STREAMS.
# Other 2D sensors do not need stream=<csv>, they default to `single`.
#
# D4xx defaults to depth,rgb when no stream is specified, plus ir and then imu
# while the deserializer has a spare source_stream and the capture node is free.
#
# When des= is omitted, des=0 is assumed (matches the legacy single-DES CLI).
#
# Multi-PHY serializers (ZED X) carry two cameras on one link. link=N applies
# to every camera on the link; add phy=P to select one of them:
#     mc-setup.sh des=D,link=N[,phy=P][,res=WxH][,format=MBUS_CODE][,fps=FPS]
#
# Capture-node layout (per DES):
#     csi2_pad = STREAM_CAPTURE_BASE[s] +
#                 ((l + STREAM_LINK_ROTATION[s]) % CSI2_NODE_BANK_SIZE)
#     node     = CAPTURE_BASE[d] + csi2_pad
# For a dual-output DES, CAPTURE_BASE and the CSI2 entity are those of the
# DES output the link is assigned to (LINK_OUT / DES_LINK_OUT); every stream
# of one link goes to the same output because max_des validates routing with
# V4L2_SUBDEV_ROUTING_NO_SINK_STREAM_MIX.
# This places each stream in its configured capture bank and rotates selected
# streams across links using the permutation documented above. Streams that
# resolve to the same node cannot be enabled together and are rejected. For
# 1-stream sensors like isx031, links land on base+0..3 directly. The CSI2 RX
# cap is IPU*_NR_OF_CSI2_SRC_PADS; set IPU_CSI2_SRC_PADS to match (commonly 8
# or 16).
#
# v4l2 source_stream tag at the deserializer source pad / CSI2 sink pad is
# allocated separately as a compact per-DES sequential id (0..3), because
# max96724 / max_des bound the per-pipe stream-id field at 2 bits
# (MAX_SERDES_STREAMS_NUM=4). The csi2_pad above is only used as the CSI2
# *source* pad index (i.e. capture-node selector).
#
# Cameras behind a multi-PHY serializer (ZED X) instead get a fixed slot per
# DES, counted over every camera *declared* under the DES in ACPI path order
# (populated or not). Both csi2_pad and the deserializer source_stream are set
# to that slot; max96724 runs in pixel mode and so emits source_stream N on
# VC N. This matches the camera HAL config (ar0234stereo.json), which pins
# e.g. DES0.CH01.SER1.CH00.CAM0 / CH01.CAM1 / CH02...CAM0 / CAM1 to
# Capture 0..3 with vcId 0..3.

# =============================================================================
# Per-sensor stream lookups
# =============================================================================

sensor_entity_pad() {
    local model=$1 cam=$2 stream=$3 sid=$4

    case "$model" in
        d4xx)   SENSOR_ENTITY="D4XX ${stream} ${cam}"; SENSOR_PAD=0; SENSOR_SID=0 ;;
        isx031) SENSOR_ENTITY="isx031 ${cam}"; SENSOR_PAD=0; SENSOR_SID=$sid ;;
        ar0234) SENSOR_ENTITY="ar0234 ${cam}"; SENSOR_PAD=0; SENSOR_SID=$sid ;;
        ov13b10) SENSOR_ENTITY="ov13b10 ${cam}"; SENSOR_PAD=0; SENSOR_SID=0 ;;
        *) return 1 ;;
    esac
}

# Query one sensor source pad and print "<mbus-code> <width>x<height>".
sensor_active_format() {
    local model=$1 cam=$2 stream=$3 sid=$4 output fmt size

    sensor_entity_pad "$model" "$cam" "$stream" "$sid" || return 1
    output=$(media-ctl --get-v4l2 \
        "\"${SENSOR_ENTITY}\":${SENSOR_PAD}/${SENSOR_SID}" 2>/dev/null) || return 1
    if [[ $output =~ fmt:([[:alnum:]_]+)/([0-9]+x[0-9]+) ]]; then
        fmt=${BASH_REMATCH[1]}
        size=${BASH_REMATCH[2]}
        echo "$fmt $size"
        return 0
    fi
    return 1
}

sensor_active_fps() {
    local model=$1 cam=$2 stream=$3 sid=$4 dev output

    sensor_entity_pad "$model" "$cam" "$stream" "$sid" || return 1
    dev=$(media-ctl -e "$SENSOR_ENTITY" 2>/dev/null) || return 1
    output=$(v4l2-ctl -d "$dev" --get-subdev-fps \
        pad="$SENSOR_PAD",stream="$SENSOR_SID" 2>/dev/null) || return 1
    if [[ $output =~ Frames[[:space:]]per[[:space:]]second:[[:space:]]([0-9.]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Print the requested format/size after checking the sensor's advertised
# format-resolution combinations. Retain the active format when unsupported;
# use the largest resolution advertised for a supported format.
sensor_validate_format_size() {
    local model=$1 cam=$2 stream=$3 sid=$4 requested_fmt=$5 requested_size=$6
    local active_fmt=$7 active_size=$8 context=$9 dev codes line code name
    local selected_fmt selected_size selected_code sizes supported
    local min_w min_h max_w max_h req_w req_h largest_w largest_h
    local area largest_area=0
    local range_re

    range_re='Size[[:space:]]Range:[[:space:]]([0-9]+)x([0-9]+)'
    range_re+='[[:space:]]-[[:space:]]([0-9]+)x([0-9]+)'

    selected_fmt=${requested_fmt:-$active_fmt}
    selected_size=${requested_size:-$active_size}
    sensor_entity_pad "$model" "$cam" "$stream" "$sid" || return 1
    dev=$(media-ctl -e "$SENSOR_ENTITY" 2>/dev/null) || {
        echo "$selected_fmt $selected_size"
        return 0
    }

    codes=$(v4l2-ctl -d "$dev" --list-subdev-mbus-codes \
        pad="$SENSOR_PAD",stream="$SENSOR_SID" 2>/dev/null) || {
        echo "$selected_fmt $selected_size"
        return 0
    }
    while IFS= read -r line; do
        if [[ $line =~ (0x[[:xdigit:]]+):[[:space:]]+MEDIA_BUS_FMT_([[:alnum:]_]+) ]]; then
            code=${BASH_REMATCH[1]}
            name=${BASH_REMATCH[2]^^}
            if [ "$name" = "${selected_fmt^^}" ]; then
                selected_code=$code
                selected_fmt=$name
            fi
        fi
    done <<<"$codes"

    if [ -z "$selected_code" ]; then
        [ -z "$requested_fmt" ] || printf \
            "WARN: %s: format '%s' is unsupported; retaining current active format '%s'\n" \
            "$context" "$requested_fmt" "$active_fmt" >&2
        selected_fmt=$active_fmt
        while IFS= read -r line; do
            if [[ $line =~ (0x[[:xdigit:]]+):[[:space:]]+MEDIA_BUS_FMT_([[:alnum:]_]+) ]]; then
                code=${BASH_REMATCH[1]}
                name=${BASH_REMATCH[2]^^}
                [ "$name" = "${active_fmt^^}" ] && selected_code=$code
            fi
        done <<<"$codes"
    fi

    if [ -n "$requested_size" ] && [ -n "$selected_code" ]; then
        sizes=$(v4l2-ctl -d "$dev" --list-subdev-framesizes \
            pad="$SENSOR_PAD",stream="$SENSOR_SID",code="$selected_code" 2>/dev/null) || sizes=""
        supported=0
        while IFS= read -r line; do
            if [[ $line =~ $range_re ]]; then
                min_w=${BASH_REMATCH[1]}; min_h=${BASH_REMATCH[2]}
                max_w=${BASH_REMATCH[3]}; max_h=${BASH_REMATCH[4]}
                area=$(( max_w * max_h ))
                if (( area > largest_area )); then
                    largest_area=$area
                    largest_w=$max_w
                    largest_h=$max_h
                fi
                req_w=${requested_size%x*}; req_h=${requested_size#*x}
                if (( req_w >= min_w && req_w <= max_w && req_h >= min_h && req_h <= max_h )); then
                    supported=1
                fi
            elif [[ $line =~ Size:[[:space:]]Discrete[[:space:]]([0-9]+)x([0-9]+) ]]; then
                max_w=${BASH_REMATCH[1]}; max_h=${BASH_REMATCH[2]}
                area=$(( max_w * max_h ))
                if (( area > largest_area )); then
                    largest_area=$area
                    largest_w=$max_w
                    largest_h=$max_h
                fi
                req_w=${requested_size%x*}; req_h=${requested_size#*x}
                if (( req_w == max_w && req_h == max_h )); then
                    supported=1
                fi
            fi
        done <<<"$sizes"
        if [ -n "$sizes" ] && (( ! supported )); then
            printf "WARN: %s: resolution '%s' is unsupported with format '%s'; " \
                "$context" "$requested_size" "$selected_fmt" >&2
            if (( largest_area > 0 )); then
                selected_size="${largest_w}x${largest_h}"
                printf "using largest supported resolution '%s'\n" "$selected_size" >&2
            else
                printf "retaining current active resolution '%s'\n" "$active_size" >&2
                selected_size=$active_size
            fi
        fi
    fi

    echo "$selected_fmt $selected_size"
}

sensor_validate_fps() {
    local model=$1 cam=$2 stream=$3 sid=$4 fmt=$5 size=$6
    local requested_fps=$7 active_fps=$8 context=$9 dev codes line code name
    local format_size_changed=${10}
    local interval_args intervals candidate selected_fps max_fps supported=0

    selected_fps=${requested_fps:-$active_fps}
    sensor_entity_pad "$model" "$cam" "$stream" "$sid" || return 1
    dev=$(media-ctl -e "$SENSOR_ENTITY" 2>/dev/null) || {
        echo "$selected_fps"
        return
    }
    codes=$(v4l2-ctl -d "$dev" --list-subdev-mbus-codes \
        pad="$SENSOR_PAD",stream="$SENSOR_SID" 2>/dev/null) || {
        echo "$selected_fps"
        return
    }
    while IFS= read -r line; do
        if [[ $line =~ (0x[[:xdigit:]]+):[[:space:]]+MEDIA_BUS_FMT_([[:alnum:]_]+) ]]; then
            name=${BASH_REMATCH[2]^^}
            [ "$name" = "${fmt^^}" ] && code=${BASH_REMATCH[1]}
        fi
    done <<<"$codes"
    [ -n "$code" ] || { echo "$selected_fps"; return; }

    interval_args="pad=${SENSOR_PAD},stream=${SENSOR_SID},code=${code}"
    interval_args+=",width=${size%x*},height=${size#*x}"
    intervals=$(v4l2-ctl -d "$dev" --list-subdev-frameintervals \
        "$interval_args" 2>/dev/null) || intervals=""
    [ -n "$intervals" ] || { echo "$selected_fps"; return; }
    while IFS= read -r line; do
        if [[ $line =~ \(([0-9.]+)[[:space:]]fps\) ]]; then
            candidate=${BASH_REMATCH[1]}
            if [ -z "$max_fps" ] || awk -v a="$candidate" -v b="$max_fps" \
                'BEGIN { exit !(a > b) }'; then
                max_fps=$candidate
            fi
            awk -v a="$candidate" -v b="$selected_fps" \
                'BEGIN { exit !((a - b < 0.0005) && (b - a < 0.0005)) }' && {
                selected_fps=$candidate
                supported=1
            }
        fi
    done <<<"$intervals"
    if (( format_size_changed )) && [ -z "$requested_fps" ] && [ -n "$max_fps" ]; then
        selected_fps=$max_fps
    elif (( ! supported )) && [ -n "$max_fps" ]; then
        if (( format_size_changed )); then
            printf "WARN: %s: FPS '%s' is unsupported with %s/%s; " \
                "$context" "$selected_fps" "$fmt" "$size" >&2
            printf "using largest supported FPS '%s'\n" "$max_fps" >&2
            selected_fps=$max_fps
        else
            [ -z "$requested_fps" ] || printf \
                "WARN: %s: FPS '%s' is unsupported; retaining active FPS '%s'\n" \
                "$context" "$requested_fps" "$active_fps" >&2
            selected_fps=$active_fps
        fi
    fi
    echo "$selected_fps"
}

sensor_set_fps() {
    local model=$1 cam=$2 stream=$3 sid=$4 fps=$5 context=$6 dev output

    sensor_entity_pad "$model" "$cam" "$stream" "$sid" || return 1
    dev=$(media-ctl -e "$SENSOR_ENTITY" 2>/dev/null) || return 1
    v4l2-ctl -d "$dev" --set-subdev-fps \
        pad="$SENSOR_PAD",stream="$SENSOR_SID",fps="$fps" >/dev/null \
        || { echo "WARN: ${context}: failed to set FPS '${fps}'" >&2; return 1; }
    output=$(v4l2-ctl -d "$dev" --get-subdev-fps \
        pad="$SENSOR_PAD",stream="$SENSOR_SID" 2>/dev/null) || return 1
    [[ $output =~ Frames[[:space:]]per[[:space:]]second:[[:space:]]([0-9.]+) ]] \
        || return 1
    echo "${BASH_REMATCH[1]}"
}

# Is stream token $1 selectable for model $2?
stream_valid_for_model() {
    local s=$1 streams=${MODEL_STREAMS[$2]:-} t
    [ -n "$streams" ] || return 1
    for t in $streams; do
        [ "$t" = "$s" ] && return 0
    done
    return 1
}

# Is $1 a known stream token (in any model)?
is_known_stream() { [ -n "${STREAM_NODE[$1]+x}" ]; }

die() { echo "ERROR: $*" >&2; exit 1; }

check_media_tools() {
    local missing=() tool
    for tool in media-ctl v4l2-ctl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0

    echo "Missing required command(s): ${missing[*]}; installing v4l-utils..." >&2
    command -v apt-get >/dev/null 2>&1 \
        || die "apt-get not found; install v4l-utils manually"

    local apt=(apt-get)
    if (( EUID != 0 )); then
        command -v sudo >/dev/null 2>&1 \
            || die "root privileges are required to install v4l-utils"
        apt=(sudo apt-get)
    fi
    "${apt[@]}" install -y v4l-utils \
        || die "failed to install v4l-utils"

    for tool in media-ctl v4l2-ctl; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "$tool is still unavailable after installing v4l-utils"
    done
}

# Require media-ctl >= 1.30 (older releases lack the streams/routing API used here).
check_media_ctl_version() {
    local required_major=1 required_minor=30

    local ver
    ver=$(media-ctl --version 2>/dev/null | awk '/^media-ctl[[:space:]]+[0-9]+\./ {print $2; exit}')
    [[ -n $ver ]] || die "unable to determine media-ctl version (\`media-ctl --version\`)"

    local major minor
    major=${ver%%.*}
    minor=${ver#*.}; minor=${minor%%.*}; minor=${minor%%-*}
    [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] \
        || die "unable to parse media-ctl version: '$ver'"

    if (( major < required_major )) || \
       (( major == required_major && minor < required_minor )); then
        die "media-ctl ${ver} is too old; ${required_major}.${required_minor} or newer is required"
    fi
}

# -------- main ----------------------------------------------------------------

check_media_tools
check_media_ctl_version
discover || exit 1

[ "$NUM_DES"  -gt 0 ] && { detect_gmsl_csi2 || exit 1; }
[ "$NUM_MIPI" -gt 0 ] && { detect_mipi_csi2 || exit 1; }
# Probe the source stream the live sensor driver exposes. ar0234 built with
# CONFIG_VIDEO_ZEDX uses stream 1 for the ZED X secondary sensor (not 0x10).
probe_sensor_sid() {
    local model=$1 cam=$2 sid
    case "$model" in
        ar0234)
            for sid in 0 1 2 3; do
                sensor_active_format "$model" "$cam" single "$sid" >/dev/null \
                    && { echo "$sid"; return 0; }
            done
            return 1
            ;;
    esac
    return 1
}

for ckey in "${!CAM_MODEL[@]}"; do
    if sid=$(probe_sensor_sid "${CAM_MODEL[$ckey]}" "${CAM_BA[$ckey]}"); then
        CAM_SID[$ckey]=$sid
    fi
done

print_topology

# ---- GMSL programming (DES-based cameras) -----------------------------------
# Steps below (argument parsing, pad computation, route setup, format
# propagation, capture-node format) apply only to GMSL deserializer cameras.
# Direct MIPI cameras are handled separately by setup_mipi_cameras() at the end.

# CFG entry $1 -> camera key "d_l_p".
cfg_ckey() { echo "${CFG_DES[$1]}_${CFG_LINKS[$1]}_${CFG_PHYS[$1]}"; }

# CFG entry $1 -> human-readable location ("DES0 link 1[ PHY 0]").
cfg_where() {
    local key="${CFG_DES[$1]}_${CFG_LINKS[$1]}" w
    w="DES${CFG_DES[$1]} link ${CFG_LINKS[$1]}"
    (( SER_NPHYS[$key] > 1 )) && w+=" PHY ${CFG_PHYS[$1]}"
    echo "$w"
}

# Sensor source stream of camera $1 for stream token $2.
sensor_sid() { echo "${CAM_SID[$1]:-${STREAM_NODE[$2]}}"; }

# ---- argument parsing ------------------------------------------------------

# Each CFG entry is identified by (des_idx, link_idx, phy_idx) and carries a
# streams list.
declare -a CFG_DES=()
declare -a CFG_LINKS=()
declare -a CFG_PHYS=()
declare -a CFG_STREAMS=()
declare -a CFG_RES=()
declare -a CFG_FORMAT=()
declare -a CFG_FPS=()
declare -A CFG_STREAM_RES=()
declare -A CFG_STREAM_FORMAT=()
declare -A CFG_STREAM_FPS_REQUEST=()
# CFG entries whose streams came from MODEL_DEFAULT_STREAMS.
declare -A CFG_DEFAULT_STREAMS=()

if [ "$#" -eq 0 ]; then
    # Default: program every discovered camera with its default or fixed stream.
    for ((d = 0; d < NUM_DES; d++)); do
        for l in ${LINKS_OF[$d]}; do
            key="${d}_${l}"
            for p in ${PHYS_OF[$key]}; do
                CFG_DES+=("$d")
                CFG_LINKS+=("$l")
                CFG_PHYS+=("$p")
                model=${CAM_MODEL[${key}_${p}]}
                streams=${MODEL_DEFAULT_STREAMS[$model]:-}
                [ -n "$streams" ] || streams=$(fixed_stream_for_model "$model") \
                    || die "no stream configuration for $model"
                CFG_DEFAULT_STREAMS[${#CFG_STREAMS[@]}]=1
                CFG_STREAMS+=("$streams")
                CFG_RES+=("")
                CFG_FORMAT+=("")
                CFG_FPS+=("")
            done
        done
    done
else
    for arg in "$@"; do
        des=""; link=""; phy=""; streams=""; res=""; format=""; fps=""
        declare -A arg_stream_res=()
        declare -A arg_stream_format=()
        declare -A arg_stream_fps=()

        # Parse bracketed per-stream settings before splitting the remaining
        # link-level options on commas.
        if [[ $arg == *",stream=["* ]]; then
            stream_specs=${arg#*,stream=}
            arg=${arg%%,stream=*}
            while [ -n "$stream_specs" ]; do
                stream_specs=${stream_specs#"${stream_specs%%[![:space:]]*}"}
                if [[ $stream_specs =~ ^\[([^][]+)\](,(.*))?$ ]]; then
                    stream_spec=${BASH_REMATCH[1]}
                    stream_specs=${BASH_REMATCH[3]}
                else
                    die "invalid bracketed stream specification in '$stream_specs'"
                fi

                IFS=',' read -ra stream_parts <<<"$stream_spec"
                for stream_part_idx in "${!stream_parts[@]}"; do
                    stream_part=${stream_parts[$stream_part_idx]}
                    stream_part=${stream_part#"${stream_part%%[![:space:]]*}"}
                    stream_parts[$stream_part_idx]=${stream_part%"${stream_part##*[![:space:]]}"}
                done
                s=${stream_parts[0]}
                is_known_stream "$s" || die "unknown stream '$s' in '$stream_spec'"
                [ -z "${arg_stream_res[$s]+x}" ] && \
                    [ -z "${arg_stream_format[$s]+x}" ] && \
                    [[ " $streams " != *" $s "* ]] \
                    || die "stream '$s' specified more than once"
                streams+="${streams:+ }$s"
                for stream_kv in "${stream_parts[@]:1}"; do
                    case "$stream_kv" in
                        res=*)
                            arg_stream_res[$s]=${stream_kv#res=}
                            [[ ${arg_stream_res[$s]} =~ ^[0-9]+x[0-9]+$ ]] \
                                || die "res must be WIDTHxHEIGHT (got '${arg_stream_res[$s]}')"
                            ;;
                        format=*)
                            arg_stream_format[$s]=${stream_kv#format=}
                            [[ ${arg_stream_format[$s]} =~ ^[[:alnum:]_]+$ ]] \
                                || die "format must be a media-bus code" \
                                    "(got '${arg_stream_format[$s]}')"
                            ;;
                        fps=*)
                            arg_stream_fps[$s]=${stream_kv#fps=}
                            [[ ${arg_stream_fps[$s]} =~ ^[0-9]+([.][0-9]+)?$ ]] \
                                || die "fps must be numeric (got '${arg_stream_fps[$s]}')"
                            ;;
                        *) die "unrecognized stream option '$stream_kv' in '$stream_spec'" ;;
                    esac
                done
            done
        fi

        IFS=',' read -ra parts <<<"$arg"
        for kv in "${parts[@]}"; do
            case "$kv" in
                des=*)    des=${kv#des=} ;;
                link=*)   link=${kv#link=} ;;
                phy=*)    phy=${kv#phy=} ;;
                stream=*) streams+="${streams:+ }${kv#stream=}" ;;
                res=*)    res=${kv#res=} ;;
                format=*) format=${kv#format=} ;;
                fps=*)    fps=${kv#fps=} ;;
                *)
                    if is_known_stream "$kv"; then
                        streams+="${streams:+ }$kv"
                    else
                        die "unrecognized token '$kv' in '$arg'"
                    fi
                    ;;
            esac
        done
        [ -n "$link" ]    || die "missing link= in '$arg'"
        [[ $link =~ ^[0-9]+$ ]] || die "link must be numeric (got '$link')"
        [ -z "$res" ] || [[ $res =~ ^[0-9]+x[0-9]+$ ]] \
            || die "res must be WIDTHxHEIGHT (got '$res')"
        [ -z "$format" ] || [[ $format =~ ^[[:alnum:]_]+$ ]] \
            || die "format must be a media-bus code (got '$format')"
        [ -z "$fps" ] || [[ $fps =~ ^[0-9]+([.][0-9]+)?$ ]] \
            || die "fps must be numeric (got '$fps')"
        # Default des=0 when only one DES is present and des= was omitted.
        if [ -z "$des" ]; then
            if [ "$NUM_DES" -gt 1 ]; then
                die "des= required when multiple deserializers are present (in '$arg')"
            fi
            des=0
        fi
        [[ $des =~ ^[0-9]+$ ]] || die "des must be numeric (got '$des')"
        (( des < NUM_DES )) || die "des=$des out of range (have ${NUM_DES} DES)"
        [ -z "$phy" ] || [[ $phy =~ ^[0-9]+$ ]] || die "phy must be numeric (got '$phy')"
        key="${des}_${link}"
        [ -n "${PHYS_OF[$key]:-}" ] || die "no camera discovered on DES${des} link ${link}"
        # phy= selects one camera of a multi-PHY serializer; otherwise the
        # entry applies to every camera discovered on the link.
        target_phys=${phy:-${PHYS_OF[$key]}}
        req_streams=$streams
        for p in $target_phys; do
            ckey="${key}_${p}"
            where="DES${des} link ${link}"
            (( SER_NPHYS[$key] > 1 )) && where+=" PHY ${p}"
            [ -n "${CAM_MODEL[$ckey]:-}" ] || die "no camera discovered on ${where}"
            model=${CAM_MODEL[$ckey]}
            streams=$req_streams
            if [ -n "${MODEL_STREAMS[$model]:-}" ]; then
                if [ -z "$streams" ]; then
                    streams=${MODEL_DEFAULT_STREAMS[$model]}
                    # A link-level res/format applies to every stream; don't
                    # risk applying it to optional streams too.
                    [ -n "$res$format" ] || \
                        CFG_DEFAULT_STREAMS[${#CFG_STREAMS[@]}]=1
                fi
                for s in $streams; do
                    stream_valid_for_model "$s" "$model" \
                        || die "stream '$s' invalid for $model on ${where}"
                done
            else
                fixed_stream=$(fixed_stream_for_model "$model") \
                    || die "no stream configuration for $model"
                if [ -n "$streams" ] && [ "$streams" != "$fixed_stream" ]; then
                    echo "WARN: $model on ${where}: replacing requested" \
                        "stream '$streams' with fixed stream '$fixed_stream'" >&2
                fi
                streams=$fixed_stream
            fi
            CFG_DES+=("$des")
            CFG_LINKS+=("$link")
            CFG_PHYS+=("$p")
            CFG_STREAMS+=("$streams")
            CFG_RES+=("$res")
            CFG_FORMAT+=("$format")
            CFG_FPS+=("$fps")
            k=$((${#CFG_LINKS[@]} - 1))
            for s in $streams; do
                CFG_STREAM_RES["${k}_${s}"]=${arg_stream_res[$s]:-}
                CFG_STREAM_FORMAT["${k}_${s}"]=${arg_stream_format[$s]:-}
                CFG_STREAM_FPS_REQUEST["${k}_${s}"]=${arg_stream_fps[$s]:-${CFG_FPS[$k]}}
            done
        done
        unset arg_stream_res arg_stream_format arg_stream_fps
    done
    # Reject duplicate (des,link,phy) entries.
    declare -A seen=()
    for k in "${!CFG_LINKS[@]}"; do
        sk="${CFG_DES[$k]}_${CFG_LINKS[$k]}_${CFG_PHYS[$k]}"
        [ -z "${seen[$sk]:-}" ] || die "DES${CFG_DES[$k]} link ${CFG_LINKS[$k]}" \
            "PHY ${CFG_PHYS[$k]} specified more than once"
        seen[$sk]=1
    done
fi

# Capture-node offset (csi2_pad) of stream $1 on link $2 for cameras that are
# not behind a multi-PHY serializer.
stream_csi2_pad() {
    echo $(( STREAM_CAPTURE_BASE[$1] +
        ($2 + STREAM_LINK_ROTATION[$1]) % CSI2_NODE_BANK_SIZE ))
}

# Append MODEL_OPTIONAL_DEFAULT_STREAMS to default-stream entries while the
# deserializer has a spare source_stream and the capture node is free.
for k in "${!CFG_LINKS[@]}"; do
    [ -n "${CFG_DEFAULT_STREAMS[$k]:-}" ] || continue
    d=${CFG_DES[$k]}
    l=${CFG_LINKS[$k]}
    (( SER_NPHYS[${d}_${l}] > 1 )) && continue
    model=${CAM_MODEL[$(cfg_ckey "$k")]}
    for s in ${MODEL_OPTIONAL_DEFAULT_STREAMS[$model]:-}; do
        pad=$(stream_csi2_pad "$s" "$l")
        okey=$(cfg_okey "$k")
        n=0
        free=1
        for j in "${!CFG_LINKS[@]}"; do
            [ "$(cfg_okey "$j")" = "$okey" ] || continue
            for t in ${CFG_STREAMS[$j]}; do
                n=$(( n + 1 ))
                (( SER_NPHYS[${d}_${CFG_LINKS[$j]}] > 1 )) && continue
                [ "$(stream_csi2_pad "$t" "${CFG_LINKS[$j]}")" = "$pad" ] && free=0
            done
        done
        (( free && n < 4 )) || continue
        CFG_STREAMS[$k]+=" $s"
        CFG_STREAM_FPS_REQUEST["${k}_${s}"]=${CFG_FPS[$k]:-}
    done
done

# Resolve and validate each selected stream's format, size and FPS. Unsupported
# FPS requests retain the active FPS when format/size stay unchanged. After an
# effective format/size change, an unsupported or omitted FPS uses the largest
# FPS advertised for the new mode.
declare -A CFG_STREAM_FMT=()
declare -A CFG_STREAM_PIXFMT=()
declare -A CFG_STREAM_SIZE=()
declare -A CFG_STREAM_FPS=()
declare -A CFG_STREAM_FPS_APPLY=()
for k in "${!CFG_LINKS[@]}"; do
    d=${CFG_DES[$k]}
    l=${CFG_LINKS[$k]}
    ckey=$(cfg_ckey "$k")
    model=${CAM_MODEL[$ckey]}
    cam=${CAM_BA[$ckey]}
    where=$(cfg_where "$k")
    for s in ${CFG_STREAMS[$k]}; do
        sid=$(sensor_sid "$ckey" "$s")
        requested_fmt=${CFG_STREAM_FORMAT["${k}_${s}"]:-${CFG_FORMAT[$k]}}
        requested_size=${CFG_STREAM_RES["${k}_${s}"]:-${CFG_RES[$k]}}
        if [ -n "$requested_fmt" ] || [ -n "$requested_size" ] ||
            [ -n "${CFG_STREAM_FPS_REQUEST["${k}_${s}"]}" ]; then
            CFG_STREAM_FPS_APPLY["${k}_${s}"]=1
        fi
        detected=$(sensor_active_format "$model" "$cam" "$s" "$sid") || \
            die "cannot read active format from ${model} sensor on" \
                "${where}, stream ${s}"
        read -r detected_fmt detected_size <<<"$detected"
        validated=$(sensor_validate_format_size "$model" "$cam" "$s" "$sid" \
            "$requested_fmt" "$requested_size" "$detected_fmt" "$detected_size" \
            "${where} stream ${s}")
        read -r selected_fmt CFG_STREAM_SIZE["${k}_${s}"] <<<"$validated"
        CFG_STREAM_PIXFMT["${k}_${s}"]=$(mbus_to_pixfmt "$selected_fmt")
        format_key="${model}_${s}_${selected_fmt}"
        CFG_STREAM_FMT["${k}_${s}"]=${STREAM_FORMAT_MAP[$format_key]:-$selected_fmt}
        format_size_changed=0
        if [ "${CFG_STREAM_FMT["${k}_${s}"]}" != "$detected_fmt" ] || \
            [ "${CFG_STREAM_SIZE["${k}_${s}"]}" != "$detected_size" ]; then
            format_size_changed=1
        fi
        active_fps=$(sensor_active_fps "$model" "$cam" "$s" "$sid") || active_fps=""
        if [ -n "$active_fps" ]; then
            CFG_STREAM_FPS["${k}_${s}"]=$(sensor_validate_fps \
                "$model" "$cam" "$s" "$sid" \
                "${CFG_STREAM_FMT["${k}_${s}"]}" \
                "${CFG_STREAM_SIZE["${k}_${s}"]}" \
                "${CFG_STREAM_FPS_REQUEST["${k}_${s}"]}" "$active_fps" \
                "${where} stream ${s}" "$format_size_changed")
        else
            [ -z "${CFG_STREAM_FPS_REQUEST["${k}_${s}"]}" ] || \
                echo "WARN: ${where} stream ${s}: FPS control unavailable" >&2
            CFG_STREAM_FPS["${k}_${s}"]="n/a"
            CFG_STREAM_FPS_REQUEST["${k}_${s}"]=""
        fi
    done
done

# IPU7 CSI2 RX source-pad cap (16 with the D4XX patch, 8 otherwise).
IPU_CSI2_SRC_PADS=${IPU_CSI2_SRC_PADS:-16}

# Compute csi2_pad per (cfg_index, stream) using the configured capture bank
# and link rotation. For isx031 this collapses to csi2_pad == link.
declare -A CSI2_PAD=()
declare -A CSI2_PAD_OWNER=()
# Compact v4l2 source_stream id assigned to each (cfg_index, stream) at the
# deserializer source pad and at the CSI2 sink pad. The kernel-side max96724
# / max_des state machine bounds the per-pipe stream-id field at 2 bits
# (MAX_SERDES_STREAMS_NUM=4), so any v4l2 source_stream tag >=4 trips an
# EINVAL on set_fmt. We therefore allocate per-DES sequential ids 0..3
# independent of the (larger) csi2_pad values used downstream.
declare -A DES_STREAM=()
declare -A DES_STREAM_USED=()

# Fixed per-DES slot of every camera declared under the DES (populated or
# not), in ACPI path order; each camera occupies as many slots as its default
# stream count. Used for cameras behind multi-PHY serializers (ZED X).
declare -A ACPI_SLOT=()
for ((d = 0; d < NUM_DES; d++)); do
    n=0
    while read -r cp model; do
        ACPI_SLOT[$cp]=$n
        ns=${MODEL_DEFAULT_STREAMS[$model]:-$(fixed_stream_for_model "$model")}
        ns=($ns)
        n=$(( n + ${#ns[@]} ))
    done < <(for dir in /sys/bus/acpi/devices/*; do
                 cp=$(cat "$dir/path" 2>/dev/null) || continue
                 [[ $cp == "${DES_PATH[$d]}".* ]] || continue
                 hid=$(acpi_hid "$dir")
                 [ -n "$hid" ] || continue
                 model=${SENSOR_MODEL[$hid]:-}
                 [ -n "$model" ] && echo "$cp $model"
             done | sort)
done

# Claim csi2_pad $3 and deserializer source_stream $4 for CFG entry $1 stream $2.
# Both are tracked per DES output: each output has its own IPU CSI2 entity
# (capture nodes) and its own DES PHY (VC ids are allocated per PHY by
# max_des), so source_stream 0..3 restarts on every output.
claim_stream() {
    local k=$1 s=$2 pad=$3 ds=$4 d=${CFG_DES[$1]} okey where
    okey=$(cfg_okey "$k")
    where="$(cfg_where "$k") stream ${s}"
    if (( pad >= IPU_CSI2_SRC_PADS )); then
        die "${where}: csi2_pad ${pad} exceeds CSI2 src-pad cap "\
        "(${IPU_CSI2_SRC_PADS}); reduce active links/streams or rebuild the kernel with a "\
        "higher *_NR_OF_CSI2_SRC_PADS"
    fi
    if [ -n "${CSI2_PAD_OWNER[${okey}_${pad}]:-}" ]; then
        die "${where}: capture node offset ${pad} conflicts with "\
        "${CSI2_PAD_OWNER[${okey}_${pad}]}"
    fi
    if (( ds >= 4 )); then
        die "DES${d}: too many streams routed through deserializer source pad "\
        "${OUT_SRC_PAD[$okey]} (maxim-serdes supports 4 unique source_streams)"
    fi
    if [ -n "${DES_STREAM_USED[${okey}_${ds}]:-}" ]; then
        die "${where}: deserializer source_stream ${ds} conflicts with "\
        "${DES_STREAM_USED[${okey}_${ds}]}"
    fi
    CSI2_PAD_OWNER[${okey}_${pad}]=$where
    DES_STREAM_USED[${okey}_${ds}]=$where
    CSI2_PAD["${k}_${s}"]=$pad
    DES_STREAM["${k}_${s}"]=$ds
}

# Multi-PHY serializer cameras first: csi2_pad == source_stream == ACPI slot.
for k in "${!CFG_LINKS[@]}"; do
    (( SER_NPHYS[${CFG_DES[$k]}_${CFG_LINKS[$k]}] > 1 )) || continue
    ckey=$(cfg_ckey "$k")
    slot=${ACPI_SLOT[${CAM_PATH[$ckey]}]:-}
    [ -n "$slot" ] || die "$(cfg_where "$k"): no ACPI slot for ${CAM_PATH[$ckey]}"
    for s in ${CFG_STREAMS[$k]}; do
        claim_stream "$k" "$s" "$slot" "$slot"
        slot=$(( slot + 1 ))
    done
done

# Remaining cameras: capture bank/rotation layout and the lowest free
# deserializer source_stream.
for k in "${!CFG_LINKS[@]}"; do
    d=${CFG_DES[$k]}
    l=${CFG_LINKS[$k]}
    (( SER_NPHYS[${d}_${l}] > 1 )) && continue
    for s in ${CFG_STREAMS[$k]}; do
        pad=$(stream_csi2_pad "$s" "$l")
        okey=$(cfg_okey "$k")
        ds=0
        while [ -n "${DES_STREAM_USED[${okey}_${ds}]:-}" ]; do ds=$(( ds + 1 )); done
        claim_stream "$k" "$s" "$pad" "$ds"
    done
done

# Reset all media links and per-stream pad state so we don't inherit formats
# or enabled-link flags from a prior run with a different layout.
media-ctl -r 2>/dev/null || true

echo -e "\nConfiguration summary:"
for k in "${!CFG_LINKS[@]}"; do
    d=${CFG_DES[$k]}
    l=${CFG_LINKS[$k]}
    ckey=$(cfg_ckey "$k")
    label="LINK${l}"
    (( SER_NPHYS[${d}_${l}] > 1 )) && label+=" PHY${CFG_PHYS[$k]}"
    echo -e "  DES${d} ${label}\t Sensor model\t ${CAM_MODEL[$ckey]}"
    for s in ${CFG_STREAMS[$k]}; do
        csi2_pad=${CSI2_PAD["${k}_${s}"]}
        node=$(( OUT_CAPBASE[$(cfg_okey "$k")] + csi2_pad ))
        vid_node=$(( node + VID_DEV_OFFSET ))
        printf "                 Stream          %-8s %-10s %-12s %7s FPS -->  /dev/video%s\n" \
            "[${s}]" "${CFG_STREAM_SIZE["${k}_${s}"]}" \
            "${CFG_STREAM_FMT["${k}_${s}"]}" \
            "${CFG_STREAM_FPS["${k}_${s}"]}" "$vid_node"
    done
done

# ---- programming -----------------------------------------------------------

# Per-CFG-entry serializer stream layout, set by cfg_ser_layout():
#   SER_SINK_PAD  serializer sink pad (PHY) the camera is linked to
#   SER_SRC_PAD   serializer source pad (== PHY count)
# and, per stream token, by cfg_ser_streams():
#   SER_SINK_SID  stream id on the serializer sink pad (== upstream source
#                 stream: d4xx mux source stream, or the sensor source stream)
#   SER_SRC_SID   stream id on the serializer source pad / deserializer sink
#                 pad. Multi-PHY serializers (MAX9295D) number it after the
#                 sink pad / pipe, so two cameras never share a stream id.
cfg_ser_layout() {
    local k=$1 key="${CFG_DES[$1]}_${CFG_LINKS[$1]}"
    SER_SINK_PAD=${CAM_SER_PAD[$(cfg_ckey "$k")]}
    SER_SRC_PAD=${SER_NPHYS[$key]}
}
cfg_ser_streams() {
    local k=$1 s=$2 key="${CFG_DES[$1]}_${CFG_LINKS[$1]}" ckey model
    ckey=$(cfg_ckey "$k")
    model=${CAM_MODEL[$ckey]}
    if [ "$model" = d4xx ]; then
        SER_SINK_SID=${STREAM_NODE[$s]}
    else
        SER_SINK_SID=$(sensor_sid "$ckey" "$s")
    fi
    if (( SER_NPHYS[$key] > 1 )); then
        SER_SRC_SID=$SER_SINK_PAD
    else
        SER_SRC_SID=${STREAM_NODE[$s]}
    fi
}

# Is CFG entry $1 a ZED X camera (ar0234 behind a multi-PHY serializer)?
cfg_is_zedx() {
    [ "${CAM_MODEL[$(cfg_ckey "$1")]}" = ar0234 ] &&
        (( SER_NPHYS[${CFG_DES[$1]}_${CFG_LINKS[$1]}] > 1 ))
}

# Per-DES route accumulators (the kernel resets per-stream pad formats whenever
# routes are (re)programmed, so all -R must precede any -V). Serializer routes
# are accumulated per serializer too, since a multi-PHY serializer is shared
# by several cameras and must be programmed in a single call.
declare -A DES_ROUTES=()
declare -A CSI2_ROUTES=()
declare -A SER_ROUTES=()

# --- pass 1: per-camera source-side routes (mux/serializer), and accumulate
#             per-DES deserializer/CSI2 routes.
for k in "${!CFG_LINKS[@]}"; do
    d=${CFG_DES[$k]}
    l=${CFG_LINKS[$k]}
    key="${d}_${l}"
    ckey=$(cfg_ckey "$k")
    model=${CAM_MODEL[$ckey]}
    cam=${CAM_BA[$ckey]}
    ser=${SER_BA[$key]}
    ser_pfx=${SER_PFX[$key]}
    sel_streams=(${CFG_STREAMS[$k]})
    cfg_ser_layout "$k"

    # Stream IDs along the mux->serializer->deserializer chain are fixed
    # per sensor sub-stream (see STREAM_NODE): depth=0, rgb=1, ir=2, imu=3,
    # single=0. The d4xx driver in particular asserts that the route's
    # source_stream on the mux matches the sensor's hard-coded vc_id, so
    # we must use STREAM_NODE[$s] -- not a sequential 0..n-1 index -- as
    # the stream identifier everywhere downstream of the sensor.

    case "$model" in
        d4xx)
            declare -A is_selected=()
            for s in "${sel_streams[@]}"; do is_selected[$s]=1; done

            mux_route_parts=()
            for s in depth rgb ir imu; do
                sid=${STREAM_NODE[$s]}
                if [ -n "${is_selected[$s]:-}" ]; then
                    mux_route_parts+=("${STREAM_MUXPAD[$s]}/0->0/${sid}[1]")
                else
                    mux_route_parts+=("${STREAM_MUXPAD[$s]}/0->0/${sid}[0]")
                fi
            done
            mux_routes=$(IFS=,; echo "${mux_route_parts[*]}")

            mc_l "\"DS5 mux ${cam}\":0 -> \"${ser_pfx} ${ser}\":${SER_SINK_PAD}[1]"
            mc_R "\"DS5 mux ${cam}\" [${mux_routes}]"

            unset is_selected
            ;;
    esac

    for s in "${sel_streams[@]}"; do
        cfg_ser_streams "$k" "$s"
        SER_ROUTES[$key]+="${SER_ROUTES[$key]:+,}${SER_SINK_PAD}/${SER_SINK_SID}->${SER_SRC_PAD}/${SER_SRC_SID}[1]"
        csi2_pad=${CSI2_PAD["${k}_${s}"]}
        des_stream=${DES_STREAM["${k}_${s}"]}
        okey=$(cfg_okey "$k")
        DES_ROUTES[$d]+="${DES_ROUTES[$d]:+,}${l}/${SER_SRC_SID}->${OUT_SRC_PAD[$okey]}/${des_stream}[1]"
        CSI2_ROUTES[$okey]+="${CSI2_ROUTES[$okey]:+,}0/${des_stream}->$((csi2_pad + 1))/0[1]"
    done
done

# Apply per-serializer route tables.
for key in "${!SER_ROUTES[@]}"; do
    mc_R "\"${SER_PFX[$key]} ${SER_BA[$key]}\" [${SER_ROUTES[$key]}]"
done

# Apply per-DES route tables. A dual-output DES gets a single routing table
# covering both source pads (max_des rejects set_routing while streaming),
# then one table per IPU CSI2 entity.
for ((d = 0; d < NUM_DES; d++)); do
    [ -n "${DES_ROUTES[$d]:-}" ] || continue
    mc_R "\"${DES_PREFIX_NAME[$d]} ${DES_BA[$d]}\" [${DES_ROUTES[$d]}]"
    for ((o = 0; o < DES_NOUT[$d]; o++)); do
        okey="${d}_${o}"
        [ -n "${CSI2_ROUTES[$okey]:-}" ] || continue
        mc_R "\"${OUT_CSI2[$okey]}\" [${CSI2_ROUTES[$okey]}]"
    done
done

# CSI2 source pad -> ISYS Capture entity link (must exist before formats flow).
for k in "${!CFG_LINKS[@]}"; do
    okey=$(cfg_okey "$k")
    for s in ${CFG_STREAMS[$k]}; do
        csi2_pad=${CSI2_PAD["${k}_${s}"]}
        node=$(( OUT_CAPBASE[$okey] + csi2_pad ))
        mc_l "\"${OUT_CSI2[$okey]}\":$((csi2_pad + 1)) -> \"${OUT_IPU_BASE[$okey]} ISYS Capture ${node}\":0[1]"
    done
done

# --- pass 2: format propagation (all routes are now in place).

for k in "${!CFG_LINKS[@]}"; do
    d=${CFG_DES[$k]}
    l=${CFG_LINKS[$k]}
    key="${d}_${l}"
    ckey=$(cfg_ckey "$k")
    model=${CAM_MODEL[$ckey]}
    cam=${CAM_BA[$ckey]}
    ser=${SER_BA[$key]}
    ser_pfx=${SER_PFX[$key]}
    sel_streams=(${CFG_STREAMS[$k]})
    where=$(cfg_where "$k")
    cfg_ser_layout "$k"

    for s in "${sel_streams[@]}"; do
        sid=$(sensor_sid "$ckey" "$s")
        cfg_ser_streams "$k" "$s"
        csi2_pad=${CSI2_PAD["${k}_${s}"]}
        des_stream=${DES_STREAM["${k}_${s}"]}
        fmt=${CFG_STREAM_FMT["${k}_${s}"]}
        size=${CFG_STREAM_SIZE["${k}_${s}"]}

        case "$model" in
            d4xx)
                mc_v "\"D4XX ${s} ${cam}\":0/0 [fmt:${fmt}/${size} field:none]"
                ;;
            isx031)
                mc_v "\"isx031 ${cam}\":0/${sid} [fmt:${fmt}/${size} field:none]"
                ;;
            ar0234)
                mc_v "\"ar0234 ${cam}\":0/${sid} [fmt:${fmt}/${size} field:none]"
                ;;
            ov13b10)
                mc_v "\"ov13b10 ${cam}\":0/${sid} [fmt:${fmt}/${size} field:none]"
                ;;
        esac
            fps=${CFG_STREAM_FPS["${k}_${s}"]}
            if [ -n "${CFG_STREAM_FPS_APPLY["${k}_${s}"]:-}" ] &&
                [[ $fps =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                actual_fps=$(sensor_set_fps "$model" "$cam" "$s" "$sid" \
                    "$fps" \
                    "${where} stream ${s}") || \
                    die "cannot configure FPS on ${where}, stream ${s}"
                CFG_STREAM_FPS["${k}_${s}"]=$actual_fps
            fi
        mc_v "\"${ser_pfx} ${ser}\":${SER_SINK_PAD}/${SER_SINK_SID} [fmt:${fmt}/${size} field:none]"
        mc_v "\"${ser_pfx} ${ser}\":${SER_SRC_PAD}/${SER_SRC_SID} [fmt:${fmt}/${size} field:none]"
        mc_v "\"${DES_PREFIX_NAME[$d]} ${DES_BA[$d]}\":${l}/${SER_SRC_SID} [fmt:${fmt}/${size} field:none]"
        okey=$(cfg_okey "$k")
        mc_v "\"${DES_PREFIX_NAME[$d]} ${DES_BA[$d]}\":${OUT_SRC_PAD[$okey]}/${des_stream} [fmt:${fmt}/${size} field:none]"
        mc_v "\"${OUT_CSI2[$okey]}\":0/${des_stream} [fmt:${fmt}/${size} field:none]"
        mc_v "\"${OUT_CSI2[$okey]}\":$((csi2_pad + 1))/0 [fmt:${fmt}/${size} field:none]"
    done
done

# ---- v4l2-ctl: capture-node format -----------------------------------------

for k in "${!CFG_LINKS[@]}"; do
    okey=$(cfg_okey "$k")
    for s in ${CFG_STREAMS[$k]}; do
        node=$(( OUT_CAPBASE[$okey] + CSI2_PAD["${k}_${s}"] ))
        vid_node=$(( node + VID_DEV_OFFSET ))
        pixfmt=${CFG_STREAM_PIXFMT["${k}_${s}"]}
        [ -z "$pixfmt" ] && continue
        size=${CFG_STREAM_SIZE["${k}_${s}"]}
        w=${size%x*}
        h=${size#*x}
        v4l2-ctl -d "/dev/video${vid_node}" \
            --set-fmt-video="width=${w},height=${h},pixelformat=${pixfmt}" \
            >/dev/null || die "cannot set /dev/video${vid_node} to ${pixfmt} ${size}"
    done
done

# ---- ZED X (ar0234 behind a multi-PHY serializer) ---------------------------
# Enable stereo frame sync, prepare PSYS for the camera HAL (RAW Bayer), and
# publish /dev/video-ar0234-<a..h>-<csi2> links: a..d = link 0..3 on PHY 0,
# e..h = link 0..3 on PHY 1.
zedx_used=0
for k in "${!CFG_LINKS[@]}"; do
    cfg_is_zedx "$k" || continue
    zedx_used=1
    d=${CFG_DES[$k]}
    l=${CFG_LINKS[$k]}
    if [ "${CFG_PHYS[$k]}" -ne 0 ]; then
        suffix=$(echo "$l" | tr '0-3' 'e-h')
    else
        suffix=$(echo "$l" | tr '0-3' 'a-d')
    fi
    okey=$(cfg_okey "$k")
    for s in ${CFG_STREAMS[$k]}; do
        vid_node=$(( OUT_CAPBASE[$okey] + CSI2_PAD["${k}_${s}"] + VID_DEV_OFFSET ))
        ln -snf "/dev/video${vid_node}" \
            "/dev/video-ar0234-${suffix}-${OUT_CSI2[$okey]: -1}" ||
            echo "WARN: cannot create /dev/video-ar0234-${suffix} link" >&2
    done
done
if (( zedx_used )); then
    ZEDX_FRAME_SYNC=${ZEDX_FRAME_SYNC-1}
    if [ -n "$ZEDX_FRAME_SYNC" ]; then
        echo "$ZEDX_FRAME_SYNC" > /sys/module/ar0234/parameters/frame_sync ||
            echo "WARN: cannot set ar0234 frame_sync=${ZEDX_FRAME_SYNC}" >&2
    fi
    psys=intel-${PREFIX,,}-psys
    modprobe "$psys" || echo "WARN: cannot load ${psys}" >&2
    mkdir -p /run/camera && chown root:video /run/camera && chmod 777 /run/camera ||
        echo "WARN: cannot prepare /run/camera" >&2
    if [ -e "/dev/${PREFIX,,}-psys0" ]; then
        chown root:video "/dev/${PREFIX,,}-psys0" && chmod 777 "/dev/${PREFIX,,}-psys0" ||
            echo "WARN: cannot set /dev/${PREFIX,,}-psys0 permissions" >&2
    fi
fi

# ---- direct MIPI cameras (non-GMSL) -----------------------------------------
setup_mipi_cameras
