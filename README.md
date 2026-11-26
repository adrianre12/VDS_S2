# OWON VDS3102 / Multicomp Pro MP720019 Linux Port

A standalone Linux installer and native JNI USB bridge for the **OWON VDS3102** and **Multicomp Pro MP720019** PC USB oscilloscopes (USB ID `5345:1234`), porting the official Windows `OWON_VDS_S2` (`S2_2.1.19` / `2.0.18.2`) application to modern Linux distributions (tested on **Fedora 44 x86_64, Kernel 7.3.4**).

---

## Overview

OWON and Multicomp Pro (Farnell/element14) distribute the VDS3102 / MP720019 software exclusively as a Windows NSIS installer (`.exe`). Internally, the application is an **Eclipse RCP / Equinox Java** program that communicates with the oscilloscope over USB using `ch.ntb.usb` (`libusbJava`).

`install_owon_vds3102.sh` automates extracting the platform-independent Java/Eclipse bundles directly from the Windows `.exe` installer, pairing them with a standalone Java 8 runtime, compiling a 64-bit Linux `libusbJava.so` JNI wrapper from scratch, and configuring `udev` so the kernel does not hijack the scope as a serial tty device.

---

## Supported Hardware

This port works with the classic **OWON VDS_S2** hardware generation (manufactured ~2013–2023):
* **OWON:** VDS3102, VDS3102L, VDS2062, VDS2062L
* **Multicomp Pro (Farnell/element14):** MP720019, MP720018

[More Detals](owon-vds-s2-vs-vds-plus.md)

### How to Check if Your Oscilloscope is Compatible
Plug your oscilloscope into a USB port and run:
```bash
lsusb -d 5345:1234
```
* **If it prints `ID 5345:1234`:** Your unit uses the `VDS_S2` (`V6.x` firmware) bulk USB protocol and is compatible with this installer.
* **Not supported:** Newer **VDS 2000 Series** (`VDS2062A` / `VDS2102`) models, or the 25 MHz **VDS1022 / VDS1022I** (which uses the `VDS_C2` software branch).

---

## Obtaining the Windows `.exe` Installer

Because OWON and Multicomp Pro retain copyright over their compiled application binaries, the Windows installer is not hosted in this repository. You can download a compatible `.exe` installer from:

