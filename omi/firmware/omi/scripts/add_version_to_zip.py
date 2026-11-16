#!/usr/bin/env python3
"""Make sure a firmware zip carries exactly one version.txt, holding VERSION.

    add_version_to_zip.py <zip> <version>

Adds version.txt when the zip has none. Leaves the zip alone when it already
says <version>. Fails, changing nothing, when it says anything else or holds
more than one version.txt: that zip was not built from the omi.conf being
stamped, and the memrii app (which reads the first version.txt it finds) would
show the wrong version for it. Safe to run more than once.
"""
import sys
import zipfile

zip_path, version = sys.argv[1], sys.argv[2]

with zipfile.ZipFile(zip_path) as z:
    # The app trims the value before showing it, so compare trimmed.
    stamps = [z.read(i).decode('utf-8', 'replace').strip()
              for i in z.infolist() if i.filename == 'version.txt']

if not stamps:
    with zipfile.ZipFile(zip_path, 'a') as z:
        z.writestr('version.txt', version)
    print(f'Stamped {version} into {zip_path}')
elif stamps == [version]:
    print(f'{zip_path} already carries version.txt = {version}')
elif len(stamps) > 1:
    sys.exit(f'error: {zip_path} carries {len(stamps)} version.txt entries {stamps}; '
             f'the app reads only the first. Package from the build\'s own '
             f'dfu_application.zip, not from an already-packaged zip.')
else:
    sys.exit(f'error: {zip_path} carries version.txt {stamps[0]!r}, expected {version!r}. '
             f'The zip was not built from this omi.conf: do a pristine build '
             f'(west build -p) and package again.')
