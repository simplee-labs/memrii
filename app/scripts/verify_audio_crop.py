"""Generate synthetic FFmpeg crop references, then compare pulled emulator outputs.

python app/scripts/verify_audio_crop.py generate <temporary-directory>
adb -s emulator-XXXX push <temporary-directory> /data/local/tmp/memrii-crop-fixtures
Run AudioCropDecoderTest on that emulator and pull its crop-comparison directory.
python app/scripts/verify_audio_crop.py compare <temporary-directory> <pulled-directory>

FFmpeg is a developer reference tool only; it is not an app dependency.
"""
import argparse
import array
import json
import math
from pathlib import Path
import subprocess
import struct
import sys
import wave


def ffmpeg(*args):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', *map(str, args)], check=True)


def with_leading_edit(source, output):
    """Add 125 ms of empty edit before a normal AAC priming edit (moov follows mdat)."""
    data = bytearray(source.read_bytes())
    def atoms(start, end):
        while start + 8 <= end:
            size, kind = struct.unpack_from('>I4s', data, start)
            assert size >= 8 and start + size <= end
            yield start, size, kind
            start += size
    movie = next(a for a in atoms(0, len(data)) if a[2] == b'moov')
    assert movie[0] + movie[1] == len(data), 'Test helper requires moov after media data'
    movie_parts = list(atoms(movie[0] + 8, movie[0] + movie[1]))
    mvhd = next(a for a in movie_parts if a[2] == b'mvhd')
    scale = struct.unpack_from('>I', data, mvhd[0] + 20)[0]
    lead = scale // 8
    trak = next(a for a in movie_parts if a[2] == b'trak')
    track_parts = list(atoms(trak[0] + 8, trak[0] + trak[1]))
    tkhd = next(a for a in track_parts if a[2] == b'tkhd')
    edts = next(a for a in track_parts if a[2] == b'edts')
    elst = next(a for a in atoms(edts[0] + 8, edts[0] + edts[1]) if a[2] == b'elst')
    assert data[elst[0] + 8] == 0 and struct.unpack_from('>I', data, elst[0] + 12)[0] == 1
    for atom in (movie, trak, edts, elst):
        struct.pack_into('>I', data, atom[0], atom[1] + 12)
    for offset in (mvhd[0] + 24, tkhd[0] + 28):
        struct.pack_into('>I', data, offset, struct.unpack_from('>I', data, offset)[0] + lead)
    struct.pack_into('>I', data, elst[0] + 12, 2)
    data[elst[0] + 16:elst[0] + 16] = struct.pack('>IiI', lead, -1, 0x10000)
    output.write_bytes(data)


