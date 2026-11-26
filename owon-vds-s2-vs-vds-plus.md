# OWON VDS Series Architecture Comparison: Legacy (`VDS_S2`) vs. Newer (`VDS_Plus`)

This document summarizes the hardware, firmware, USB protocol, and PC software differences between OWON's legacy **VDS1000/2000/3000 (`VDS_S2`)** oscilloscopes (including Multicomp Pro `MP720016`–`MP720019`) and the newer **VDS6000 (`VDS_Plus`)** generation.

## 1. Hardware & Firmware Architecture

| Attribute | Legacy VDS (`VDS1022`, `VDS2062`, `VDS3102`) | Newer VDS (`VDS6022`, `VDS6102`, `VDS6202`) |
| :--- | :--- | :--- |
| **Multicomp Pro Models** | `MP720016` / `MP720017` (`VDS1022` / `VDS1022I`)<br>`MP720018` (`VDS2062`)<br>`MP720019` (`VDS3102` / `VDS3102L`) | Newer VDS6000-series rebadges |
| **Firmware Storage** | **Host-loaded (volatile):** Does not boot autonomously from internal flash. The PC host must upload the FPGA bitstream over USB every time the scope powers on. | **Onboard non-volatile flash:** Embedded MCU/SoC boots autonomously at power-on without host FPGA bitstream injection. |
| **FPGA Bitstream Location** | Bundled inside the PC software JAR (`com.owon.vds.smart_*.jar` or `fpga/*.bin`). | Stored on the oscilloscope's internal flash; not bundled in the PC application. |
| **Power & Ports** | USB 2.0 powered (`5V`, dual-headed Y-cable); `VDS3102L` adds RJ45 LAN, DC barrel jack, and USB isolation. | USB Type-C (`USB-PD`), RJ45 LAN, and optional Wi-Fi module. |

## 2. USB Enumeration & Communication Protocol

| Layer | Legacy VDS (`VDS_S2` / `MP720019`) | Newer VDS (`VDS_Plus` / `VDS6102AF`) |
| :--- | :--- | :--- |
| **USB VID:PID** | `5345:1234` (raw vendor-specific bulk USB) | USBTMC / VISA-compliant IDs or TCP/IP socket (`ScpiPort = 5188`) |
| **Transport Protocol** | Proprietary binary framing over raw USB bulk endpoints. | **SCPI** over USBTMC or TCP/IP sockets. |
| **Windows Driver** | `libusb0.sys` / `libusbK.sys` (`USBDRV`). | **NI-VISA** (`ni-visa_19.5` / `visa32.dll`). |
| **Linux Driver Behavior** | Userspace `libusb` (`ch.ntb.usb` / `libusbJava.so`).<br>*Kernel 6.14.5+ / 7.x caveat:* `usb_serial_simple` claims `5345:1234` automatically and must be unbound via `udev`. | Standard VISA (`libvisa.so` via JNA) or TCP sockets (`ScpiPort = 5188`). |

## 3. PC Software Architecture

| Attribute | `OWON_VDS_S2` (`2.0.17`, `2.0.18.2`, `2.1.19`) | `VDS_Plus` (`2.1.2_20250701`) |
| :--- | :--- | :--- |
| **Core JARs & Runtime** | Eclipse Equinox OSGi `3.8.1` + `com.owon.vds.foundation_1.0.0.jar` + `com.owon.vds.smart_2.0.18.2.jar`. | Eclipse Equinox OSGi `3.12.50` + unified `vds_plus_1.0.5/vds_plus.jar`. |
| **Java Requirement** | **Java 8** (uses `com.sun.java.swing.plaf.nimbus.NimbusLookAndFeel` and Equinox `3.8.1` profiles). | Modern Java Swing/AWT (`owon.vds.uibase.*`) without legacy `com.sun.*` Nimbus calls. |
| **Native I/O Bridge** | `ch.ntb.usb-0.5.9.jar` + `LibusbJava.dll` (`libusbJava.so` on Linux). | `JNA 5.2.0` (`libjnidispatch.so`) + `JVisa` (`visa32.dll` / `libvisa.so`). |
| **Interoperability** | Only works with legacy `5345:1234` FPGA scopes. | **Cannot initialize legacy `5345:1234` scopes** (lacks the FPGA bitstream loader). |

## 4. Linux Kernel 6.14.5+ / 7.x `udev` Rule (`/etc/udev/rules.d/99-owon-vds.rules`)

```udev
SUBSYSTEM=="usb", ATTR{idVendor}=="5345", ATTR{idProduct}=="1234", MODE="0666", GROUP="plugdev", RUN+="/bin/sh -c 'for dev in /sys/bus/usb/drivers/usb_serial_simple/*; do [ -e \"\$dev\" ] && echo -n \((basename \"\)dev\") > /sys/bus/usb/drivers/usb_serial_simple/unbind; done'"
```

