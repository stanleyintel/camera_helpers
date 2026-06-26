# Intel MIPI CSI Camera Reference Driver DKMS Guide (commit `8c83b94`)

[繁體中文 (Traditional Chinese)](./README.zh_tw.md)

Use the same working directory for all steps below.

## Before You Start

This flow assumes **PTL PV2 BKC** is already installed.

If you still need that setup, see [`../../PTL-PV2_BKC`](../../PTL-PV2_BKC).

## Files in This Directory

| File | Purpose |
| --- | --- |
| `1_do_clone_acpica.sh` | Clone `https://github.com/acpica/acpica.git` and switch to local branch `20260408` at tag `20260408`. |
| `2_do_build_install_acpica.sh` | Check the current `iasl` version, or build and install ACPICA from the local `acpica/` tree when needed. |
| `5_do_clone_dkms_driver.sh` | Clone the Intel reference DKMS driver and apply the local patch. |
| `6_do_build_dkms.sh` | Build and install `ipu-camera-sensor/0.1` for the active kernel. |
| `8_post_check.sh` | Check `iasl`, patch state, DKMS state, firmware strings, dmesg, and required packages. |

## Step-by-Step Install

1. Clone this helper repository:

   ```bash
   git clone https://github.com/stanleyintel/camera_helpers.git
   ```

2. Enter this directory:

   ```bash
   cd camera_helpers/IntelRefDrv/wip_20260610_8c83b94
   ```

3. Clone ACPICA:

   ```bash
   ./1_do_clone_acpica.sh
   ```

4. Build and install ACPICA:

   ```bash
   ./2_do_build_install_acpica.sh
   ```

   If the installed `acpica-tools` package is too old, this script asks whether it should uninstall the package before continuing.

5. Clone and patch the DKMS driver:

   ```bash
   ./5_do_clone_dkms_driver.sh
   ```

6. Build and install the DKMS driver:

   ```bash
   ./6_do_build_dkms.sh
   ```

7. Reboot:

   ```bash
   sudo reboot
   ```

8. After reboot, return to the same directory and run the post check:

   ```bash
   cd camera_helpers/IntelRefDrv/wip_20260610_8c83b94
   ./8_post_check.sh
   ```

## Camera Test

After `8_post_check.sh` passes, use these commands to test D3 ISX031.

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

## Notes

1. Run `1_do_clone_acpica.sh`, `2_do_build_install_acpica.sh`, `5_do_clone_dkms_driver.sh`, `6_do_build_dkms.sh`, and `8_post_check.sh` from this same directory.
