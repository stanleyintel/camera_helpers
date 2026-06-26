# Intel MIPI CSI Camera Reference Driver DKMS 指南（commit `8c83b94`）

[English](./README.md)

以下步驟請都在同一個工作目錄中執行。

## 開始之前

此流程假設系統已先安裝好 **PTL PV2 BKC**。

如果還沒完成，請先參考 [`../../PTL-PV2_BKC`](../../PTL-PV2_BKC)。

## 本目錄中的檔案

| 檔案 | 用途 |
| --- | --- |
| `1_do_clone_acpica.sh` | 複製 `https://github.com/acpica/acpica.git`，並切到 tag `20260408` 的本地 branch `20260408`。 |
| `2_do_build_install_acpica.sh` | 檢查目前 `iasl` 版本，或在需要時從本地 `acpica/` 目錄建置並安裝 ACPICA。 |
| `5_do_clone_dkms_driver.sh` | 複製 Intel reference DKMS driver 並套用本地 patch。 |
| `6_do_build_dkms.sh` | 為目前使用中的 kernel 建置並安裝 `ipu-camera-sensor/0.1`。 |
| `8_post_check.sh` | 檢查 `iasl`、patch 狀態、DKMS 狀態、firmware 字串、dmesg 與必要套件。 |

## 安裝步驟

1. 複製此 helper repository：

   ```bash
   git clone https://github.com/stanleyintel/camera_helpers.git
   ```

2. 進入此目錄：

   ```bash
   cd camera_helpers/IntelRefDrv/wip_20260610_8c83b94
   ```

3. 複製 ACPICA：

   ```bash
   ./1_do_clone_acpica.sh
   ```

4. 建置並安裝 ACPICA：

   ```bash
   ./2_do_build_install_acpica.sh
   ```

   如果已安裝的 `acpica-tools` 套件版本太舊，這個腳本會先詢問是否要幫你移除，再繼續後面的流程。

5. 複製並套用 DKMS driver：

   ```bash
   ./5_do_clone_dkms_driver.sh
   ```

6. 建置並安裝 DKMS driver：

   ```bash
   ./6_do_build_dkms.sh
   ```

7. 重新開機：

   ```bash
   sudo reboot
   ```

8. 重新開機後，回到同一個目錄並執行 post check：

   ```bash
   cd camera_helpers/IntelRefDrv/wip_20260610_8c83b94
   ./8_post_check.sh
   ```

## 相機測試

當 `8_post_check.sh` 通過後，可用以下指令測試 D3 ISX031。

### 單顆相機 DMA 模式

```bash
gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
```

### 單顆相機 mmap 模式

```bash
gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=mmap printfps=true ! 'video/x-raw,format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
```

### 雙顆相機 DMA 模式

```bash
gst-launch-1.0 icamerasrc num-vc=2 scene-mode=auto device-name=isx031-1 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink sync=false \
               icamerasrc num-vc=2 scene-mode=auto device-name=isx031-2 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink sync=false
```

## 注意事項

1. `1_do_clone_acpica.sh`、`2_do_build_install_acpica.sh`、`5_do_clone_dkms_driver.sh`、`6_do_build_dkms.sh` 與 `8_post_check.sh` 都要在這個相同目錄中執行。
