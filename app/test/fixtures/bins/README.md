# Real firmware bin fixtures

Two device-written fixtures (app 0.35.6): one 476-byte bin with four frames and a
VAD-resume, and one 36-byte metadata-only rotation.
[real_bin_format_test.dart](../../unit/services/real_bin_format_test.dart) runs the production parser with a
counting stand-in decoder. Firmware strides are 4 + ((payloadLength + 3) & ~3):
dropping alignment changes four frames to one, while synthetic fixtures sharing
the wrong rule cannot expose that misunderstanding.

This validates framing, not PCM/VAD/audio. The host decoder is not mobile libopus.
Synthetic fixtures script controlled speech/silence for downstream tests.

Reported measurements from the larger 118-bin capture:
its walker reached file ends. The two checked-in fixtures do not independently
establish that dataset or its statistics:
1,538,037 VBR frames, payloads 61–160 bytes (mean 87.0), ~309,000 bytes/minute,
~10.3% block padding. Retired 243,000-byte/minute estimate was 21% low: assumed
one-byte rather than four-byte length, 80-byte payload and no padding.

Keep fixture bytes unchanged. Native downloads retain a contiguous prefix and
restart legacy pending prefixes unless their WAL `nativeIntegrityVersion` is 1.
Resume truncates bytes beyond the saved bookmark and rewinds missing/short files;
firmware deletion waits for a complete transfer. These framing fixtures do not
validate that native transfer or downgrade behavior.
These parser fixtures are not new hardware validation.
