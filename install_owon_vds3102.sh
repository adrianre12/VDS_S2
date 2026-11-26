#!/usr/bin/env bash
set -euo pipefail

EXE_INPUT="${1:-OWON_VDS_S2_2.1.19_Setup.exe}"
INSTALL_DIR="${HOME}/.local/share/owon-vds3102"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.local/share/applications"
WORK_DIR="$(mktemp -d /tmp/owon_build.XXXXXX)"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "=== OWON VDS3102 / Multicomp Pro MP720019 Linux Port Installer (v20) ==="

if [[ ! -f "${EXE_INPUT}" ]]; then
    echo "Error: Installer executable not found: '${EXE_INPUT}'"
    echo "Usage: $0 \"/path/to/Setup.exe\""
    exit 1
fi

if [[ "${EXE_INPUT,,}" != *.exe ]]; then
    echo "Error: Expected a Windows .exe installer, got: '${EXE_INPUT}'"
    echo "Please extract any .zip archive first and pass the .exe file directly."
    exit 1
fi

# 1. Check build & extraction dependencies
MISSING_TOOLS=()
command -v gcc >/dev/null 2>&1 || MISSING_TOOLS+=("gcc")
command -v make >/dev/null 2>&1 || MISSING_TOOLS+=("make")
command -v curl >/dev/null 2>&1 || MISSING_TOOLS+=("curl")
command -v 7z >/dev/null 2>&1 || MISSING_TOOLS+=("7z")

HAS_USB_H=0
for inc in /usr/include/usb.h /usr/local/include/usb.h; do
    [[ -f "$inc" ]] && HAS_USB_H=1
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 || ${HAS_USB_H} -eq 0 ]]; then
    echo ""
    echo "Missing build dependencies detected:"
    [[ ${#MISSING_TOOLS[@]} -gt 0 ]] && echo "  - Tools: ${MISSING_TOOLS[*]}"
    [[ ${HAS_USB_H} -eq 0 ]] && echo "  - Header: usb.h (libusb-0.1 compatibility headers)"
    echo ""

    if command -v dnf >/dev/null 2>&1; then
        INSTALL_CMD="sudo dnf install -y gcc make curl p7zip p7zip-plugins libusb-compat-0.1-devel"
    elif command -v apt-get >/dev/null 2>&1; then
        INSTALL_CMD="sudo apt-get update && sudo apt-get install -y build-essential curl p7zip-full libusb-dev"
    elif command -v pacman >/dev/null 2>&1; then
        INSTALL_CMD="sudo pacman -S --needed base-devel curl p7zip libusb-compat"
    else
        echo "Please install gcc, make, curl, 7z, and libusb-0.1 development headers manually, then re-run."
        exit 1
    fi

    echo "Suggested command:"
    echo "  ${INSTALL_CMD}"
    read -r -p "Run this command now? [Y/n] " REPLY
    if [[ "${REPLY:-Y}" =~ ^[Yy]$ ]]; then
        eval "${INSTALL_CMD}"
    else
        echo "Cannot compile libusbJava.so without build tools. Exiting."
        exit 1
    fi
fi

# 2. Unpack NSIS .exe installer
echo "[1/5] Extracting ${EXE_INPUT}..."
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}" "${BIN_DIR}" "${APP_DIR}"
7z x -y "${EXE_INPUT}" -o"${INSTALL_DIR}" configuration plugins docs >/dev/null

# Remove Windows-only binaries inside plugins
find "${INSTALL_DIR}/plugins" -type f \( -iname "*.dll" -o -iname "*.exe" \) -delete

# 3. Download standalone Eclipse Temurin 8 JRE for current architecture
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  ADOPTIUM_ARCH="x64" ;;
    aarch64) ADOPTIUM_ARCH="aarch64" ;;
    armv7l)  ADOPTIUM_ARCH="arm" ;;
    *)
        echo "Unsupported CPU architecture for Temurin 8 JRE: ${ARCH}"
        exit 1
        ;;
