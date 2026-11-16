#!/usr/bin/env python3
"""Check a sysbuild output directory against what deployed devices need.

    check_build.py <build-dir> [--key root-rsa-2048.pem] [--imgtool imgtool.py]

Run after `west build --sysbuild ...` (the Firmware workflow runs it on every build;
it also works on a local build). Each check guards something an over-the-air update
cannot undo or that devices in the field depend on:

  - the flash layout every device already has (see "Memory Layout" in
    BUILD_AND_OTA_FLASH.md): an image for a different layout needs wired recovery;
  - the MCUboot settings the trailer arithmetic in src/settings.c assumes;
  - the DFU zip: both core images, signed with the key field bootloaders trust,
    image version 0.0.0+0, and exactly one version.txt matching omi.conf.

Exits non-zero if any check fails. Without --imgtool the signature check is skipped.
"""
import argparse
import json
import pathlib
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

APP_DIR = pathlib.Path(__file__).resolve().parents[1]

# Deployed layout: (address, end_address). Changing any of these breaks OTA for devices
# in the field; settings.c asserts the internal-flash part at compile time too.
LAYOUT = {
    'mcuboot': (0x0, 0x10000),
    'mcuboot_primary': (0x10000, 0x100000),
    'mcuboot_secondary': (0x0, 0xf0000),        # external flash: app-core update slot
    'mcuboot_secondary_1': (0xf0000, 0x130000),  # external flash: network-core update slot
    'sram_retained_mem': (0x2006f000, 0x20070000),
}
APP_ADDRESS = 0x10200
SETTINGS_END_MAX = 0xfe000     # settings.c: two sectors below the primary slot top
BOOT_MAX_IMG_SECTORS_MAX = 678  # settings.c: above this the trailer erase reaches settings
MCUBOOT_MAGIC = 0x96f3b83d
IMAGE_VERSION = '0.0.0+0'       # README "Versioning": deliberately unset

results = []


def check(name, ok, detail=''):
    results.append(ok)
    print(f'{"PASS" if ok else "FAIL"}  {name}' + (f' — {detail}' if detail else ''))


def read_config(path):
    values = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        m = re.match(r'^(CONFIG_\w+)=(.*)$', line)
        if m:
            values[m.group(1)] = m.group(2)
    return values


def check_layout(build):
    path = build / 'partitions.yml'
    if not path.exists():
        check('partitions.yml present', False, str(path))
        return
    import yaml  # PyYAML ships with the NCS toolchain

    parts = yaml.safe_load(path.read_text(encoding='utf-8'))
    for name, (start, end) in LAYOUT.items():
        p = parts.get(name)
        got = (p.get('address'), p.get('end_address')) if p else None
        check(f'layout: {name} at {start:#x}-{end:#x}', got == (start, end),
              'missing' if got is None else f'got {got[0]:#x}-{got[1]:#x}')
    app = parts.get('app', {}).get('address')
    check(f'layout: app linked at {APP_ADDRESS:#x}', app == APP_ADDRESS,
          'missing' if app is None else f'got {app:#x}')
    s = parts.get('settings_storage')
    ok = bool(s) and APP_ADDRESS <= s['address'] and s['end_address'] <= SETTINGS_END_MAX
    check(f'layout: settings_storage inside the slot, ending at or below {SETTINGS_END_MAX:#x}', ok,
          'missing' if not s else f'got {s["address"]:#x}-{s["end_address"]:#x}')


def check_configs(build, version):
    app_cfg = build / 'omi' / 'zephyr' / '.config'
    boot_cfg = build / 'mcuboot' / 'zephyr' / '.config'
    for path in (app_cfg, boot_cfg):
        if not path.exists():
            check(f'{path.relative_to(build)} present', False)
            return
    app = read_config(app_cfg)
    check('app: DIS firmware revision matches omi.conf',
          app.get('CONFIG_BT_DIS_FW_REV_STR') == f'"{version}"',
          f'{app.get("CONFIG_BT_DIS_FW_REV_STR")} vs "{version}"')
    boot = read_config(boot_cfg)
    check('mcuboot: overwrite-only (CONFIG_BOOT_UPGRADE_ONLY=y)', boot.get('CONFIG_BOOT_UPGRADE_ONLY') == 'y')
    sectors = int(boot.get('CONFIG_BOOT_MAX_IMG_SECTORS', '0'))
    check(f'mcuboot: CONFIG_BOOT_MAX_IMG_SECTORS <= {BOOT_MAX_IMG_SECTORS_MAX}',
          0 < sectors <= BOOT_MAX_IMG_SECTORS_MAX, f'got {sectors}')