def generate(folder):
    folder.mkdir(parents=True, exist_ok=True)
    cases = []
    for rate, channels, codec in [(16000, 1, 'aac'), (48000, 1, 'aac'), (44100, 2, 'aac'),
                                  (8000, 1, 'aac'), (12000, 1, 'aac'), (24000, 1, 'aac'),
                                  (32000, 1, 'aac'), (16000, 1, 'opus'), (48000, 2, 'opus')]:
        name = f'{codec}-{rate}-{channels}'
        pcm = array.array('h')
        for frame in range(rate * 3):
            t = frame / rate
            # A chirp and distinct channel tones expose offsets, aliasing and downmix gain.
            value = 9000 * math.sin(2 * math.pi * (317 * t + 173 * t * t))
            value += 2200 * math.sin(2 * math.pi * min(1731, rate * 0.2) * t)
            if 0.205 <= t < 0.215 or 1.301 <= t < 1.311:
                value += 7000
            for channel in range(channels):
                pcm.append(round(value if channel == 0 else value * 0.5 + 1700 * math.sin(2 * math.pi * 823 * t)))
        if sys.byteorder != 'little':
            pcm.byteswap()
        wav = folder / f'{name}.wav'
        with wave.open(str(wav), 'wb') as out:
            out.setparams((channels, 2, rate, 0, 'NONE', 'not compressed'))
            out.writeframes(pcm.tobytes())
        source = folder / f'{name}.{"m4a" if codec == "aac" else "ogg"}'
        ffmpeg('-i', wav, '-c:a', 'aac' if codec == 'aac' else 'libopus', '-b:a', '64k', source)
        for label, start, end in [('head', 0, 125000), ('middle', 713125, 1989375), ('tail', 2750000, 3000000)]:
            case = dict(name=f'{name}-{label}', source=source.name, startUs=start, endUs=end)
            cases.append(case)
            ffmpeg('-i', source, '-ss', start / 1e6, '-t', (end - start) / 1e6,
                   '-ac', 1, '-ar', 16000, '-c:a', 'pcm_s16le', folder / f'{case["name"]}-reference.wav')
    # Explicitly cover an edit list containing leading silence as well as priming.
    edited = folder / 'aac-leading-edit.m4a'
    with_leading_edit(folder / 'aac-16000-1.m4a', edited)
    full = folder / 'aac-full-reference.wav'
    ffmpeg('-i', folder / 'aac-16000-1.m4a', '-ac', 1, '-ar', 16000, full)
    full_pcm = array.array('h', [0] * 2000)
    full_pcm.extend(read_pcm(full))
    for label, start, end in [('head', 0, 250000), ('middle', 713125, 1989375), ('tail', 2875000, 3125000)]:
        case = dict(name=f'aac-leading-edit-{label}', source=edited.name, startUs=start, endUs=end)
        cases.append(case)
        selected = full_pcm[start * 16000 // 1000000:end * 16000 // 1000000]
        if sys.byteorder != 'little':
            selected.byteswap()
        with wave.open(str(folder / f'{case["name"]}-reference.wav'), 'wb') as out:
            out.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            out.writeframes(selected.tobytes())
    no_edit = folder / 'aac-no-edit.m4a'
    ffmpeg('-i', folder / 'aac-16000-1.wav', '-c:a', 'aac', '-b:a', '64k', '-use_editlist', '0', no_edit)
    for label, start, end in [('head', 0, 125000), ('middle', 713125, 1989375), ('tail', 2750000, 3000000)]:
        case = dict(name=f'aac-no-edit-{label}', source=no_edit.name, startUs=start, endUs=end)
        cases.append(case)
        ffmpeg('-i', no_edit, '-ss', start / 1e6, '-t', (end - start) / 1e6,
               '-ac', 1, '-ar', 16000, '-c:a', 'pcm_s16le', folder / f'{case["name"]}-reference.wav')
    (folder / 'cases.json').write_text(json.dumps(cases, indent=2))
    print(f'Generated {len(cases)} synthetic crop references in {folder}')


def read_pcm(path):
    with wave.open(str(path), 'rb') as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 16000)
        pcm = array.array('h', wav.readframes(wav.getnframes()))
    if sys.byteorder != 'little':
        pcm.byteswap()
    return pcm


def compare(folder, outputs):
    rows = []
    for case in json.loads((folder / 'cases.json').read_text()):
        name = case['name']
        reference = read_pcm(folder / f'{name}-reference.wav')
        actual = read_pcm(outputs / f'{name}.wav')
        count = case['endUs'] * 16000 // 1000000 - case['startUs'] * 16000 // 1000000
        # Compare an interior window to avoid filter-edge transients and codec padding.
        left, right = 1100, min(len(reference), len(actual)) - 1100
        if right <= left:
            left, right = 300, min(len(reference), len(actual)) - 300
        def correlation(lag):
            pairs = [(reference[i], actual[i + lag]) for i in range(left, right, max(1, (right - left) // 128))
                     if 0 <= i + lag < len(actual)]
            cross = sum(a * b for a, b in pairs)
            norm = math.sqrt(sum(a * a for a, _ in pairs) * sum(b * b for _, b in pairs))
            return cross / norm if norm else 0
        lag = max(range(-1024, 1025), key=correlation)
        ref_rms = math.sqrt(sum(x * x for x in reference[left:right]) / (right - left))
        out_rms = math.sqrt(sum(x * x for x in actual[left:right]) / (right - left))
        row = dict(name=name, expected=count, ffmpegSamples=len(reference), nativeSamples=len(actual),
                   lagSamples=lag, correlation=round(correlation(lag), 6), rmsRatio=round(out_rms / ref_rms, 6))
        rows.append(row)
        assert len(actual) == count, row
        assert abs(lag) <= (1024 if name.startswith('aac') else 1), row
        assert row['correlation'] > 0.98 and 0.95 < row['rmsRatio'] < 1.05, row
    (outputs / 'comparison.json').write_text(json.dumps(rows, indent=2))
    print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['generate', 'compare'])
    parser.add_argument('folder', type=Path)
    parser.add_argument('outputs', type=Path, nargs='?')
    args = parser.parse_args()
    if args.mode == 'generate':
        generate(args.folder)
    else:
        parser.error('compare needs a pulled output directory') if args.outputs is None else compare(args.folder, args.outputs)