* **Multicomp Pro MP720019 (element14 Community Archive):** Download the software bundle from the [element14 MP720019 Software and USB Drivers](https://community.element14.com/products/manufacturers/multicomp-pro/m/files/151198) page, which contains `DS_Wave_VDS_S2_2.0.18.2_Setup.exe`.

The S2_2.1.19 does not currently appear to be available anywhere. I obtained copy when Owon hosted it, and it has been tested with this script.

---

## How the Windows `.exe` Port Works

The installation script performs five steps to turn the Windows installer into a native Linux desktop application:

### 1. Extracting Eclipse RCP Bundles from the Windows NSIS Installer
* Uses `7z` to unpack the Windows `.exe` NSIS archive directly into `~/.local/share/owon-vds3102/` without needing Wine.
* Extracts the `configuration/`, `plugins/`, and `docs/` directories.
* Strips Windows-specific native binaries (`*.dll` and `*.exe`) from `plugins/`.

### 2. Provisioning an Isolated Eclipse Temurin 8 JRE
* Downloads the official **Eclipse Temurin 8 JRE** (OpenJDK 8 Hotspot) matching the host CPU architecture (`x86_64`, `aarch64`, or `armv7l`) from the Adoptium API into `~/.local/share/owon-vds3102/jre`.
* Keeps the Java 8 runtime isolated to this application so system-wide modern JDKs (Java 17/21+) remain untouched.

### 3. Compiling a Native 64-Bit `libusbJava.so` JNI Library
The Windows release ships a 32/64-bit Windows `LibusbJava.dll` that bridges Java's `ch.ntb.usb.LibusbJava` class to `libusb-0.1`. To run natively on Linux, the script compiles a clean C JNI implementation (`libusbJava.so`) linked against `libusb-0.1` (`libusb-compat`) and places it in `plugins/ch.ntb.usb_*/`.

Key Linux/64-bit compatibility fixes built into `LibusbJava.c`:
* **64-bit JNI Field Signatures:** Maps `Usb_Bus.location` as a 64-bit Java `long` (`"J"`), `Usb_Device.devnum` and `num_children` as `byte` (`"B"`), and stores native `struct usb_device *` pointers in `Usb_Device.devStructAddr` (`"J"`).
* **Null-Handle Guards:** Validates `usb_dev_handle *` pointers across all JNI entry points (`usb_get_string_simple`, `usb_bulk_read`, `usb_bulk_write`, etc.). On Linux, scanning all USB busses encounters root hubs or devices without user write permissions where `usb_open()` returns `NULL`; returning early prevents `SIGSEGV` crashes in `libusb-0.1.so.4`.
* **Preventing Endpoint State Resets:** On Windows (`libusb-win32`), calling `usb_set_configuration(1)` and `usb_set_altinterface(0)` during `CDevice.open()` resets host-side data toggles cleanly. On Linux `libusb-0.1`, issuing redundant `SET_CONFIGURATION(1)` / `SET_INTERFACE(0)` control packets or `usb_clear_halt()` resets the VDS3102's USB endpoint state machine, causing subsequent `usb_bulk_read` calls on endpoint `0x81` (`:SDSLVER#` handshake) to time out. Skipping redundant configuration/altinterface control transfers matches the working USB sequence (`usb_open` -> `usb_claim_interface` -> `usb_bulk_write` -> `usb_bulk_read`).
* **Automatic Kernel Driver Detachment:** Calls `usb_detach_kernel_driver_np()` inside `usb_claim_interface()` as a fallback if a kernel driver is attached.
* **Minimum Transfer Timeout Floor:** Enforces a `>= 1000 ms` timeout on `usb_bulk_write` and `usb_bulk_read` so cold FPGA responses are not dropped.
* **Automatic JNI Header Fallback:** Uses system JDK `jni.h` / `jni_md.h` headers if present, or automatically fetches them from `openjdk/jdk8u` when building against a JRE-only bundle.

### 4. Configuring `udev` Rules for Kernel 6.14+ / 7.x
Modern Linux kernels include the `usb_serial_simple` driver (`owon` subdriver), which automatically claims USB ID `5345:1234` and binds it to `/dev/ttyUSB0`. While `/dev/ttyUSB0` is bound, `libusb` cannot claim interface `0`.

The installer writes `/etc/udev/rules.d/99-owon-vds.rules` with three rules:
1. **User-space USB permissions:** Sets `MODE="0666"` and `TAG+="uaccess"` on `5345:1234` so non-root desktop users can open the oscilloscope.
2. **Disable USB autosuspend:** Sets `ATTR{power/control}="on"` so the kernel does not suspend the oscilloscope mid-capture.
3. **Post-bind driver unbind:** Uses `ACTION=="bind", SUBSYSTEM=="usb", DRIVER=="usb_serial_simple", ATTRS{idVendor}=="5345", ATTRS{idProduct}=="1234"` to unbind `usb_serial_simple` immediately after the kernel attaches it, avoiding race conditions during enumeration.

### 5. Desktop & CLI Integration
* Generates an executable wrapper at `~/.local/bin/owon-vds` with `LD_LIBRARY_PATH` and `-Djava.library.path` pointing to `ch.ntb.usb_*`.
* Extracts the application icon from `com.owon.vds.foundation_1.0.0.jar` and installs a freedesktop `.desktop` entry at `~/.local/share/applications/owon-vds3102.desktop`.

---

## Requirements

* **Linux** (`x86_64`, `aarch64`, or `armv7l`)
* **Build & extraction tools:** `gcc`, `make`, `curl`, `7z` (`p7zip`), and `libusb-0.1` compatibility headers (`usb.h`)
  * **Fedora / RHEL:** `sudo dnf install gcc make curl p7zip p7zip-plugins libusb-compat-0.1-devel`
  * **Debian / Ubuntu:** `sudo apt-get install build-essential curl p7zip-full libusb-dev`
  * **Arch Linux:** `sudo pacman -S base-devel curl p7zip libusb-compat`
  *(The installer script checks for these automatically and offers to install them.)*
* **Official Windows Installer (`.exe`):** `OWON_VDS_S2_2.1.19_Setup.exe` or `DS_Wave_VDS_S2_2.0.18.2_Setup.exe` (see [Obtaining the Windows `.exe` Installer](#obtaining-the-windows-exe-installer)).

---

## Installation

1. Place `install_owon_vds3102.sh` and your Windows `.exe` installer (e.g., `DS_Wave_VDS_S2_2.0.18.2_Setup.exe` or `OWON_VDS_S2_2.1.19_Setup.exe`) in the same directory.
2. Make the installer executable and run it:
   ```bash
   chmod +x install_owon_vds3102.sh
   ./install_owon_vds3102.sh "DS_Wave_VDS_S2_2.0.18.2_Setup.exe"
   ```
3. Approve the `sudo` prompt when asked to install `/etc/udev/rules.d/99-owon-vds.rules`.
4. Unplug and replug your oscilloscope once so the new `udev` rule takes effect.

---

## Usage

Launch from your desktop application menu (**OWON VDS3102 Oscilloscope**) or run from a terminal:

```bash
owon-vds
```

*(Ensure `~/.local/bin` is in your `PATH`.)*

---

## Troubleshooting

* **Scope stays offline / `ttyUSB0` appears in `dmesg`:**
  Verify that `/etc/udev/rules.d/99-owon-vds.rules` is installed and reload `udev`:
  ```bash
  sudo udevadm control --reload-rules
  sudo udevadm trigger --attr-match=idVendor=5345 --attr-match=idProduct=1234
  ```
  Then unplug and replug the USB cable.
* **Verify USB communication manually:**
  You can confirm the hardware responds to the `:SDSLVER#` handshake using `lsusb -d 5345:1234`. The scope uses bulk endpoint `0x03` (OUT) and `0x81` (IN) on Interface `0`.

---

## Disclaimer

This repository contains only the Linux installation and JNI bridge script. It does not redistribute OWON or Multicomp Pro proprietary software or firmware; you must obtain the Windows `.exe` installer directly from the [element14 MP720019 Software Archive](https://community.element14.com/products/manufacturers/multicomp-pro/m/files/151198) or the [OWON Official Download Center](https://www.owon.com.hk/download/index.asp?S=75).
