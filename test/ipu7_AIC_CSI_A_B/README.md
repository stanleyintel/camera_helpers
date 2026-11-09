# IPU7 example: one MAX96724 on two CSI-2 ports (CSI_A + CSI_B)

This example shows how to connect one MAX96724 GMSL deserializer to two
IPU7 CSI-2 ports. Two GMSL links use CSI_A. The other two GMSL links use
CSI_B. You do not change the driver. You change only the ACPI SSDT overlay,
the media-ctl routing and the camera HAL JSON file.

## 1. Configuration

| GMSL link | Camera (HAL name) | DES0 output   | IPU port              | Capture node    |
|-----------|-------------------|---------------|-----------------------|-----------------|
| A (0)     | `acpi-1`          | PHY2 (pad 6)  | CSI2 0 (CSI_A, port 0)| ISYS Capture 0  |
| B (1)     | `acpi-2`          | PHY2 (pad 6)  | CSI2 0 (CSI_A, port 0)| ISYS Capture 1  |
| C (2)     | `acpi-3`          | PHY3 (pad 7)  | CSI2 1 (CSI_B, port 1)| ISYS Capture 10 |
| D (3)     | `acpi-4`          | PHY3 (pad 7)  | CSI2 1 (CSI_B, port 1)| ISYS Capture 11 |

- Platform: Intel PTL (IPU7.5).
- Cameras: ISX031 with MAX9295 or MAX96717 GMSL2 serializers.
- DES0: MAX96724 at I2C address 0x27 on I2C1.
- MIPI: C-PHY, 2 trios on each output.
- This example does not change DES1.

## 2. Folder contents

| File | Purpose |
|------|---------|
| `acpi/ipu7/max96724-servoss_d3_isx031.asl` | Board SSDT. DES0 has two outputs. |
| `acpi/ipu7/_des_common_max96724.asl` | DES template. It adds a second `CSI2Bus` when the board sets `DES_INTERNAL_PHY_2`. |
| `acpi/ipu7/_ipu_dual_csi_ab.asl` | IPU0 ports. Port 0 and port 1 have 2 data lanes each. |
| `acpi/ipu7/_des_ch_common_isx031.asl`, `_ser_common_max9295.asl`, `_cam_common_isx031.asl` | Unchanged channel, serializer and camera templates. |
| `script/acpi/mc-setup.sh` | media-ctl setup. It supports a DES with two outputs. |
| `config/acpi/ipu75xa/sensors/acpi.json` | Camera HAL JSON. `acpi-3` and `acpi-4` use CSI2 1. |
| `patch/0001-acpi-ipu7-route-one-MAX96724-to-CSI_A-and-CSI_B.patch` | All the changes above as one patch. Apply it with `git am` on commit `bc0fb0652fc0f32ed82be829729869a0c40523d2` of `https://github.com/Pirouf/Intel-mipi-gmsl-modules.git`. |

## 3. Changes from the standard configuration

- **DES template.** The DES `_CRS` has a second `CSI2Bus` resource. It
   connects DES PHY3 (local port 7) to IPU0 port 1. The board file enables it
   with these defines:

   ```
   #define DES_INTERNAL_PHY   6   // PHY2 -> CSI_A
   #define DES_TO_MIPI_PORT   0
   #define DES_INTERNAL_PHY_2 7   // PHY3 -> CSI_B
   #define DES_TO_MIPI_PORT_2 1
   ```

   The two outputs use the MAX96724 4x2 mode. `DES_LANES` must be 2.

## 4. Prerequisites

- Ubuntu with the IPU7 GMSL driver package, version `20260907-0eci6` or newer:

  ```
  sudo apt install intel-mipi-gmsl-dkms
  ```

- Camera HAL and GStreamer plugin for IPU7.5 (`libcamhal-ipu75xa`,
  `gstreamer1.0-icamera`).
- `iasl` 20250807 or newer, `cpio`, `media-ctl` (`v4l-utils`) and
  `i2ctransfer` (`i2c-tools`).

## 5. Procedure

Run all commands from this folder.

1. Update the package lists. Make sure that the package version is
   `20260907-0eci6` or newer:

   ```
   sudo apt update
   apt policy intel-mipi-gmsl-dkms
   ```

2. Download the driver package source to the folder `x`. This source
   contains `gen_ssdt.sh`. The `deb-src` entries must be enabled in your APT
   sources.

   ```
   mkdir x
   (cd x && apt source intel-mipi-gmsl-dkms)
   ```

3. Compile the ASL and make the SSDT image. `gen_ssdt.sh` writes `/boot/img_ssdt.img`.

   ```
   ./x/intel-mipi-gmsl-drivers-20260907/script/acpi/gen_ssdt.sh ./acpi/ipu7/max96724-servoss_d3_isx031.asl
   ```

   If `/boot/img_ssdt.img` does not exist, skip the backup command. If your
   package version is newer, change `20260907` in the path.

