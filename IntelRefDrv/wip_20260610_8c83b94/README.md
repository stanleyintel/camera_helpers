# Intel MIPI CSI Camera Reference Driver DKMS Guide (commit `8c83b94`)

[繁體中文 (Traditional Chinese)](./README.zh_tw.md)

## Table of Contents

- [Overview](#overview)
- [Before You Start](#before-you-start)
- [Files in This Directory](#files-in-this-directory)
- [Installation Workflow](#installation-workflow)
- [Post-Reboot Validation](#post-reboot-validation)
- [Camera Test Guide](#camera-test-guide)
- [Troubleshooting Notes](#troubleshooting-notes)

## Overview

This directory contains the helper scripts for the Intel reference DKMS driver flow based on the upstream `Intel-MIPI-CSI-Camera-Reference-Driver` repository at commit `8c83b94`.

The flow in this directory does **not** install the full userspace camera stack. It covers:

1. Cloning the reference driver repository.
2. Applying the local patch `0002-media-ipu7-sync-acpi-csi2-config-abi.patch`.
3. Building and installing the `ipu-camera-sensor` DKMS package for the active kernel.
4. Running post-reboot validation checks.
5. Providing example test commands for D3 ISX031.

## Before You Start

This guide assumes **PTL PV2 BKC** is already installed on the target system.

For the PTL PV2 BKC installation flow, see [`../../PTL-PV2_BKC`](../../PTL-PV2_BKC).

## Files in This Directory

| File | Purpose |
| --- | --- |
| `5_do_clone_dkms_driver.sh` | Clones `Intel-MIPI-CSI-Camera-Reference-Driver`, checks out commit `8c83b94`, updates submodules, and applies the local patch. |
| `6_do_build_dkms.sh` | Removes old DKMS state, then adds, builds, and installs `ipu-camera-sensor/0.1` for the active kernel. |
| `8_post_check.sh` | Verifies patch state, DKMS install state, `modinfo max96717`, firmware strings, dmesg firmware version lines, and required package sources. |
| `0002-media-ipu7-sync-acpi-csi2-config-abi.patch` | Patch copied into the cloned reference driver repository and applied by step 1. |

## Installation Workflow

1. Clone this helper repository:

   ```bash
   git clone https://github.com/stanleyintel/camera_helpers.git
   ```

2. Enter this directory:

   ```bash
   cd camera_helpers/IntelRefDrv/wip_20260610_8c83b94
   ```

3. Clone and patch the reference DKMS driver:

   ```bash
   ./5_do_clone_dkms_driver.sh
   ```

   This step does the following:

   1. Clones `https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver.git`.
   2. Checks out local branch `ref_main/8c83b94` at commit `8c83b94`.
   3. Updates git submodules.
   4. Copies `0002-media-ipu7-sync-acpi-csi2-config-abi.patch` into the cloned repository.
   5. Applies the patch if it is not already applied.

4. Build and install the DKMS package:

   ```bash
   ./6_do_build_dkms.sh
   ```

   This script removes old `ipu-camera-sensor/0.1` DKMS state, then build and install the DKMS package.

5. Reboot the system:

   ```bash
   sudo reboot
   ```

## Post-Reboot Validation

After reboot, return to the **same** working directory used in the installation steps and run the post check:

```bash
cd camera_helpers/IntelRefDrv/wip_20260610_8c83b94
./8_post_check.sh
```

`8_post_check.sh` validates all of the following:

1. The local patch is still applied in the cloned reference driver tree.
2. `ipu-camera-sensor/0.1` is installed in DKMS.
3. `modinfo -F filename max96717` points to:

   ```text
   /lib/modules/$(uname -r)/updates/dkms/max96717.ko
   ```

4. `/usr/lib/firmware/intel/ipu/ipu7ptl_fw.bin` contains the expected firmware version strings.
5. `dmesg` contains the expected IPU firmware file and version lines.
6. `libva2`, `intel-media-va-driver-non-free`, and `libigdgmm-dev` are installed and come from `download.01`.

Review the result carefully:

- `[PASS]` means the check matched the expected state.
- `[WARN]` means the script found something non-fatal that still needs review.
- `[FAIL]` means the setup does not match the expected state and the script exits with a non-zero status.

## Camera Test Guide

After the platform is installed and the post check passes, use the following commands to test D3 ISX031 streaming.

### Single camera in DMA mode

```bash
gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
```

### Single camera in mmap mode

```bash
gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=mmap printfps=true ! 'video/x-raw,format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
```

### Two cameras in DMA mode

```bash
gst-launch-1.0 icamerasrc num-vc=2 scene-mode=auto device-name=isx031-1 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink sync=false \
               icamerasrc num-vc=2 scene-mode=auto device-name=isx031-2 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink sync=false
```

## Troubleshooting Notes

1. If `6_do_build_dkms.sh` reports that the driver repository is missing, you are not in the same working directory used for `5_do_clone_dkms_driver.sh`.
2. If `8_post_check.sh` warns that the driver repo is not found, rerun it from `camera_helpers/IntelRefDrv/wip_20260610_8c83b94`, where `Intel-MIPI-CSI-Camera-Reference-Driver/` was created by step 3.
3. If `modinfo -F filename max96717` does not point to `/lib/modules/$(uname -r)/updates/dkms/max96717.ko`, the expected DKMS-installed module is not the active one for the running kernel.
