# Third-party notices

memrii contains software originally derived from the Based Hardware/Omi open-source
project. memrii is an independent project and is not affiliated with or endorsed by
Based Hardware/Omi.

This file records where memrii's code comes from and which third-party components it
contains or distributes. It is a record of provenance, not legal advice. Where a
component's own license file or header says something different from the summary
here, the component's own text governs.

"Omi" is used in this repository to identify the hardware memrii supports (the Omi
wearable, whose firmware memrii replaces) and the Omi Cloud service memrii can
optionally upload to. It is Based Hardware's name, not memrii's.

---

## 1. Upstream project: Based Hardware / Omi

- Source: <https://github.com/BasedHardware/omi>
- License: MIT
- Copyright (c) 2024 Based Hardware Contributors

The memrii app (`app/`), the memrii firmware (`omi/firmware/`) and the board
definitions began as a fork of that project, and the historical repository
<https://github.com/john-gitdev/omi-offline> records that ancestry. This repository
starts with a clean memrii release snapshot exported from
<https://github.com/john-gitdev/omi-offline> at source commit
`647aaf93fb37e21c7ed63a60fc0bbcf211fa19d8` (memrii 0.1.1).
Much of the upstream code has since been rewritten or removed, but not all
of it, and memrii does not claim that every line is independently authored. The
upstream MIT license text and Based Hardware's copyright notice are kept in
[`LICENSE`](LICENSE), next to memrii's own notice, and continue to apply to the code
derived from it.

The Omi Consumer hardware design files under `omi/hardware/consumer/` are Based
Hardware's, under their own MIT license:
[`omi/hardware/consumer/LICENSE`](omi/hardware/consumer/LICENSE) (Copyright (c) 2024
Based Hardware Contributors). They are unmodified except that GPS location metadata
was removed from two assembly photos (`components-disassembled.jpg` and
`outer-aluminium-covers.jpg`; image data unchanged), and their entries in
`checksums.sha256` and the package README were updated to match.

---

## 2. Vendored in this repository

These are copied into the tree and ship in memrii's builds. Each keeps its original
notice in place; do not strip those headers when editing the files.

### Opus 1.2.1 — firmware audio codec

- Location: `omi/firmware/omi/src/lib/core/lib/opus-1.2.1/`
- Compiled into the firmware image.
- License: BSD 3-clause style, carried in each source file's header.
- Copyright 2001-2011 Xiph.Org Foundation, Skype Limited, Octasic, Jean-Marc Valin,
  Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo
  (see each file for its exact holders).

The vendored directory has no separate COPYING file, so the notice binary
redistribution requires is reproduced here:

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Battery header — firmware

- Location: `omi/firmware/omi/src/lib/core/lib/battery/battery.h`
- License: Apache License 2.0, Copyright 2024 Marcus Alexander Tjomsaas (header in the
  file).

### flutter_onnxruntime 1.7.1 — app plugin

- Location: `app/third_party/flutter_onnxruntime/`
- License: MIT, Copyright (c) 2025 MASIC AI —
  [`app/third_party/flutter_onnxruntime/LICENSE`](app/third_party/flutter_onnxruntime/LICENSE).
- Modified: the iOS podspec's minimum platform was lowered (see `app/pubspec.yaml`).
  The plugin code is otherwise the pub.dev release.

### Silero VAD model v6.2.1

- Location: `app/assets/models/silero_vad.onnx` (identity and hashes in
  [`app/assets/models/README.md`](app/assets/models/README.md))
- Source: <https://github.com/snakers4/silero-vad>, distributed there under the MIT
  License (Silero Team). Bundled unmodified in the APK.

---

## 3. Distributed in builds, not vendored

### Firmware image

The firmware is built with the nRF Connect SDK v2.9.0, and the released DFU images
(`releases/*.zip`) contain code from:

- **Zephyr RTOS** — Apache License 2.0.
- **nRF Connect SDK**, including the SoftDevice Controller and MPSL used by the
  network core — Nordic Semiconductor's licenses (predominantly
  `LicenseRef-Nordic-5-Clause`), as stated in the SDK's own files.
- **MCUboot** — Apache License 2.0.

Their license texts ship with the SDK installation used to build, not with this
repository.

### Android APK

Dart/Flutter packages are resolved from `app/pubspec.lock`, native Android libraries
from the Gradle graph in `app/android/app/build.gradle`. Flutter collects every Dart
package's LICENSE into the APK's `NOTICES` asset at build time. Components that
carry native code worth calling out:

| Component | Brought in by | License (as declared by the component) |
|---|---|---|
| libopus | `opus_flutter_android` (git, `mdmohsin7/opus_flutter`) | BSD (Opus license, above) + BSD 2-clause for the wrapper |
| opus_dart | git, `mdmohsin7/opus_dart` | BSD 2-clause |
| ONNX Runtime for Android 1.22.0 | `com.microsoft.onnxruntime:onnxruntime-android` | MIT (Microsoft) |
| mcumgr_flutter 0.4.2 | pub.dev | BSD 3-clause |
| nordic_dfu 6.2.0 | pub.dev | MIT |
| just_audio 0.9.46 | pub.dev | MIT |
| webview_flutter 4.13.0 | pub.dev | BSD 3-clause (The Flutter Authors) |
| talker_flutter 5.0.0 | pub.dev | MIT |
| OkHttp 4.12.0 | Gradle | Apache License 2.0 |
| AndroidX WorkManager 2.9.1 | Gradle | Apache License 2.0 |
| Flutter engine and framework | Flutter SDK | BSD 3-clause (The Flutter Authors) |