esac

echo "[2/5] Downloading Eclipse Temurin 8 JRE (${ADOPTIUM_ARCH})..."
JRE_URL="https://api.adoptium.net/v3/binary/latest/8/ga/linux/${ADOPTIUM_ARCH}/jre/hotspot/normal/eclipse?project=jdk"
curl -fsSL "${JRE_URL}" -o "${WORK_DIR}/temurin8-jre.tar.gz"
mkdir -p "${INSTALL_DIR}/jre"
tar -xzf "${WORK_DIR}/temurin8-jre.tar.gz" -C "${INSTALL_DIR}/jre" --strip-components=1

# 4. Compile libusbJava.so from embedded C source
echo "[3/5] Compiling libusbJava.so from source..."
mkdir -p "${WORK_DIR}/libusbjava_src"

JNI_INC=""
JNI_LINUX_INC=""
for candidate in "${INSTALL_DIR}/jre/include" /usr/lib/jvm/*/include; do
    if [[ -f "${candidate}/jni.h" && -f "${candidate}/linux/jni_md.h" ]]; then
        JNI_INC="${candidate}"
        JNI_LINUX_INC="${candidate}/linux"
        break
    fi
done

if [[ -z "${JNI_INC}" ]]; then
    mkdir -p "${WORK_DIR}/jni_inc/linux"
    curl -fsSL "https://raw.githubusercontent.com/openjdk/jdk8u/master/jdk/src/share/javavm/export/jni.h" -o "${WORK_DIR}/jni_inc/jni.h"
    curl -fsSL "https://raw.githubusercontent.com/openjdk/jdk8u/master/jdk/src/solaris/javavm/export/jni_md.h" -o "${WORK_DIR}/jni_inc/linux/jni_md.h"
    JNI_INC="${WORK_DIR}/jni_inc"
    JNI_LINUX_INC="${WORK_DIR}/jni_inc/linux"
fi

cat > "${WORK_DIR}/libusbjava_src/LibusbJava.c" <<'CSRC'
#include <jni.h>
#include <usb.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <errno.h>

static jclass cls_bus = NULL, cls_dev = NULL, cls_dev_desc = NULL, cls_cfg_desc = NULL;
static jclass cls_iface = NULL, cls_iface_desc = NULL, cls_ep_desc = NULL;

static void init_classes(JNIEnv *env) {
    if (cls_bus != NULL) return;
    cls_bus        = (*env)->NewGlobalRef(env, (*env)->FindClass(env, "ch/ntb/usb/Usb_Bus"));
    cls_dev        = (*env)->NewGlobalRef(env, (*env)->FindClass(env, "ch/ntb/usb/Usb_Device"));
    cls_dev_desc   = (*env)->NewGlobalRef(env, (*env)->FindClass(env, "ch/ntb/usb/Usb_Device_Descriptor"));
    cls_cfg_desc   = (*env)->NewGlobalRef(env, (*env)->FindClass(env, "ch/ntb/usb/Usb_Config_Descriptor"));
    cls_iface      = (*env)->NewGlobalRef(env, (*env)->FindClass(env, "ch/ntb/usb/Usb_Interface"));
    cls_iface_desc = (*env)->NewGlobalRef(env, (*env)->FindClass(env, "ch/ntb/usb/Usb_Interface_Descriptor"));
    cls_ep_desc    = (*env)->NewGlobalRef(env, (*env)->FindClass(env, "ch/ntb/usb/Usb_Endpoint_Descriptor"));
}

static jobject create_ep_desc(JNIEnv *env, struct usb_endpoint_descriptor *ep) {
    jmethodID cid = (*env)->GetMethodID(env, cls_ep_desc, "<init>", "()V");
    jobject obj = (*env)->NewObject(env, cls_ep_desc, cid);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "bLength", "B"), (jbyte)ep->bLength);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "bDescriptorType", "B"), (jbyte)ep->bDescriptorType);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "bEndpointAddress", "B"), (jbyte)ep->bEndpointAddress);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "bmAttributes", "B"), (jbyte)ep->bmAttributes);
    (*env)->SetShortField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "wMaxPacketSize", "S"), (jshort)ep->wMaxPacketSize);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "bInterval", "B"), (jbyte)ep->bInterval);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "bRefresh", "B"), (jbyte)ep->bRefresh);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "bSynchAddress", "B"), (jbyte)ep->bSynchAddress);
    if (ep->extra && ep->extralen > 0) {
        jbyteArray arr = (*env)->NewByteArray(env, ep->extralen);
        (*env)->SetByteArrayRegion(env, arr, 0, ep->extralen, (jbyte *)ep->extra);
        (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "extra", "[B"), arr);
    }
    (*env)->SetIntField(env, obj, (*env)->GetFieldID(env, cls_ep_desc, "extralen", "I"), (jint)ep->extralen);
    return obj;
}

static jobject create_iface_desc(JNIEnv *env, struct usb_interface_descriptor *id) {
    jmethodID cid = (*env)->GetMethodID(env, cls_iface_desc, "<init>", "()V");
    jobject obj = (*env)->NewObject(env, cls_iface_desc, cid);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "bLength", "B"), (jbyte)id->bLength);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "bDescriptorType", "B"), (jbyte)id->bDescriptorType);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "bInterfaceNumber", "B"), (jbyte)id->bInterfaceNumber);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "bAlternateSetting", "B"), (jbyte)id->bAlternateSetting);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "bNumEndpoints", "B"), (jbyte)id->bNumEndpoints);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "bInterfaceClass", "B"), (jbyte)id->bInterfaceClass);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "bInterfaceSubClass", "B"), (jbyte)id->bInterfaceSubClass);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "bInterfaceProtocol", "B"), (jbyte)id->bInterfaceProtocol);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "iInterface", "B"), (jbyte)id->iInterface);
    if (id->endpoint && id->bNumEndpoints > 0) {
        jobjectArray eps = (*env)->NewObjectArray(env, id->bNumEndpoints, cls_ep_desc, NULL);
        for (int i = 0; i < id->bNumEndpoints; i++) {
            (*env)->SetObjectArrayElement(env, eps, i, create_ep_desc(env, &id->endpoint[i]));
        }
        (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "endpoint", "[Lch/ntb/usb/Usb_Endpoint_Descriptor;"), eps);
    }
    if (id->extra && id->extralen > 0) {
        jbyteArray arr = (*env)->NewByteArray(env, id->extralen);
        (*env)->SetByteArrayRegion(env, arr, 0, id->extralen, (jbyte *)id->extra);
        (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "extra", "[B"), arr);
    }
    (*env)->SetIntField(env, obj, (*env)->GetFieldID(env, cls_iface_desc, "extralen", "I"), (jint)id->extralen);
    return obj;
}

static jobject create_iface(JNIEnv *env, struct usb_interface *iface) {
    jmethodID cid = (*env)->GetMethodID(env, cls_iface, "<init>", "()V");
    jobject obj = (*env)->NewObject(env, cls_iface, cid);
    if (iface->altsetting && iface->num_altsetting > 0) {
        jobjectArray alts = (*env)->NewObjectArray(env, iface->num_altsetting, cls_iface_desc, NULL);
        for (int i = 0; i < iface->num_altsetting; i++) {
            (*env)->SetObjectArrayElement(env, alts, i, create_iface_desc(env, &iface->altsetting[i]));
        }
        (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_iface, "altsetting", "[Lch/ntb/usb/Usb_Interface_Descriptor;"), alts);
    }
    (*env)->SetIntField(env, obj, (*env)->GetFieldID(env, cls_iface, "num_altsetting", "I"), (jint)iface->num_altsetting);
    return obj;
}

static jobject create_cfg_desc(JNIEnv *env, struct usb_config_descriptor *cfg) {
    jmethodID cid = (*env)->GetMethodID(env, cls_cfg_desc, "<init>", "()V");
    jobject obj = (*env)->NewObject(env, cls_cfg_desc, cid);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "bLength", "B"), (jbyte)cfg->bLength);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "bDescriptorType", "B"), (jbyte)cfg->bDescriptorType);
    (*env)->SetShortField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "wTotalLength", "S"), (jshort)cfg->wTotalLength);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "bNumInterfaces", "B"), (jbyte)cfg->bNumInterfaces);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "bConfigurationValue", "B"), (jbyte)cfg->bConfigurationValue);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "iConfiguration", "B"), (jbyte)cfg->iConfiguration);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "bmAttributes", "B"), (jbyte)cfg->bmAttributes);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "MaxPower", "B"), (jbyte)cfg->MaxPower);
    if (cfg->interface && cfg->bNumInterfaces > 0) {
        jobjectArray ifaces = (*env)->NewObjectArray(env, cfg->bNumInterfaces, cls_iface, NULL);
        for (int i = 0; i < cfg->bNumInterfaces; i++) {
            (*env)->SetObjectArrayElement(env, ifaces, i, create_iface(env, &cfg->interface[i]));
        }
        (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "interface_", "[Lch/ntb/usb/Usb_Interface;"), ifaces);
    }
    if (cfg->extra && cfg->extralen > 0) {
        jbyteArray arr = (*env)->NewByteArray(env, cfg->extralen);
        (*env)->SetByteArrayRegion(env, arr, 0, cfg->extralen, (jbyte *)cfg->extra);
        (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "extra", "[B"), arr);
    }
    (*env)->SetIntField(env, obj, (*env)->GetFieldID(env, cls_cfg_desc, "extralen", "I"), (jint)cfg->extralen);
    return obj;
}

static jobject create_dev_desc(JNIEnv *env, struct usb_device_descriptor *dd) {
    jmethodID cid = (*env)->GetMethodID(env, cls_dev_desc, "<init>", "()V");
    jobject obj = (*env)->NewObject(env, cls_dev_desc, cid);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bLength", "B"), (jbyte)dd->bLength);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bDescriptorType", "B"), (jbyte)dd->bDescriptorType);
    (*env)->SetShortField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bcdUSB", "S"), (jshort)dd->bcdUSB);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bDeviceClass", "B"), (jbyte)dd->bDeviceClass);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bDeviceSubClass", "B"), (jbyte)dd->bDeviceSubClass);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bDeviceProtocol", "B"), (jbyte)dd->bDeviceProtocol);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bMaxPacketSize0", "B"), (jbyte)dd->bMaxPacketSize0);
    (*env)->SetShortField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "idVendor", "S"), (jshort)dd->idVendor);
    (*env)->SetShortField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "idProduct", "S"), (jshort)dd->idProduct);
    (*env)->SetShortField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bcdDevice", "S"), (jshort)dd->bcdDevice);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "iManufacturer", "B"), (jbyte)dd->iManufacturer);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "iProduct", "B"), (jbyte)dd->iProduct);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "iSerialNumber", "B"), (jbyte)dd->iSerialNumber);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev_desc, "bNumConfigurations", "B"), (jbyte)dd->bNumConfigurations);
    return obj;
}

static jobject create_device(JNIEnv *env, struct usb_device *dev, jobject bus_obj) {
    if (!dev) return NULL;
    jmethodID cid = (*env)->GetMethodID(env, cls_dev, "<init>", "()V");
    jobject obj = (*env)->NewObject(env, cls_dev, cid);
    (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_dev, "next", "Lch/ntb/usb/Usb_Device;"), create_device(env, dev->next, bus_obj));
    (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_dev, "filename", "Ljava/lang/String;"), (*env)->NewStringUTF(env, dev->filename));
    (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_dev, "bus", "Lch/ntb/usb/Usb_Bus;"), bus_obj);
    (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_dev, "descriptor", "Lch/ntb/usb/Usb_Device_Descriptor;"), create_dev_desc(env, &dev->descriptor));
    if (dev->config && dev->descriptor.bNumConfigurations > 0) {
        jobjectArray cfgs = (*env)->NewObjectArray(env, dev->descriptor.bNumConfigurations, cls_cfg_desc, NULL);
        for (int i = 0; i < dev->descriptor.bNumConfigurations; i++) {
            (*env)->SetObjectArrayElement(env, cfgs, i, create_cfg_desc(env, &dev->config[i]));
        }
        (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_dev, "config", "[Lch/ntb/usb/Usb_Config_Descriptor;"), cfgs);
    }
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev, "devnum", "B"), (jbyte)dev->devnum);
    (*env)->SetByteField(env, obj, (*env)->GetFieldID(env, cls_dev, "num_children", "B"), (jbyte)dev->num_children);
    (*env)->SetLongField(env, obj, (*env)->GetFieldID(env, cls_dev, "devStructAddr", "J"), (jlong)(intptr_t)dev);
    return obj;
}

static jobject create_bus(JNIEnv *env, struct usb_bus *bus) {
    if (!bus) return NULL;
    jmethodID cid = (*env)->GetMethodID(env, cls_bus, "<init>", "()V");
    jobject obj = (*env)->NewObject(env, cls_bus, cid);
    (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_bus, "next", "Lch/ntb/usb/Usb_Bus;"), create_bus(env, bus->next));
    (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_bus, "dirname", "Ljava/lang/String;"), (*env)->NewStringUTF(env, bus->dirname));
    (*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls_bus, "devices", "Lch/ntb/usb/Usb_Device;"), create_device(env, bus->devices, obj));
    (*env)->SetLongField(env, obj, (*env)->GetFieldID(env, cls_bus, "location", "J"), (jlong)bus->location);
    return obj;
}

JNIEXPORT void JNICALL Java_ch_ntb_usb_LibusbJava_usb_1set_1debug(JNIEnv *env, jclass cls, jint level) { usb_set_debug(level); }
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1error_1no(JNIEnv *env, jclass cls, jint err) {
    switch (err) {
        case 0: return 0;
        case 1: return EBADF;
        case 2: return ENOENT;
        case 3: return EINTR;
        case 4: return EIO;
        case 5: return EBUSY;
        case 6: return EEXIST;
        case 7: return ENODEV;
        case 8: return EINVAL;
        case 9: return EPIPE;
        case 10: return ETIMEDOUT;
        default: return err;
    }
}
JNIEXPORT void JNICALL Java_ch_ntb_usb_LibusbJava_usb_1init(JNIEnv *env, jclass cls) { init_classes(env); usb_init(); }
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1find_1busses(JNIEnv *env, jclass cls) { return (jint)usb_find_busses(); }
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1find_1devices(JNIEnv *env, jclass cls) { return (jint)usb_find_devices(); }
JNIEXPORT jobject JNICALL Java_ch_ntb_usb_LibusbJava_usb_1get_1busses(JNIEnv *env, jclass cls) { init_classes(env); return create_bus(env, usb_get_busses()); }

JNIEXPORT jlong JNICALL Java_ch_ntb_usb_LibusbJava_usb_1open(JNIEnv *env, jclass cls, jobject dev_obj) {
    if (!dev_obj) return 0;
    init_classes(env);
    jfieldID fid = (*env)->GetFieldID(env, cls_dev, "devStructAddr", "J");
    struct usb_device *dev = (struct usb_device *)(intptr_t)(*env)->GetLongField(env, dev_obj, fid);
    if (!dev) return 0;
    return (jlong)(intptr_t)usb_open(dev);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1close(JNIEnv *env, jclass cls, jlong handle) {
    if (!handle) return -EINVAL;
    return (jint)usb_close((usb_dev_handle *)(intptr_t)handle);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1set_1configuration(JNIEnv *env, jclass cls, jlong handle, jint cfg) {
    if (!handle) return -EINVAL;
    if (cfg == 1) return 0;
    int r = usb_set_configuration((usb_dev_handle *)(intptr_t)handle, cfg);
    return (jint)(r == -EBUSY ? 0 : r);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1set_1altinterface(JNIEnv *env, jclass cls, jlong handle, jint alt) {
    if (!handle) return -EINVAL;
    if (alt == 0) return 0;
    return (jint)usb_set_altinterface((usb_dev_handle *)(intptr_t)handle, alt);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1clear_1halt(JNIEnv *env, jclass cls, jlong handle, jint ep) {
    if (!handle) return -EINVAL;
    return (jint)usb_clear_halt((usb_dev_handle *)(intptr_t)handle, (unsigned int)ep);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1reset(JNIEnv *env, jclass cls, jlong handle) {
    if (!handle) return -EINVAL;
    return (jint)usb_reset((usb_dev_handle *)(intptr_t)handle);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1claim_1interface(JNIEnv *env, jclass cls, jlong handle, jint iface) {
    if (!handle) return -EINVAL;
    usb_dev_handle *h = (usb_dev_handle *)(intptr_t)handle;
    usb_detach_kernel_driver_np(h, iface);
    return (jint)usb_claim_interface(h, iface);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1release_1interface(JNIEnv *env, jclass cls, jlong handle, jint iface) {
    if (!handle) return -EINVAL;
    return (jint)usb_release_interface((usb_dev_handle *)(intptr_t)handle, iface);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1control_1msg(JNIEnv *env, jclass cls, jlong handle, jint reqtype, jint req, jint val, jint idx, jbyteArray bytes, jint size, jint timeout) {
    if (!handle) return -EINVAL;
    jbyte *buf = bytes ? (*env)->GetByteArrayElements(env, bytes, NULL) : NULL;
    int ret = usb_control_msg((usb_dev_handle *)(intptr_t)handle, reqtype, req, val, idx, (char *)buf, size, timeout);
    if (buf) (*env)->ReleaseByteArrayElements(env, bytes, buf, 0);
    return (jint)ret;
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1get_1string(JNIEnv *env, jclass cls, jlong handle, jint idx, jint langid, jbyteArray buf, jint buflen) {
    if (!handle || !buf) return -EINVAL;
    jbyte *ptr = (*env)->GetByteArrayElements(env, buf, NULL);
    int ret = usb_get_string((usb_dev_handle *)(intptr_t)handle, idx, langid, (char *)ptr, buflen);
    (*env)->ReleaseByteArrayElements(env, buf, ptr, 0);
    return (jint)ret;
}
JNIEXPORT jstring JNICALL Java_ch_ntb_usb_LibusbJava_usb_1get_1string_1simple(JNIEnv *env, jclass cls, jlong handle, jint idx) {
    if (!handle) return NULL;
    char buf[256] = {0};
    if (usb_get_string_simple((usb_dev_handle *)(intptr_t)handle, idx, buf, sizeof(buf)) < 0) return NULL;
    return (*env)->NewStringUTF(env, buf);
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1get_1descriptor(JNIEnv *env, jclass cls, jlong handle, jbyte type, jbyte idx, jbyteArray buf, jint size) {
    if (!handle || !buf) return -EINVAL;
    jbyte *ptr = (*env)->GetByteArrayElements(env, buf, NULL);
    int ret = usb_get_descriptor((usb_dev_handle *)(intptr_t)handle, (unsigned char)type, (unsigned char)idx, ptr, size);
    (*env)->ReleaseByteArrayElements(env, buf, ptr, 0);
    return (jint)ret;
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1get_1descriptor_1by_1endpoint(JNIEnv *env, jclass cls, jlong handle, jint ep, jbyte type, jbyte idx, jbyteArray buf, jint size) {
    if (!handle || !buf) return -EINVAL;
    jbyte *ptr = (*env)->GetByteArrayElements(env, buf, NULL);
    int ret = usb_get_descriptor_by_endpoint((usb_dev_handle *)(intptr_t)handle, ep, (unsigned char)type, (unsigned char)idx, ptr, size);
    (*env)->ReleaseByteArrayElements(env, buf, ptr, 0);
    return (jint)ret;
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1bulk_1write(JNIEnv *env, jclass cls, jlong handle, jint ep, jbyteArray bytes, jint size, jint timeout) {
    if (!handle || !bytes) return -EINVAL;
    jbyte *buf = (*env)->GetByteArrayElements(env, bytes, NULL);
    int t = timeout < 1000 ? 1000 : timeout;
    int ret = usb_bulk_write((usb_dev_handle *)(intptr_t)handle, ep, (char *)buf, size, t);
    (*env)->ReleaseByteArrayElements(env, bytes, buf, JNI_ABORT);
    return (jint)ret;
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1bulk_1read(JNIEnv *env, jclass cls, jlong handle, jint ep, jbyteArray bytes, jint size, jint timeout) {
    if (!handle || !bytes) return -EINVAL;
    jbyte *buf = (*env)->GetByteArrayElements(env, bytes, NULL);
    int t = timeout < 1000 ? 1000 : timeout;
    int ret = usb_bulk_read((usb_dev_handle *)(intptr_t)handle, ep, (char *)buf, size, t);
    (*env)->ReleaseByteArrayElements(env, bytes, buf, 0);
    return (jint)ret;
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1interrupt_1write(JNIEnv *env, jclass cls, jlong handle, jint ep, jbyteArray bytes, jint size, jint timeout) {
    if (!handle || !bytes) return -EINVAL;
    jbyte *buf = (*env)->GetByteArrayElements(env, bytes, NULL);
    int ret = usb_interrupt_write((usb_dev_handle *)(intptr_t)handle, ep, (char *)buf, size, timeout);
    (*env)->ReleaseByteArrayElements(env, bytes, buf, JNI_ABORT);
    return (jint)ret;
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1interrupt_1read(JNIEnv *env, jclass cls, jlong handle, jint ep, jbyteArray bytes, jint size, jint timeout) {
    if (!handle || !bytes) return -EINVAL;
    jbyte *buf = (*env)->GetByteArrayElements(env, bytes, NULL);
    int ret = usb_interrupt_read((usb_dev_handle *)(intptr_t)handle, ep, (char *)buf, size, timeout);
    (*env)->ReleaseByteArrayElements(env, bytes, buf, 0);
    return (jint)ret;
}
JNIEXPORT jstring JNICALL Java_ch_ntb_usb_LibusbJava_usb_1strerror(JNIEnv *env, jclass cls) {
    const char *s = usb_strerror();
    return (*env)->NewStringUTF(env, s ? s : "Unknown USB error");
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1get_1driver_1np(JNIEnv *env, jclass cls, jlong handle, jint iface, jbyteArray name, jint namelen) {
    if (!handle || !name) return -EINVAL;
    jbyte *buf = (*env)->GetByteArrayElements(env, name, NULL);
    int ret = usb_get_driver_np((usb_dev_handle *)(intptr_t)handle, iface, (char *)buf, namelen);
    (*env)->ReleaseByteArrayElements(env, name, buf, 0);
    return (jint)ret;
}
JNIEXPORT jint JNICALL Java_ch_ntb_usb_LibusbJava_usb_1detach_1kernel_1driver_1np(JNIEnv *env, jclass cls, jlong handle, jint iface) {
    if (!handle) return -EINVAL;
    return (jint)usb_detach_kernel_driver_np((usb_dev_handle *)(intptr_t)handle, iface);
}
CSRC

USB_PLUGIN_DIR="$(find "${INSTALL_DIR}/plugins" -maxdepth 1 -type d -name "ch.ntb.usb_*" | head -n 1)"
gcc -fPIC -shared -O2 \
    -I"${JNI_INC}" \
    -I"${JNI_LINUX_INC}" \
    "${WORK_DIR}/libusbjava_src/LibusbJava.c" \
    -o "${USB_PLUGIN_DIR}/libusbJava.so" \
    -lusb

echo "    Built: ${USB_PLUGIN_DIR}/libusbJava.so"

# 5. Create launcher script & desktop entry
echo "[4/5] Creating launcher in ${BIN_DIR}/owon-vds..."
LAUNCHER_JAR="$(find "${INSTALL_DIR}/plugins" -maxdepth 1 -name "org.eclipse.equinox.launcher_*.jar" | head -n 1)"
LAUNCHER_JAR_REL="plugins/$(basename "${LAUNCHER_JAR}")"

7z e -so "${INSTALL_DIR}/plugins/com.owon.vds.foundation_1.0.0.jar" com/owon/uppersoft/dso/image/launcher.png > "${INSTALL_DIR}/icon.png" 2>/dev/null || true

cat > "${BIN_DIR}/owon-vds" <<EOF
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="${INSTALL_DIR}"
cd "\${APP_DIR}"
export LD_LIBRARY_PATH="${USB_PLUGIN_DIR}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
exec "\${APP_DIR}/jre/bin/java" \\
    -Djava.library.path="${USB_PLUGIN_DIR}" \\
    -jar "${LAUNCHER_JAR_REL}" \\
    -configuration configuration \\
    "\$@"
EOF
chmod +x "${BIN_DIR}/owon-vds"

cat > "${APP_DIR}/owon-vds3102.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OWON VDS3102 Oscilloscope
Comment=PC Oscilloscope Software (Multicomp Pro MP720019 / OWON VDS_S2)
Exec=${BIN_DIR}/owon-vds
Icon=${INSTALL_DIR}/icon.png
Terminal=false
Categories=Development;Electronics;Engineering;
EOF

# 6. Install udev rule for USB 5345:1234 & Kernel 6.14.5+/7.x usb_serial_simple unbind
echo "[5/5] USB permissions & Kernel 7.x driver rule (5345:1234)..."
read -r -d '' UDEV_CONTENT <<'UDEV' || true
SUBSYSTEM=="usb", ATTR{idVendor}=="5345", ATTR{idProduct}=="1234", MODE="0666", TAG+="uaccess", ATTR{power/control}="on"
ACTION=="bind", SUBSYSTEM=="usb", DRIVER=="usb_serial_simple", ATTRS{idVendor}=="5345", ATTRS{idProduct}=="1234", RUN+="/bin/sh -c 'echo -n $kernel > /sys/bus/usb/drivers/usb_serial_simple/unbind'"
UDEV

NEED_UDEV=1
if [[ -f /etc/udev/rules.d/99-owon-vds.rules ]] && grep -q 'ACTION=="bind"' /etc/udev/rules.d/99-owon-vds.rules; then
    NEED_UDEV=0
fi

if [[ ${NEED_UDEV} -eq 1 ]]; then
    echo ""
    echo "Installing /etc/udev/rules.d/99-owon-vds.rules for non-root USB access,"
    echo "autosuspend disable, and automatic usb_serial_simple unbinding..."
    read -r -p "Install/update udev rule now (requires sudo)? [Y/n] " UDEV_REPLY
    if [[ "${UDEV_REPLY:-Y}" =~ ^[Yy]$ ]]; then
        printf '%s\n' "${UDEV_CONTENT}" | sudo tee /etc/udev/rules.d/99-owon-vds.rules >/dev/null
        sudo udevadm control --reload-rules
        sudo udevadm trigger --attr-match=idVendor=5345 --attr-match=idProduct=1234
        echo "    Installed /etc/udev/rules.d/99-owon-vds.rules."
    else
        echo "    Skipped udev rule."
    fi
fi

echo ""
echo "=== Installation Complete! ==="
echo "Run 'owon-vds' from your terminal (ensure ~/.local/bin is in your PATH) or launch 'OWON VDS3102 Oscilloscope' from your application menu."
