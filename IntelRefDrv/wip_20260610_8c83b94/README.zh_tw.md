# Intel MIPI CSI Camera Reference Driver DKMS 指南（commit `8c83b94`）

[English](./README.md)

## 目錄

- [總覽](#總覽)
- [開始之前](#開始之前)
- [本目錄中的檔案](#本目錄中的檔案)
- [安裝流程](#安裝流程)
- [重新開機後驗證](#重新開機後驗證)
- [相機測試指南](#相機測試指南)
- [疑難排解說明](#疑難排解說明)

## 總覽

此目錄提供的是 Intel 參考 DKMS driver 流程的輔助腳本，對應上游 `Intel-MIPI-CSI-Camera-Reference-Driver` repository 的 commit `8c83b94`。

此目錄中的流程**不會**安裝完整的 camera userspace stack。它涵蓋的內容如下：

1. 複製 reference driver repository。
2. 套用本地 patch `0002-media-ipu7-sync-acpi-csi2-config-abi.patch`。
3. 針對目前啟動中的 kernel 建置並安裝 `ipu-camera-sensor` DKMS 套件。
4. 在重新開機後執行驗證檢查。
5. 提供 D3 ISX031 的測試指令範例。

## 開始之前

本指南假設目標系統已經安裝好 **PTL PV2 BKC**。

PTL PV2 BKC 的安裝流程請參考 [`../../PTL-PV2_BKC`](../../PTL-PV2_BKC)。

## 本目錄中的檔案

| 檔案 | 用途 |
| --- | --- |
| `5_do_clone_dkms_driver.sh` | 複製 `Intel-MIPI-CSI-Camera-Reference-Driver`、切到 commit `8c83b94`、更新 submodule，並套用本地 patch。 |
| `6_do_build_dkms.sh` | 清除舊的 DKMS 狀態，然後為目前 kernel `add`、`build`、`install` `ipu-camera-sensor/0.1`。 |
| `8_post_check.sh` | 驗證 patch 狀態、DKMS 安裝狀態、`modinfo max96717`、firmware 字串、dmesg 版本資訊，以及必要套件來源。 |
| `0002-media-ipu7-sync-acpi-csi2-config-abi.patch` | 第 1 步會複製並套用到 cloned reference driver repository 的 patch。 |

## 安裝流程

1. 複製此 helper repository：

   ```bash
   git clone https://github.com/stanleyintel/camera_helpers.git
   ```

2. 進入此目錄：

   ```bash
   cd camera_helpers/IntelRefDrv/wip_20260610_8c83b94
   ```

3. 複製並套用 reference DKMS driver：

   ```bash
   ./5_do_clone_dkms_driver.sh
   ```

   此步驟實際上會做以下事情：

   1. 複製 `https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver.git`。
   2. 建立本地 branch `ref_main/8c83b94` 並切到 commit `8c83b94`。
   3. 更新 git submodule。
   4. 將 `0002-media-ipu7-sync-acpi-csi2-config-abi.patch` 複製到 cloned repository 中。
   5. 若 patch 尚未套用，則執行套用。

4. 建置並安裝 DKMS 套件：

   ```bash
   ./6_do_build_dkms.sh
   ```

   此腳本會先移除舊的 `ipu-camera-sensor/0.1` DKMS 狀態，再建置並安裝 DKMS 套件

5. 重新開機：

   ```bash
   sudo reboot
   ```

## 重新開機後驗證

重新開機後，請回到與安裝時**相同**的工作目錄，再執行 post check：

```bash
cd camera_helpers/IntelRefDrv/wip_20260610_8c83b94
./8_post_check.sh
```

`8_post_check.sh` 會驗證以下項目：

1. 本地 patch 是否仍已套用在 cloned reference driver tree 中。
2. `ipu-camera-sensor/0.1` 是否已安裝在 DKMS 中。
3. `modinfo -F filename max96717` 是否指向：

   ```text
   /lib/modules/$(uname -r)/updates/dkms/max96717.ko
   ```

4. `/usr/lib/firmware/intel/ipu/ipu7ptl_fw.bin` 是否包含預期的 firmware version 字串。
5. `dmesg` 是否包含預期的 IPU firmware 檔名與版本資訊。
6. `libva2`、`intel-media-va-driver-non-free` 與 `libigdgmm-dev` 是否已安裝且來源為 `download.01`。

請仔細查看結果：

- `[PASS]` 代表檢查結果符合預期。
- `[WARN]` 代表腳本發現非致命問題，但仍建議人工確認。
- `[FAIL]` 代表目前狀態不符合預期，且腳本會以非零狀態結束。

## 相機測試指南

當平台安裝完成且 post check 通過後，可使用以下指令測試 D3 ISX031 串流。

### 單顆相機 DMA 模式

```bash
gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
```

### 單顆相機 mmap 模式

```bash
gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=mmap printfps=true ! 'video/x-raw,format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
```

### 兩顆相機 DMA 模式

```bash
gst-launch-1.0 icamerasrc num-vc=2 scene-mode=auto device-name=isx031-1 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink sync=false \
               icamerasrc num-vc=2 scene-mode=auto device-name=isx031-2 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink sync=false
```

## 疑難排解說明

1. 若 `6_do_build_dkms.sh` 提示找不到 driver repository，代表你不在執行 `5_do_clone_dkms_driver.sh` 時使用的同一個工作目錄。
2. 若 `8_post_check.sh` 警告找不到 driver repo，請切回 `camera_helpers/IntelRefDrv/wip_20260610_8c83b94`，也就是第 3 步建立 `Intel-MIPI-CSI-Camera-Reference-Driver/` 的目錄後再執行。
3. 若 `modinfo -F filename max96717` 沒有指向 `/lib/modules/$(uname -r)/updates/dkms/max96717.ko`，代表目前執行中的 kernel 使用的不是預期的 DKMS 安裝模組。
