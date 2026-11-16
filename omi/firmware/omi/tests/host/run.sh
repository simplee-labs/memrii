#!/usr/bin/env bash
# Host tests for the firmware: no nRF Connect SDK needed, only a C compiler and
# Python 3. Run from anywhere: omi/firmware/omi/tests/host/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../../src" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

CC="${CC:-cc}"
"$CC" -std=c11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -include "$HERE/stubs/prelude.h" -I"$HERE/stubs" -I"$SRC" \
  -o "$OUT/sd_ring_test" "$HERE/sd_ring_test.c" "$SRC/lib/core/sd_ring.c"

status=0
for seed in 12345 1 7 99 2024; do
  echo -n "sd_ring seed $seed: "
  "$OUT/sd_ring_test" "$seed" || status=1
done

python3 "$HERE/package_firmware_test.py" || status=1
exit "$status"