def header_version(data):
    """MCUboot image header: magic, load_addr, hdr_size, protect_tlv_size, img_size, flags, version."""
    if len(data) < 32:
        return None
    magic, = struct.unpack_from('<I', data, 0)
    if magic != MCUBOOT_MAGIC:
        return None
    major, minor, rev, build = struct.unpack_from('<BBHI', data, 20)
    return f'{major}.{minor}.{rev}+{build}'


def verify_signature(imgtool, key, data, name):
    with tempfile.TemporaryDirectory() as tmp:
        img = pathlib.Path(tmp, name)
        img.write_bytes(data)
        cmd = [sys.executable, imgtool] if imgtool.endswith('.py') else [imgtool]
        run = subprocess.run(cmd + ['verify', '-k', key, str(img)], capture_output=True, text=True)
    out = (run.stdout + run.stderr).strip()
    return run.returncode == 0 and 'correctly validated' in out, out.splitlines()[0] if out else ''


def check_zip(build, version, key, imgtool):
    path = build / 'dfu_application.zip'
    if not path.exists():
        check('dfu_application.zip present', False, str(path))
        return
    with zipfile.ZipFile(path) as z:
        names = [i.filename for i in z.infolist()]
        stamps = [z.read(i).decode('utf-8', 'replace').strip() for i in z.infolist() if i.filename == 'version.txt']
        check('zip: exactly one version.txt, matching omi.conf', stamps == [version], f'got {stamps}')
        if 'manifest.json' not in names:
            check('zip: manifest.json present', False)
            return
        files = json.loads(z.read('manifest.json')).get('files', [])
        by_index = {str(f.get('image_index')): f for f in files}
        check('zip: app (image 0) and network core (image 1) both present',
              set(by_index) == {'0', '1'}, f'image_index values {sorted(by_index)}')
        app = by_index.get('0')
        if app:
            load = app.get('load_address')
            load = int(load, 0) if isinstance(load, str) else load
            check(f'zip: app load_address {APP_ADDRESS:#x}', load == APP_ADDRESS,
                  f'got {load:#x}' if isinstance(load, int) else f'got {load}')
            if 'version_MCUBOOT' in app:
                check(f'zip: app version_MCUBOOT {IMAGE_VERSION}', app['version_MCUBOOT'] == IMAGE_VERSION,
                      f'got {app["version_MCUBOOT"]}')
        for index, entry in sorted(by_index.items()):
            name = entry.get('file')
            if name not in names:
                check(f'zip: image {index} file {name} present', False)
                continue
            data = z.read(name)
            ver = header_version(data)
            check(f'zip: image {index} ({name}) is an MCUboot image', ver is not None)
            if index == '0' and ver is not None:
                check(f'zip: app image header version {IMAGE_VERSION}', ver == IMAGE_VERSION, f'got {ver}')
            if imgtool and key:
                ok, msg = verify_signature(imgtool, key, data, name)
                check(f'zip: image {index} ({name}) signature verifies against {pathlib.Path(key).name}', ok, msg)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('build_dir', type=pathlib.Path)
    ap.add_argument('--conf', type=pathlib.Path, default=APP_DIR / 'omi.conf')
    ap.add_argument('--key', help="MCUboot signing key (the public sample key field bootloaders trust)")
    ap.add_argument('--imgtool', help='imgtool command, or path to imgtool.py')
    args = ap.parse_args()

    conf = args.conf.read_text(encoding='utf-8').replace('\r', '')
    m = re.search(r'^CONFIG_BT_DIS_FW_REV_STR="(.*)"$', conf, re.M)
    if not m:
        sys.exit(f'error: no CONFIG_BT_DIS_FW_REV_STR in {args.conf}')
    version = m.group(1)

    check_layout(args.build_dir)
    check_configs(args.build_dir, version)
    check_zip(args.build_dir, version, args.key, args.imgtool)
    if not (args.imgtool and args.key):
        print('SKIP  image signatures (pass --key and --imgtool to check them)')

    failed = results.count(False)
    print(f'\n{len(results) - failed}/{len(results)} checks passed')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
