#!/usr/bin/env python3
"""Host test for package_firmware.sh and scripts/add_version_to_zip.py.

Builds small stand-in DFU zips and checks that packaging always yields exactly one
version.txt equal to CONFIG_BT_DIS_FW_REV_STR in omi.conf, and that a zip carrying
another version, or two version.txt entries, fails without leaving an output zip.
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import warnings
import zipfile

APP_DIR = pathlib.Path(__file__).resolve().parents[2]
PACKAGE = APP_DIR / 'package_firmware.sh'
CONF_TEXT = (APP_DIR / 'omi.conf').read_text(encoding='utf-8').replace('\r', '')
VERSION = re.search(r'^CONFIG_BT_DIS_FW_REV_STR="(.*)"$', CONF_TEXT, re.M).group(1)

failures = []


def make_zip(path, stamps):
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')  # a duplicate version.txt is the point of one case
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('manifest.json', '{"files": []}')
            z.writestr('omi.signed.bin', b'\0' * 64)
            for stamp in stamps:
                z.writestr('version.txt', stamp)


def stamps_in(path):
    with zipfile.ZipFile(path) as z:
        return [z.read(i).decode() for i in z.infolist() if i.filename == 'version.txt']


def case(name, stamps, expect_ok):
    with tempfile.TemporaryDirectory() as tmp:
        src = pathlib.Path(tmp, 'dfu_application.zip')
        make_zip(src, stamps)
        out = pathlib.Path(tmp, 'packaged.zip')
        run = subprocess.run(['bash', str(PACKAGE), 'packaged', str(src)], capture_output=True, text=True)
        ok = run.returncode == 0
        if ok != expect_ok:
            failures.append(f'{name}: exit {run.returncode}, expected {"success" if expect_ok else "failure"}\n'
                            f'{run.stdout}{run.stderr}')
            return
        if expect_ok and stamps_in(out) != [VERSION]:
            failures.append(f'{name}: packaged zip carries {stamps_in(out)}, expected [{VERSION!r}]')
        if not expect_ok and out.exists():
            failures.append(f'{name}: failed but left {out.name} behind')
        if expect_ok:
            # Packaging the same input again must not add a second stamp.
            subprocess.run(['bash', str(PACKAGE), 'packaged', str(src)], capture_output=True, check=True)
            if stamps_in(out) != [VERSION]:
                failures.append(f'{name}: second run left {stamps_in(out)}')


case('unstamped zip gets stamped', [], True)
case('matching stamp is kept once', [VERSION], True)
case('different version fails', ['memrii-fw-0.0.1'], False)
case('two version.txt entries fail', [VERSION, VERSION], False)

for f in failures:
    print('FAIL:', f)
print(f'{"FAIL" if failures else "PASS"}: package_firmware.sh ({VERSION}), {4 - len(failures)}/4 cases')
sys.exit(1 if failures else 0)
