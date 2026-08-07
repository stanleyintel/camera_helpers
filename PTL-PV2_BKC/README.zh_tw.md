# PTL-PV2 BKC 安裝指南

[English](./README.md)

## 目錄

- [1. 安裝 BKC Kernel](#1-安裝-bkc-kernel)
- [2. 設定 D3 ISX031 的 BIOS](#2-設定-d3-isx031-的-bios)
- [3. 安裝 PTL PV2 必要套件](#3-安裝-ptl-pv2-必要套件)
- [4. 安裝後驗證檢查](#4-安裝後驗證檢查)
- [5. 測試 D3 ISX031](#5-測試-d3-isx031)

## 1. 安裝 BKC Kernel

參考文件：**[RDC 858119 PTL GSG](https://edc.intel.com/content/www/us/en/secure/design/confidential/products-and-solutions/processors-and-chipsets/panther-lake-h/with-linux-os-get-started-guide-for-edge-platforms/)** 第 3 章。

1. 依照 3.1 節安裝 Ubuntu 24.04 LTS。
2. 從 **[RDC 860689](https://edc.intel.com/content/www/us/en/secure/design/confidential/products-and-solutions/processors-and-chipsets/panther-lake-h/with-linux-os-get-started-guide-for-edge-platforms/)** 下載並解壓縮 `installer.zip`（Ubuntu Kernel Overlay Auto Installer Script）。
3. 請先確認 Ubuntu Proxy 設定正確，否則後續步驟可能失敗。
4. 下載並儲存 [`ptl_pv2_installer.patch`](./ptl_pv2_installer.patch) 到與 `installer.sh` 相同的資料夾，然後在該資料夾執行：

   ```bash
   patch < ptl_pv2_installer.patch
   ```

   此 patch 可改善 apt 套件安裝流程、加入 kernel localversion 資訊，並為後續 DKMS build 預作準備。

5. 執行安裝指令（3.2.2 節）：

   ```bash
   sudo -E ./installer.sh UBUNTU_NOBLE PTL lts-v6.18.23-deb-overlay-260427T075939Z default
   ```

   請仔細檢查執行日誌。腳本會在完成後自動重新開機，並選擇：
   `Ubuntu, with Linux 6.18.23-nonrt-00`。

6. 重新開機後，確認 kernel 版本：

   ```bash
   uname -r
   ```

   預期輸出：

   ```text
   6.18.23-nonrt-000
   ```

7. 若要了解 `installer.sh` 會執行與安裝的完整內容，請參考 PTL GSG。

## 2. 設定 D3 ISX031 的 BIOS

請依照 **MIPI Camera Configuration for IPU75XA** 中的設定調整 BIOS：  
https://github.com/intel/Intel-MIPI-CSI-Camera-Reference-Driver/blob/release/26Q1.2/doc/isx031/userspace-gmsl.md#mipi-camera-configuration-for-ipu75xa

請將 **Custom HID** 設為 `INTC031M`。

在 Ubuntu dmesg 的預期輸出範例：

   ```text
   $ dmesg |grep ppr
   [    2.999079] IPU ACPI: SSDB: name INTC031M:00. link 0. lanes 4. pprval 2. pprunit 4. degree 180
   ```
## 3. 安裝 PTL PV2 必要套件

1. 從 **[RDC 860689](https://www.intel.com/content/www/us/en/secure/design/confidential/software-kits/kit-details.html?kitId=860689)** 下載並解壓縮 **`Panther Lake - H HDMI Capture Software Packages for PV2 Release`**。
2. 依照 4.2 節安裝 IPU 元件：

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

3. 下載並執行 [`7_do_post_install.sh`](./7_do_post_install.sh)。  
   此腳本會先加入非 root 使用者權限，再自動重新開機平台。

4. 下載並執行 [`8_do_post_build_v4l.sh`](./8_do_post_build_v4l.sh)。
   此腳本會檢查 v4l-utils 版本，若有需要會自動從原始碼重新 build 並安裝較新的版本。

## 4. 安裝後驗證檢查

執行完 [`8_do_post_build_v4l.sh`](./8_do_post_build_v4l.sh) 後，請執行 [`9_post_check.sh`](./9_post_check.sh) 進行安裝後驗證：

  ```bash
  $ ./9_post_check.sh
  ```


  ```text
  $ ./9_post_check.sh
  [PASS] Installed camera HAL exists: /usr/lib/libcamhal.so
  [PASS] Installed camera HAL plugin exists: /usr/lib/libcamhal/plugins/ipu75xa.so
  (skip)
  ```

## 5. 測試 D3 ISX031

1. DMA 模式：

   ```bash
   gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=dma_mode printfps=true ! 'video/x-raw(memory:DMABuf),drm-format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
   ```

2. mmap 模式：

   ```bash
   gst-launch-1.0 icamerasrc scene-mode=auto device-name=isx031-1 io-mode=mmap printfps=true ! 'video/x-raw,format=UYVY,width=1920,height=1536' ! fpsdisplaysink video-sink=glimagesink
   ```