4. Make sure that `/etc/default/grub.d/ssdt.cfg` contains this line:

   ```
   GRUB_EARLY_INITRD_LINUX_CUSTOM="img_ssdt.img"
   ```

   Then update GRUB again to make sure that all settings are applied:

   ```
   sudo update-grub
   ```

5. Replace the packaged `mc-setup.sh`.

   ```
   sudo cp -p /usr/share/camera/acpi/mc-setup.sh /usr/share/camera/acpi/mc-setup.sh.bak
   sudo cp script/acpi/mc-setup.sh /usr/share/camera/acpi/mc-setup.sh
   ```

6. Install the camera HAL JSON file.

   ```
   sudo cp -p /etc/camera/ipu75xa/sensors/acpi.json /etc/camera/ipu75xa/sensors/acpi.json.bak
   sudo cp config/acpi/ipu75xa/sensors/acpi.json /etc/camera/ipu75xa/sensors/acpi.json
   ```

7. Reboot.

8. Make sure that the kernel binds DES0 to two IPU ports:

   ```
   sudo dmesg | grep "bind max96724"
   ```

   Example result:

   ```
   ... bind max96724 1-0027 nlanes is 2 port is 0
   ... bind max96724 1-0027 nlanes is 2 port is 1
   ... bind max96724 2-0027 nlanes is 2 port is 2
   ```

9. Set the media graph. The udev rule does this at boot. You can also do it
   manually. Do not do this step while a camera streams.

   ```
   sudo /usr/share/camera/acpi/mc-setup.sh
   ```

   The output must show:

   ```
   OUT0  DES pad 6 -> Intel IPU7 CSI2 0 (...), links: 0 1
   OUT1  DES pad 7 -> Intel IPU7 CSI2 1 (...), links: 2 3
   ```

10. Stream the four cameras:

   ```
   gst-launch-1.0 -e -v \
     icamerasrc num-vc=4 scene-mode=auto device-name=acpi-1 io-mode=dma_mode printfps=true \
       '!' 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' \
       '!' fpsdisplaysink video-sink=glimagesink sync=false \
     icamerasrc num-vc=4 scene-mode=auto device-name=acpi-2 io-mode=dma_mode printfps=true \
       '!' 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' \
       '!' fpsdisplaysink video-sink=glimagesink sync=false \
     icamerasrc num-vc=4 scene-mode=auto device-name=acpi-3 io-mode=dma_mode printfps=true \
       '!' 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' \
       '!' fpsdisplaysink video-sink=glimagesink sync=false \
     icamerasrc num-vc=4 scene-mode=auto device-name=acpi-4 io-mode=dma_mode printfps=true \
       '!' 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' \
       '!' fpsdisplaysink video-sink=glimagesink sync=false
   ```

## 6. Verification

Do these checks while the cameras stream.

1. DES0 routes. Links 0 and 1 must go to pad 6. Links 2 and 3 must go to
   pad 7.

   ```
   media-ctl -p | sed -n '/: max96724 1-0027 /,/pad0:/p' | grep -- '->'
   ```

   Expected result:

   ```
   0/0 -> 6/0 [ACTIVE]
   1/0 -> 6/1 [ACTIVE]
   2/0 -> 7/0 [ACTIVE]
   3/0 -> 7/1 [ACTIVE]
   ```

2. MAX96724 registers. DES0 is at address 0x27 on I2C bus 1. Read each
   register with `i2ctransfer` (high byte, then low byte):

   ```
   sudo i2ctransfer -f -y 1 w2@0x27 0x08 0xA2 r1
   sudo i2ctransfer -f -y 1 w2@0x27 0x09 0x2D r1
   sudo i2ctransfer -f -y 1 w2@0x27 0x09 0x6D r1
   sudo i2ctransfer -f -y 1 w2@0x27 0x09 0xAD r1
   sudo i2ctransfer -f -y 1 w2@0x27 0x09 0xED r1
   ```

   | Register | Expected | Meaning |
   |----------|----------|---------|
   | 0x8A2 | 0xc4 | PHY2 and PHY3 are on |
   | 0x92D | 0x2a | Pipe 0 to PHY2 (CSI_A) |
   | 0x96D | 0x2a | Pipe 1 to PHY2 (CSI_A) |
   | 0x9AD | 0x3f | Pipe 2 to PHY3 (CSI_B) |
   | 0x9ED | 0x3f | Pipe 3 to PHY3 (CSI_B) |

If all four links go to pad 6 (PHY2), the system uses an `mc-setup.sh` that
does not support two outputs. Do step 5 of the procedure again.

## 7. Tested environment

| Item | Version |
|------|---------|
| Platform | Intel PTL, IPU7.5 (PCI ID 8086:b05d) |
| Kernel | 7.0.0-42-generic |
| iasl | 20260408 |
| libcamhal-ipu75xa | 20260629-0eci3 |
| gstreamer1.0-icamera | 20260406-0eci1+tw1 |
