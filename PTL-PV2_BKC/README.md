# PTL-PV2 26Q1.2 Setup Guide

[繁體中文 (Traditional Chinese)](./README.zh_tw.md)

## Table of Contents

- [1. Install BKC Kernel](#1-install-bkc-kernel)
- [2. BIOS Configuration for D3 ISX031](#2-bios-configuration-for-d3-isx031)
- [3. Install Intel-MIPI-CSI-Camera-Reference-Driver (release/26Q1.2)](#3-install-intel-mipi-csi-camera-reference-driver-release26q12)
- [4. Test with D3 ISX031](#4-test-with-d3-isx031)

## 1. Install BKC Kernel

Reference: **RDC 858119 PTL GSG**, focus on Chapter 3.

1. Install Ubuntu 24.04 LTS as described in section 3.1.
2. Download and decompress `installer.zip` (Ubuntu Kernel Overlay Auto Installer Script) from **RDC 860689** .
3. Ensure proxy is properly configured in Ubuntu; otherwise, later steps may fail.
4. Modify `installer.sh`:

   - Around line 174:

   ```diff
   - run "echo 'N' | apt upgrade -y"
   + run "echo 'N' | apt upgrade -y --allow-downgrades"
   ```

   - Around line 295 (optional but recommended: add localversion info):

   ```diff
   if [ "$variant" == "default" ]; then
   -    run "./build.sh -r no"
   +    run "./build.sh -r no -t nonrt-000"
   ```

5. Run the installer command (section 3.2.2):

   ```bash
   sudo -E ./installer.sh UBUNTU_NOBLE PTL lts-v6.18.23-deb-overlay-260427T075939Z default
   ```

   Check execution logs carefully. The script reboots the board and auto-selects:
   `Ubuntu, with Linux 6.18.23-nonrt-00`.

6. After reboot, confirm kernel version:

   ```bash
   uname -r
   ```

   Expected output:

   ```text
   6.18.23-nonrt-000
   ```

7. For details about what `installer.zip` executes and installs, refer to PTL GSG.

## 2. BIOS Configuration for D3 ISX031

Configure BIOS with the settings shown in **MIPI Camera Configuration for IPU75XA**:  
https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver/blob/release/26Q1.2/doc/isx031/userspace-gmsl.md#mipi-camera-configuration-for-ipu75xa
The "Custom HID" is INTC031M.

## 3. Install Intel-MIPI-CSI-Camera-Reference-Driver (release/26Q1.2)

1. Clone:

   ```bash
   git clone https://github.com/stanleyintel/camera_helpers
   cd camera_helpers/26Q1.2/ipu7
   ```

2. Run scripts `1_do_clone_sources.sh` through `7_do_post_install.sh` one by one under current directory. 
   The board reboots automatically at the end of `7_do_post_install.sh`.
3. For script execution details, see:  
   https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver/tree/release/26Q1.2

## 4. Test with D3 ISX031

1. Run `8_do_bind_max9x_mono_isx031.sh` to configure links and routes.
2. Run the remaining validation command(s) as needed for your environment.
