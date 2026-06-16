# PTL-PV2 26Q1.2 安裝指南

[English](./README.md)

## 目錄

- [1. 安裝 BKC Kernel](#1-安裝-bkc-kernel)
- [2. D3 ISX031 的 BIOS 設定](#2-d3-isx031-的-bios-設定)
- [3. 安裝 Intel-MIPI-CSI-Camera-Reference-Driver（release/26Q1.2）](#3-安裝-intel-mipi-csi-camera-reference-driverrelease26q12)
- [4. 使用 D3 ISX031 測試](#4-使用-d3-isx031-測試)

## 1. 安裝 BKC Kernel

參考文件：**RDC 858119 PTL GSG**，重點請看第 3 章。

1. 依照 3.1 節安裝 Ubuntu 24.04 LTS。
2. 下載並解壓縮 **RDC 860689** 的 `installer.zip`（Ubuntu Kernel Overlay Auto Installer Script）。
3. 請先確認 Ubuntu 代理設定正確，否則後續步驟可能失敗。
4. 修改 `installer.sh`：

   - 約第 174 行：

   ```diff
   - run "echo 'N' | apt upgrade -y"
   + run "echo 'N' | apt upgrade -y --allow-downgrades"
   ```

   - 約第 295 行（加入 localversion 資訊）：

   ```diff
   if [ "$variant" == "default" ]; then
   -    run "./build.sh -r no"
   +    run "./build.sh -r no -t nonrt-000"
   ```

5. 執行安裝指令（3.2.2 節）：

   ```bash
   sudo -E ./installer.sh UBUNTU_NOBLE PTL lts-v6.18.23-deb-overlay-260427T075939Z default
   ```

   請仔細檢查執行過程。腳本完成後會重新開機，並自動選擇：
   `Ubuntu, with Linux 6.18.23-nonrt-00`。

6. 重新開機後，確認 kernel 版本：

   ```bash
   uname -r
   ```

   預期輸出：

   ```text
   6.18.23-nonrt-000
   ```

7. 若要了解 `installer.zip` 實際執行與安裝內容，請參考 PTL GSG。

## 2. D3 ISX031 的 BIOS 設定

Configure BIOS with the settings shown in **MIPI Camera Configuration for IPU75XA**：  
https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver/blob/release/26Q1.2/doc/isx031/userspace-gmsl.md#mipi-camera-configuration-for-ipu75xa
The "Custom HID" is INTC031M.

## 3. 安裝 Intel-MIPI-CSI-Camera-Reference-Driver（release/26Q1.2）

1. 下載專案：

   ```bash
   git clone https://github.com/stanleyintel/camera_helpers
   cd camera_helpers/26Q1.2/ipu7
   ```

2. 依序執行 `1_do_clone_sources.sh` 到 `7_do_post_install.sh`。  
   `7_do_post_install.sh` 結束後會自動重新開機。
3. 腳本執行細節請參考：  
   https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver/tree/release/26Q1.2

## 4. 使用 D3 ISX031 測試

1. 執行 `8_do_bind_max9x_mono_isx031.sh` 以設定 links 與 routes。
2. 依你的環境執行後續驗證指令。
