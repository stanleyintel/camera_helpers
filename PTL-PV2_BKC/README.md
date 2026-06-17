# PTL-PV2 BKC Setup Guide

[繁體中文 (Traditional Chinese)](./README.zh_tw.md)

## Table of Contents

- [1. Install the BKC Kernel](#1-install-the-bkc-kernel)
- [2. Configure BIOS for D3 ISX031](#2-configure-bios-for-d3-isx031)
- [3. Install PTL PV2 Required Packages](#3-install-ptl-pv2-required-packages)
- [4. Post Validation Check](#4-post-validation-check)
- [5. Test D3 ISX031](#5-test-d3-isx031)

## 1. Install the BKC Kernel

Reference: **[RDC 858119 PTL GSG](https://edc.intel.com/content/www/us/en/secure/design/confidential/products-and-solutions/processors-and-chipsets/panther-lake-h/with-linux-os-get-started-guide-for-edge-platforms/)**, Chapter 3.

1. Install Ubuntu 24.04 LTS (section 3.1).
2. Download and extract `installer.zip` (Ubuntu Kernel Overlay Auto Installer Script) from **[RDC 860689](https://edc.intel.com/content/www/us/en/secure/design/confidential/products-and-solutions/processors-and-chipsets/panther-lake-h/with-linux-os-get-started-guide-for-edge-platforms/)**.
3. Confirm Ubuntu proxy settings are correct. Otherwise, later steps may fail.
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

   - Around line 336 (optional but recommended: add config for future dkms build):

   ```diff
   echo "$kernel_entry"
   +  run "install -D -m 644 ${current_workspace}/linux-kernel-overlay/kernel.config /lib/modules/${kernel_entry}/build/.config"
   ```

5. Run the installer command (section 3.2.2):

   ```bash
   sudo -E ./installer.sh UBUNTU_NOBLE PTL lts-v6.18.23-deb-overlay-260427T075939Z default
   ```

   Review the logs carefully. The script reboots the board and automatically selects:
   `Ubuntu, with Linux 6.18.23-nonrt-00`.

6. After reboot, confirm the kernel version:

   ```bash
   uname -r
   ```

   Expected output:

   ```text
   6.18.23-nonrt-000
   ```

7. For full details of what `installer.zip` installs and executes, refer to PTL GSG.

## 2. Configure BIOS for D3 ISX031

Configure BIOS according to **MIPI Camera Configuration for IPU75XA**:  
https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver/blob/release/26Q1.2/doc/isx031/userspace-gmsl.md#mipi-camera-configuration-for-ipu75xa

Set **Custom HID** to `INTC031M`.

Example of expected output in Ubuntu dmesg:

   ```text
   $ dmesg |grep ppr
   [    2.999079] IPU ACPI: SSDB: name INTC031M:00. link 0. lanes 4. pprval 2. pprunit 4. degree 1806.18.23-nonrt-000
   ```

## 3. Install PTL PV2 Required Packages

1. Download and extract `Panther Lake - H HDMI Capture Software Packages for PV2 Release` from **[RDC 860689](https://www.intel.com/content/www/us/en/secure/design/confidential/software-kits/kit-details.html?kitId=860689)**.
2. Follow section 4.2 to install IPU components:

   ```bash
   sudo apt install -y alien
   sudo alien ./*.rpm
   sudo dpkg -i --force-overwrite icamerasrc_*.deb
   sudo dpkg -i --force-overwrite ipu7xfw_*.deb
   sudo dpkg -i --force-overwrite libiaaiq-ipu75xa_*.deb
   sudo dpkg -i --force-overwrite libiaaiq-ipu7x_*.deb
   sudo dpkg -i --force-overwrite ipu75xafw_*.deb
   sudo dpkg -i --force-overwrite libcamhal_*.deb
   ```

3. Download and run [`7_do_post_install.sh`](./7_do_post_install.sh).  
   The script adds permissions for non-root users and then reboots the platform automatically.

## 4. Post Validation Check

Run [`8_post_check.sh`](./8_post_check.sh) after reboot to perform post-install validation:

```bash
./8_post_check.sh
```

## 5. Test D3 ISX031

1. DMA mode:

   ```bash
   gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
   ```

2. mmap mode:

   ```bash
   gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=mmap printfps=true ! 'video/x-raw,format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
   ```
