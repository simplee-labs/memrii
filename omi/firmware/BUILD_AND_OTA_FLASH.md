# memrii firmware: build and OTA flash guide

This guide builds the memrii firmware for the Omi Consumer hardware (nRF5340) with nRF Connect SDK 2.9.0 and flashes it over the air (OTA) — from the memrii app (Device Settings → Firmware) or with the nRF Connect mobile app. See also the [firmware application overview](omi/README.md).

## Table of Contents
- [Prerequisites](#prerequisites)
- [Project Overview](#project-overview)
- [Environment Setup](#environment-setup)
- [Building the Firmware](#building-the-firmware)
- [OTA Flashing Process](#ota-flashing-process)
- [Build Outputs](#build-outputs)
- [Troubleshooting](#troubleshooting)
- [Technical Details](#technical-details)

## Prerequisites

### Hardware Requirements
- **Target Device**: Omi device with nRF5340 SoC (dual-core ARM Cortex-M33)
- **Mobile Device**: iOS or Android device with Bluetooth LE support
- **Development Machine**: macOS, Linux, or Windows

### Software Requirements
- **nRF Connect SDK**: Version 2.9.0
- **nrfutil**: Nordic's command-line utility
- **West**: Zephyr's meta-tool
- **CMake**: Version 3.20.0 or higher
- **Ninja**: Build system
- **Python**: 3.8+ with required packages
- **MCUboot signing key**: before building, set `MEMRII_MCUBOOT_KEY_FILE`
  to MCUboot's public sample key, which nRF Connect SDK installs at
  `<NCS>/bootloader/mcuboot/root-rsa-2048.pem`. Sysbuild fails if it is missing.
  Under Git Bash use a Windows-style absolute path; elsewhere use the host's
  native absolute path. See [firmware signing](#signing-image-version-and-factory-recovery).
- **nRF Connect for Mobile**: iOS/Android app for OTA updates

## Project Overview

The memrii firmware is a dual-core nRF5340 application with the following features:

### Core Features
- **Audio Processing**: OPUS codec for real-time audio compression
- **Bluetooth LE**: MCUmgr-enabled for OTA updates
- **Microphone**: PDM microphone capture with processing
- **User Interface**: LED indicators, haptic feedback, button controls
- **Power Management**: Battery monitoring and charging support
- **Storage**: SD card support for offline audio storage

### Architecture
- **Application Core (Cortex-M33)**: Main application logic
- **Network Core (Cortex-M33)**: Bluetooth stack and radio management
- **Bootloader**: MCUboot for secure OTA updates
- **Partition Manager**: Generates the dual-core layout from build configuration
  and board/static inputs; inspect the generated map for the selected build.

## Environment Setup

### 1. Install nRF Connect SDK 2.9.0

#### Using nrfutil (Recommended)
```bash
# Install nrfutil if not already installed
brew install nrfutil  # macOS
# or download from: https://www.nordicsemi.com/Products/Development-tools/nRF-Util

# Install toolchain manager
nrfutil install toolchain-manager

# Install nRF Connect SDK 2.9.0
nrfutil toolchain-manager install --ncs-version v2.9.0

# Verify installation
nrfutil toolchain-manager search
```

### 2. Install Build Dependencies

#### System Dependencies
```bash
# macOS
brew install ninja ccache

# Ubuntu/Debian
sudo apt install ninja-build ccache

# Windows
# Install via chocolatey or download binaries
```

### 3. Initialize the nRF Connect SDK Workspace

If the `v2.9.0` directory doesn't exist or is empty, you need to initialize the nRF Connect SDK workspace.

Since `west` and required Python dependencies are included in the nRF Connect SDK toolchain, launch the toolchain shell first:

```bash
# Launch the nRF Connect SDK environment
nrfutil toolchain-manager launch --ncs-version v2.9.0 --shell

# Navigate to the firmware directory within the shell
cd /path/to/omi/firmware

# Create and navigate to the v2.9.0 directory
mkdir -p v2.9.0
cd v2.9.0

# Initialize nRF Connect SDK v2.9.0 workspace
west init -m https://github.com/nrfconnect/sdk-nrf --mr v2.9.0

# Download all required repositories (this may take several minutes)
west update
```

**Note**: The `west update` command downloads approximately 1.5GB of source code including:
- Zephyr RTOS
- nRF Connect SDK modules
- MCUboot bootloader
- Various libraries and tools

If the workspace already exists and is properly configured, you can skip to step 4.

## Building the Firmware

### 1. Build Command

Two equivalent options — both produce the same output:

**Option A: CMake preset (recommended, run from `omi/firmware/omi/`)**

```bash
nrfutil toolchain-manager launch --ncs-version v2.9.0 --shell

# In the SDK environment:
cmake --preset OMI
cmake --build build/omi
```

The `CMakePresets.json` in `omi/firmware/omi/` already sets the board (`omi/nrf5340/cpuapp`), conf file (`omi.conf`), and build directory (`build/omi`). No extra flags needed.

**Option B: west build (run from `omi/firmware/v2.9.0/`)**

```bash
nrfutil toolchain-manager launch --ncs-version v2.9.0 --shell

# In the SDK environment:
west build -b omi/nrf5340/cpuapp ../omi --sysbuild -- -DBOARD_ROOT=/path/to/omi/firmware
```

> **Note:** Do not copy `omi.conf` to `prj.conf`. The build system is already configured to use `omi.conf` directly.

### 2. Build Process Overview

The build system will:
1. **Configure MCUboot**: Set up the secure bootloader
2. **Build Network Core**: Compile the Bluetooth radio firmware (`ipc_radio`)
3. **Build Network Bootloader**: Compile the network core bootloader (`b0n`)
4. **Build Application**: Compile the main application
5. **Sign Firmware**: Cryptographically sign all components
6. **Generate OTA Package**: Create `dfu_application.zip`, automatically stamped with `version.txt`

### 3. Build Output

Upon successful completion, you'll see:
```
Memory region         Used Size  Region Size  %age Used
           FLASH:      262908 B     982528 B     26.76%
             RAM:      244556 B       440 KB     54.28%
```

## Build Outputs

The build generates several important files in the `build/` directory:

### OTA Files
- **`dfu_application.zip`** (440 KB) - **Primary OTA package for nRF Connect app**
- `dfu_application.zip_manifest.json` - Package metadata

### Firmware Images
- `merged.hex` (869 KB) - Complete firmware for direct programming
- `signed_by_mcuboot_and_b0_ipc_radio.hex` - Signed application firmware
- `merged_CPUNET.hex` (533 KB) - Network core firmware

### Debug Files
- `build_info.yml` - Build configuration summary
- `partitions.yml` - Memory partition layout
- Individual component builds in subdirectories (`omi/`, `mcuboot/`, `ipc_radio/`, `b0n/`)

## OTA Flashing Process

### 1. Prepare the OTA Package

The build automatically stamps `version.txt` into `dfu_application.zip` via `sysbuild/CMakeLists.txt`. The memrii app reads this to display the version when you load a local zip.

To produce a named release zip:

```bash
cd omi/firmware/omi
./package_firmware.sh
# Reads version from CONFIG_BT_DIS_FW_REV_STR in omi.conf
# Output: build/omi/dfu_application_release.zip
```

Transfer `dfu_application_release.zip` (or `dfu_application.zip`) to your mobile device (email, cloud storage, etc.).

### 2. Install nRF Connect for Mobile

- **iOS**: Download from App Store
- **Android**: Download from Google Play Store

### 3. Flash via OTA

1. **Power on your Omi device** and ensure it's in range
2. **Open nRF Connect for Mobile**
3. **Scan for devices** - look for "Omi" in the device list
4. **Connect** to your Omi device
5. **Navigate to DFU tab** (Device Firmware Update)
6. **Select firmware file**:
   - Tap "Select file" or "Browse"
   - Choose `dfu_application.zip`
7. **Start update**:
   - Tap "Start" or "Upload"
   - Monitor progress (typically 2-5 minutes)
8. **Verify completion** - device will restart with new firmware

### 4. Update Process Details

During OTA update:
- **Stage 1**: Upload to secondary partition (~2-3 minutes)
- **Stage 2**: Verification and swap (automatic)
- **Stage 3**: Device restart with new firmware
- **Stage 4**: Confirmation of successful update

## Troubleshooting

### Build Issues

#### Missing Dependencies
```bash
# Error: ModuleNotFoundError: No module named 'cryptography'
# This typically occurs if you are building outside of the nrfutil shell.
# Ensure you launch the nRF Connect SDK environment first:
# nrfutil toolchain-manager launch --ncs-version v2.9.0 --shell

# Error: ccache: command not found
brew install ccache

# Error: ninja: command not found
brew install ninja
```

#### Board Not Found
```bash
# Error: No board named 'omi' found
# Ensure BOARD_ROOT is set correctly:
west build -b omi/nrf5340/cpuapp ../omi --sysbuild -- -DBOARD_ROOT=/full/path/to/firmware
```

#### Configuration Issues
```bash
# Error: No prj.conf file found
# This should not happen — CMakePresets.json sets CONF_FILE=omi.conf.
# If building outside the preset, pass -DCONF_FILE=/path/to/omi/firmware/omi/omi.conf
```

#### Workspace Issues
```bash
# Error: No such file or directory: v2.9.0
# Initialize the workspace first:
cd /path/to/omi/firmware
mkdir -p v2.9.0 && cd v2.9.0
west init -m https://github.com/nrfconnect/sdk-nrf --mr v2.9.0
west update

# Error: already initialized in /path/to/omi/firmware
# Remove broken workspace and reinitialize:
rm -rf .west
cd v2.9.0
west init -m https://github.com/nrfconnect/sdk-nrf --mr v2.9.0
west update
```

### OTA Flashing Issues

#### Device Not Found
- Ensure Omi device is powered on and in range
- Check Bluetooth is enabled on mobile device
- Try restarting both devices

#### Update Fails
- Verify `dfu_application.zip` file integrity
- Ensure sufficient battery level on Omi device
- Try updating in smaller chunks (app may have options)

#### Connection Issues
- Move closer to the device
- Ensure no other apps are connected to the Omi
- Restart the nRF Connect app

## Technical Details

### Memory Layout

Tracked `boards/omi/pm_static.yml`, DTS and sysbuild configuration are inputs,
not proof of the active layout. Inspect generated `partitions.yml` and
`pm_config.h` in the sysbuild output for flash slots, settings and retained RAM.
The application, network core and bootloaders have separate image/configuration
contexts. OTA preserves already-installed bootloaders; a freshly generated map
does not prove their size/alignment/trailer assumptions. Confirm those properties
against the installed bootloader before relying on an OTA slot layout.

### Security Features
- **Signing**: Images are signed with the key in `MEMRII_MCUBOOT_KEY_FILE`, MCUboot's
  public sample key that Omi bootloaders trust. Images signed with any other key are rejected.
- **Secure Boot**: MCUboot verifies signatures before execution
- **Rollback Protection**: Current builds leave the MCUboot image version at
  `0.0.0+0` and configure downgrade prevention. Installed bootloaders may differ;
  read [image-version compatibility](#signing-image-version-and-factory-recovery)
  before introducing a nonzero version.
- **BLE SMP**: `CONFIG_BT_SMP=y` is enabled; bonding/encryption behaviour is controlled at the app layer

### Build Configuration Highlights
```
CONFIG_NCS_SAMPLE_MCUMGR_BT_OTA_DFU=y    # Enable OTA updates
CONFIG_BT_PERIPHERAL=y                    # Bluetooth peripheral role
CONFIG_MCUMGR_GRP_IMG_ALLOW_ERASE_PENDING=y  # Allow image management
CONFIG_OMI_CODEC_OPUS=y                   # Enable OPUS codec
CONFIG_BOOTLOADER_MCUBOOT=y               # Use MCUboot
```

### Firmware Features
- **Audio Codec**: OPUS for efficient audio compression (16 kHz mono, VBR, complexity 3, 20 ms frames)
- **Bluetooth**: BLE 5.0 with 2M PHY, MTU 498, auto connection parameter negotiation
- **Power Management**: Interrupt-driven button (no polling), 60 s battery ADC when connected, 5 min when disconnected, per-operation SPI power gating
- **Storage**: no filesystem — a raw circular log on the SD NAND (`sd_ring.c`), cursor advanced only after the bytes are durable
- **IMU driver**: `src/imu.c` is built and uses the IMU timestamp as a minimal
  time bridge; low-power accelerometer operation keeps that counter running.
  `CONFIG_OMI_ENABLE_ACCELEROMETER=n` disables motion/product features, not this role.

## Success Indicators

### Build Success
```
[24/24] Generating ../dfu_application.zip
-- west build: finished
```

### OTA Success
- nRF Connect app shows "Update completed successfully"
- Omi device restarts and functions normally
- New firmware version is active

---

## Additional Resources

- [nRF Connect SDK Documentation](https://developer.nordicsemi.com/nRF_Connect_SDK/doc/latest/)
- [MCUboot Documentation](https://docs.mcuboot.com/)
- [nRF Connect for Mobile](https://www.nordicsemi.com/Products/Development-tools/nRF-Connect-for-mobile)
- [Omi hardware documentation (Based Hardware)](https://docs.omi.me/)

---

**Last Updated**: October 2026
**SDK Version**: nRF Connect SDK 2.9.0  
**Target Hardware**: Omi Consumer (nRF5340)  
**Firmware Version**: `memrii-fw-3.2.0` — the current value is `CONFIG_BT_DIS_FW_REV_STR` in
[`omi/omi.conf`](omi/omi.conf), which is the string the app reads over DIS. Check there
rather than trusting this line.

## Signing, image version and factory recovery

The advertised revision (`CONFIG_BT_DIS_FW_REV_STR`, currently
`memrii-fw-3.2.0`) is a DIS/product version, not MCUboot's anti-downgrade
image version. Current signing leaves the image version unset (`0.0.0+0`);
the build enables `CONFIG_MCUBOOT_DOWNGRADE_PREVENTION=y`.
Introducing a nonzero image version can be a one-way compatibility change:
an installed bootloader enforcing downgrade prevention can subsequently reject
older lower-version images, even when they have the right signature. Do not
couple marketing version bumps to MCUboot image versions.

Omi bootloaders, including the one in the factory images below, trust MCUboot's
public sample RSA-2048 key. nRF Connect SDK v2.9.0 installs it at
`<NCS>/bootloader/mcuboot/root-rsa-2048.pem` (for example
`C:/ncs/v2.9.0/bootloader/mcuboot/root-rsa-2048.pem`); point `MEMRII_MCUBOOT_KEY_FILE`
at that file. The key is public, not a secret: upstream Omi publishes the same file.
Field devices keep their bootloader across OTA, so they reject an image signed with
any other key, and generating a new key does not change what they trust; that would
require replacing the bootloader itself. Because the key is public, the signature
check shows that an image is intact, not who built it. The repository does not copy
the file because it is in private-key PEM format, which secret scanners flag.

`omi/firmware/FLASH_3.0.8/` contains upstream factory images for J-Link recovery
when a device cannot accept OTA. It is recovery material, not a disposable local
build. Manufacturing ZIPs under `omi/hardware/consumer/` are checksum-verified
design source and remain tracked. The generated `releases/` policy does not
apply to either collection.

A release asset should retain its source commit, SDK/toolchain versions and
SHA-256 digest. The build script can auto-select an installed SDK/toolchain;
no byte-identical reproducibility guarantee follows from its versioned filename.
