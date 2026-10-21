# memrii firmware — application

The Zephyr application that runs on the Omi Consumer wearable (nRF5340) when it is used
with memrii. It records to the device's own storage whether or not a phone is nearby and
exposes the recordings over BLE for the memrii app to sync.

- NCS: 2.9.0
- Application: this directory (`omi/firmware/omi`)
- Board: `omi/nrf5340/cpuapp` (defined in `../boards/omi/`)

## Build

First set `MEMRII_MCUBOOT_KEY_FILE` to MCUboot's public sample key,
`<NCS>/bootloader/mcuboot/root-rsa-2048.pem` in nRF Connect SDK v2.9.0.
Sysbuild rejects a missing file, and installed bootloaders reject images signed
with any other key. See
[signing prerequisites](../BUILD_AND_OTA_FLASH.md#signing-image-version-and-factory-recovery).

Set up the nRF Connect SDK v2.9.0 environment, then build with `west` and package
the OTA ZIP using the commands in
[`../BUILD_AND_OTA_FLASH.md`](../BUILD_AND_OTA_FLASH.md). Flashing from the app: Device
Settings → Firmware, pick the zip.

## Versioning

The firmware's version is `CONFIG_BT_DIS_FW_REV_STR` in [`omi.conf`](omi.conf), e.g.
`memrii-fw-3.2.0`. It is published in the Device Information Service, shown by the app,
stamped into the DFU zip as `version.txt`, and used to name that zip. The numbers
continue the omi-offline lineage (`oo-3.1.5` was the last), so statements like "firmware
oo-3.1.4 and later" keep their meaning. Bump it for every image that changes: the app
refreshes Android's cached GATT table when the revision changes, and an image reporting a
stale revision can skip that refresh.

**The MCUboot image version is deliberately unset** (every image is `0.0.0+0`), while
`CONFIG_MCUBOOT_DOWNGRADE_PREVENTION=y` is on in `sysbuild/mcuboot.conf`. Setting an image
version can create a one-way compatibility boundary on installed bootloaders that
enforce downgrade prevention: lower-version builds may then be refused. OTA does
not replace every field bootloader. Do not start stamping versions without checking
the installed bootloader and deliberately deciding the downgrade policy.

Motion/product features are disabled, but `src/imu.c` remains active for the
timestamp/time bridge. Low-power accelerometer operation keeps the IMU clock
running; it does not expose a motion feature to the app.

## What is Omi's and what is memrii's

The device is Omi hardware; the firmware is memrii's. Identifiers that existing devices
and installed apps depend on stay as they are, whatever the product is called:

| Identifier | Value | Why it stays |
|---|---|---|
| Advertised name | `Omi` | The app matches a device on it (or on the Settings service UUID) |
| DIS model / manufacturer | `Omi CV 1` / `Based Hardware` | They describe the hardware, truthfully |
| Custom service base UUID | `19b100xx-e8f2-537e-4f6c-d104768a1214` | GATT layout; changing it orphans every paired app |
| NVS settings keys | `omi/...` | Stored settings would be lost on update |
| Board, Kconfig and CMake names | `omi/nrf5340/cpuapp`, `CONFIG_OMI_*`, `project(omi)` | Build plumbing for Omi hardware; renaming buys nothing |
| MCUboot signing key | MCUboot's public `root-rsa-2048.pem`, via `MEMRII_MCUBOOT_KEY_FILE` | Installed bootloaders trust only this key |
