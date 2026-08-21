# Intel MIPI CSI Camera Reference Driver 26Q1.2 DKMS Guide for ARL/IPU6

Use the same working directory for all steps below.

## Before You Start

This flow targets **ARL + IPU6** with the 26Q1.2 userspace and DKMS driver stack. It assumes:

1. Ubuntu is already installed.
2. An **ARL BKC kernel** is already installed and booted.
3. BIOS is configured for **ISX031 over MAX9295/MAX9296**.

Reference BIOS settings:  
https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver/blob/release/26Q1.2/doc/isx031/userspace-gmsl.md#mipi-camera-configuration-for-ipu6epmtl

For D3 Embedded ISX031, set **Custom HID** to `INTC031M`.

## Files in This Directory

| File | Purpose |
| --- | --- |
| `1_do_clone_sources.sh` | Clone the 26Q1.2 source trees for `ipu6-camera-bins`, `ipu6-camera-hal`, and `icamerasrc`. |
| `2_do_install_camera_bins.sh` | Install IPU6 firmware, runtime libraries, headers, and pkg-config files from `ipu6-camera-bins`. |
| `3_do_build_camera_hal.sh` | Build and install the camera HAL. `ipu_arl` is the default target and maps to the `ipu_mtl` build used by ARL/IPU6EPMTL. |
| `4_do_build_icamerasrc.sh` | Build and install `icamerasrc`. |
| `5_do_clone_dkms_driver.sh` | Clone the Intel reference DKMS driver and apply the local patches. |
| `6_do_build_dkms.sh` | Install `dkms`, then build and install `ipu-camera-sensor/0.1` for the active kernel. |
| `7_do_post_install.sh` | Install `yavta`, `meson`, `ninja-build`, and `graphviz`, fix permissions, add the IPU6 PSYS udev rule, and set the IPU6 `isys_freq_override`. |
| `8_do_post_build_v4l.sh` | Build a new enough `v4l-utils` when the system copy of `media-ctl` is too old. |
| `9_post_check.sh` | Validate the installed userspace, DKMS state, post-install configuration, dmesg firmware version, required packages, and `media-ctl` version. |

All scripts support `--dry` to print commands without executing them.

## Step-by-Step Install

1. Clone this helper repository:

   ```bash
   git clone https://github.com/stanleyintel/camera_helpers.git
   ```

2. Enter this directory:

   ```bash
   cd camera_helpers/IntelRefDrv/26Q1.2/ipu6
   ```

3. Clone the required sources:

   ```bash
   ./1_do_clone_sources.sh
   ```

4. Install camera bins:

   ```bash
   ./2_do_install_camera_bins.sh
   ```

5. Build and install the camera HAL for ARL:

   ```bash
   ./3_do_build_camera_hal.sh
   ```

   `ipu_arl` is the default. If you need another supported board mapping, run:

   ```bash
   ./3_do_build_camera_hal.sh ipu_tgl
   ./3_do_build_camera_hal.sh ipu_adl
   ./3_do_build_camera_hal.sh ipu_mtl
   ```

6. Build and install `icamerasrc`:

   ```bash
   ./4_do_build_icamerasrc.sh
   ```

7. Clone and patch the DKMS driver:

   ```bash
   ./5_do_clone_dkms_driver.sh
   ```

8. Build and install the DKMS driver:

   ```bash
   ./6_do_build_dkms.sh
   ```

9. Run post-install setup:

   ```bash
   ./7_do_post_install.sh
   ```

10. Build `v4l-utils` if needed:

   ```bash
   ./8_do_post_build_v4l.sh
   ```

11. Reboot manually:

   ```bash
   sudo reboot
   ```

12. After reboot, return to the same directory and run the validation script:

   ```bash
   cd camera_helpers/IntelRefDrv/26Q1.2/ipu6
   ./9_post_check.sh
   ```

## ARL/IPU6 Notes

1. If `/etc/camera/ipu6epmtl/libcamhal_profile.xml` already exists, `3_do_build_camera_hal.sh` warns before overwriting it. If you agree, the script backs it up to `/etc/camera/ipu6epmtl/libcamhal_profile.xml.org` and tells you that backup path.
2. Run `media-ctl -p` after reboot to confirm the media graph is enumerated.

## Camera Test

After `./9_post_check.sh` passes, test a single D3 AR0234 camera in DMA mode:

```bash

gst-launch-1.0 icamerasrc num-buffers=-1 scene-mode=normal device-name=ar0234-1 printfps=true io-mode=dma_mode ! 'video/x-raw(memory:DMABuf),drm-format=NV12,width=1280,height=960' ! glimagesink sync=false

```
