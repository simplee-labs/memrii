package me.memrii.app

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlin.math.sin

/** Decode on a worker thread. All frame positions below are on the playback timeline. */
internal object AudioCropDecoder {
    private const val OUTPUT_RATE = 16000
    private const val TIMEOUT_US = 10000L
    private val supportedRates = setOf(8000, 12000, 16000, 24000, 32000, 44100, 48000)

    fun crop(sourcePath: String, outputPath: String, startUs: Long, endUs: Long) {
        require(startUs >= 0 && endUs > startUs) { "Choose a non-empty crop range." }
        val source = File(sourcePath)
        val output = File(outputPath)
        require(source.canonicalPath != output.canonicalPath) { "Crop output must differ from its source." }
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var writer: PcmCropWriter? = null
        var createdOutput = false
        try {
            extractor.setDataSource(sourcePath)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("The recording contains no audio track.")
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: error("Missing audio format.")
            require(mime == MediaFormat.MIMETYPE_AUDIO_AAC || mime == MediaFormat.MIMETYPE_AUDIO_OPUS) {
                "Unsupported recording codec: $mime. Expected AAC/M4A or Ogg Opus."
            }
            val rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            require(rate in supportedRates) { "Unsupported source sample rate: $rate Hz." }
            val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            require(channels in 1..8) { "Unsupported channel count: $channels." }
            extractor.selectTrack(track)
            val firstPts = extractor.sampleTime
            require(firstPts >= -10_000_000L && extractor.sampleTrackIndex == track) { "The recording is empty." }

            val opus = mime == MediaFormat.MIMETYPE_AUDIO_OPUS
            val preSkip = if (opus) opusPreSkip(format) else 0
            val timeline = if (opus) {
                Timeline(0, 0, format.longOrNull(MediaFormat.KEY_DURATION)?.let { usToFrames(it, rate) })
            } else {
                Mp4Timeline.read(source, rate) ?: Timeline(
                    format.intOrZero(MediaFormat.KEY_ENCODER_DELAY).toLong(), 0,
                    format.longOrNull(MediaFormat.KEY_DURATION)?.let {
                        usToFrames(it, rate) - format.intOrZero(MediaFormat.KEY_ENCODER_DELAY) -
                            format.intOrZero(MediaFormat.KEY_ENCODER_PADDING)
                    }
                )
            }
            timeline.duration?.let {
                require(endUs / 1000 <= it * 1000 / rate + 1) { "The crop range exceeds the recording." }
            }

            // App M4A is 16 kHz. Android's Opus decoder outputs 48 kHz; support standard
            // legacy AAC rates too. A centered FIR below removes aliasing on downsampling.
            val targetFrames = endUs * OUTPUT_RATE / 1_000_000 - startUs * OUTPUT_RATE / 1_000_000
            require(targetFrames in 1..((0xffff_ffffL - 36) / 2)) { "The selected WAV range is too large or empty." }

            // Own priming once, rather than combining platform-version-dependent edit-list
            // conversion with MediaCodec's SkipCutBuffer. Rebase AAC packet PTS against the
            // first stored packet, then apply media time in the track's timescale ourselves.
            format.setInteger(MediaFormat.KEY_ENCODER_DELAY, 0)
            format.setInteger(MediaFormat.KEY_ENCODER_PADDING, 0)
            format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            if (opus) {
                // OpusHead's pre-skip is in 48 kHz samples. MediaExtractor has already
                // subtracted it from packet PTS (clamping early packets to zero on API 26).
                // Supply explicit packet times and disable the decoder's second skip.
                format.setByteBuffer("csd-1", ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).putLong(0).apply { flip() })
                format.setByteBuffer("csd-2", ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).putLong(0).apply { flip() })
            }
            val mediaStart = (usToFrames(startUs, rate) + timeline.trim - timeline.lead).coerceAtLeast(0)
            // Warm up stateful codecs and retain FIR context before the selected range.
            val seekUs = (mediaStart * 1_000_000 / rate - 100_000).coerceAtLeast(0)
            // Keep the initial packet when warm-up starts at the beginning. Some MP4
            // extractors skip it even on seekTo(0) when an empty edit precedes priming.
            if (seekUs > 0) {
                extractor.seekTo(if (opus) seekUs else seekUs + firstPts, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }
            var earlyOpusFrame = -preSkip.toLong()
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
            createdOutput = true
            writer = PcmCropWriter(output, rate, startUs, endUs, timeline)
            val info = MediaCodec.BufferInfo()
            var inputEnded = false
            var outputEnded = false
            var emptyPolls = 0
            var outputEncoding = AudioFormat.ENCODING_PCM_16BIT
            while (!outputEnded && !writer.complete) {
                var progressed = false
                if (!inputEnded) {
                    val index = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val input = codec.getInputBuffer(index) ?: error("Missing decoder input buffer.")
                        input.clear()
                        val size = extractor.readSampleData(input, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEnded = true
                        } else {
                            val pts = if (opus) {
                                val frames = if (extractor.sampleTime <= 0) earlyOpusFrame else usToFrames(extractor.sampleTime, rate)
                                earlyOpusFrame = frames + opusPacketFrames(input, size)
                                frames * 1_000_000 / rate
                            } else extractor.sampleTime - firstPts
                            codec.queueInputBuffer(index, 0, size, pts, 0)
                            extractor.advance()
                        }
                        progressed = true
                    }
                }
                when (val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val decoded = codec.outputFormat
                        require(decoded.getInteger(MediaFormat.KEY_SAMPLE_RATE) == rate &&
                            decoded.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == channels) {
                            "The decoder changed the source rate or channel layout unexpectedly."
                        }
                        outputEncoding = if (decoded.containsKey(MediaFormat.KEY_PCM_ENCODING))
                            decoded.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                        require(outputEncoding == AudioFormat.ENCODING_PCM_16BIT || outputEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                            "Unsupported decoded PCM encoding: $outputEncoding."
                        }
                        progressed = true
                    }
                    else -> if (index >= 0) {
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                val buffer = codec.getOutputBuffer(index) ?: error("Missing decoder output buffer.")
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                buffer.order(ByteOrder.LITTLE_ENDIAN)
                                val frameBytes = channels * if (outputEncoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                                require(info.size % frameBytes == 0) { "The decoder returned a partial PCM frame." }
                                val position = usToFrames(info.presentationTimeUs, rate) - timeline.trim + timeline.lead
                                repeat(info.size / frameBytes) { frame ->
                                    var mono = 0.0
                                    repeat(channels) {
                                        mono += if (outputEncoding == AudioFormat.ENCODING_PCM_FLOAT)
                                            buffer.float.toDouble().coerceIn(-1.0, 1.0) * 32768 else buffer.short.toDouble()
                                    }
                                    writer.add(position + frame, mono / channels)
                                }
                            }
                            outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        } finally {
                            codec.releaseOutputBuffer(index, false)
                        }
                        progressed = true
                    }
                }
                if (progressed) emptyPolls = 0 else require(++emptyPolls < 500) { "Audio decoder stalled for 10 seconds." }
            }
            writer.finish()
        } catch (e: Exception) {
            writer?.close()
            if (createdOutput) output.delete()
            throw e
        } finally {
            writer?.close()
            try { codec?.stop() } catch (_: Exception) { /* May not have reached start. */ }
            try { codec?.release() } finally { extractor.release() }
        }
    }

    private fun opusPreSkip(format: MediaFormat): Int {
        val head = format.getByteBuffer("csd-0")?.duplicate()?.order(ByteOrder.LITTLE_ENDIAN)
            ?: error("Ogg Opus is missing OpusHead.")
        require(head.remaining() >= 19) { "Truncated OpusHead." }
        return head.getShort(head.position() + 10).toInt() and 0xffff
    }

    private fun opusPacketFrames(packet: ByteBuffer, size: Int): Int {
        require(size > 0) { "Empty Opus packet." }
        val toc = packet.get(0).toInt() and 0xff
        val perFrame = when {
            toc and 0x80 != 0 -> 120 shl ((toc shr 3) and 3)
            toc and 0x60 == 0x60 -> if (toc and 0x08 != 0) 960 else 480
            (toc shr 3) and 3 == 3 -> 2880
            else -> 480 shl ((toc shr 3) and 3)
        }
        val count = when (toc and 3) {
            0 -> 1
            3 -> { require(size >= 2) { "Truncated Opus packet." }; packet.get(1).toInt() and 0x3f }
            else -> 2
        }
        require(count > 0 && count * perFrame <= 5760) { "Invalid Opus packet duration." }
        return count * perFrame
    }

    private fun usToFrames(us: Long, rate: Int) = (us.toDouble() * rate / 1_000_000).roundToLong()
    private fun MediaFormat.intOrZero(key: String) = if (containsKey(key)) getInteger(key) else 0
    private fun MediaFormat.longOrNull(key: String) = if (containsKey(key)) getLong(key) else null

    private data class Timeline(val trim: Long, val lead: Long, val duration: Long?)

    /** Bounded streaming buffer; output uses an absolute 16 kHz sample grid and no codec packet padding. */
    private class PcmCropWriter(file: File, private val rate: Int, startUs: Long, endUs: Long, private val timeline: Timeline) {
        private val target = RandomAccessFile(file, "rw")
        private val start = startUs * OUTPUT_RATE / 1_000_000
        private val end = endUs * OUTPUT_RATE / 1_000_000
        private var next = start
        private val radius = if (rate == OUTPUT_RATE) 0 else 32
        private val ring = DoubleArray(256)
        private val tags = LongArray(256) { Long.MIN_VALUE }
        private var last = Long.MIN_VALUE
        private var first = Long.MAX_VALUE
        private val bytes = ByteArray(8192)
        private var used = 0
        private var closed = false
        private val divisor = gcd(rate, OUTPUT_RATE)
        private val filters = Array(OUTPUT_RATE / divisor) { phase ->
            val fraction = phase.toDouble() * divisor / OUTPUT_RATE
            val cutoff = minOf(1.0, OUTPUT_RATE.toDouble() / rate) * 0.94
            val weights = DoubleArray(radius * 2 + 1) { tap ->
                val x = tap - radius - fraction
                val sinc = if (abs(x) < 1e-10) cutoff else sin(PI * cutoff * x) / (PI * x)
                sinc * (0.5 + 0.5 * cos(PI * x / (radius + 1)))
            }
            val sum = weights.sum()
            weights.map { it / sum }.toDoubleArray()
        }
        val complete get() = next == end

        init {
            target.setLength(0)
            target.write(ByteArray(44))
        }

        fun add(position: Long, value: Double) {
            if (complete) return
            if (last != Long.MIN_VALUE && position <= last) return
            require(last == Long.MIN_VALUE || position == last + 1) { "Discontinuous decoded audio timeline." }
            first = minOf(first, position)
            last = position
            val slot = Math.floorMod(position, ring.size.toLong()).toInt()
            ring[slot] = value
            tags[slot] = position
            render(false)
        }

        private fun sample(position: Long, eof: Boolean): Double {
            if (position < timeline.lead || (timeline.duration != null && position >= timeline.duration)) return 0.0
            if (eof && position > last) return 0.0
            val slot = Math.floorMod(position, ring.size.toLong()).toInt()
            require(tags[slot] == position) { "Missing decoded samples at crop boundary." }
            return ring[slot]
        }

        private fun render(eof: Boolean) {
            while (!complete) {
                val numerator = next * rate
                val center = numerator / OUTPUT_RATE
                if (!eof && center + radius > last) break
                val value = if (radius == 0) sample(center, eof) else {
                    val weights = filters[((numerator % OUTPUT_RATE) / divisor).toInt()]
                    var mixed = 0.0
                    for (tap in weights.indices) mixed += sample(center + tap - radius, eof) * weights[tap]
                    mixed
                }
                val pcm = value.roundToInt().coerceIn(-32768, 32767)
                bytes[used++] = pcm.toByte()
                bytes[used++] = (pcm shr 8).toByte()
                if (used == bytes.size) flush()
                next++
            }
        }

        fun finish() {
            // A one-millisecond metadata tolerance must never synthesize a missing tail.
            val lastRequired = ((end - 1) * rate / OUTPUT_RATE).coerceAtLeast(0)
            require(first != Long.MAX_VALUE && (complete || last >= lastRequired)) { "The crop range exceeds decoded audio." }
            render(true)
            flush()
            val dataBytes = (end - start) * 2
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt((36 + dataBytes).toInt())
            header.put("WAVEfmt ".toByteArray(Charsets.US_ASCII)).putInt(16).putShort(1).putShort(1)
            header.putInt(OUTPUT_RATE).putInt(OUTPUT_RATE * 2).putShort(2).putShort(16)
            header.put("data".toByteArray(Charsets.US_ASCII)).putInt(dataBytes.toInt())
            target.seek(0)
            target.write(header.array())
        }

        private fun flush() { target.write(bytes, 0, used); used = 0 }
        fun close() { if (!closed) { closed = true; target.close() } }
        private fun gcd(a: Int, b: Int): Int = if (b == 0) a else gcd(b, a % b)
    }

    /** Read common MP4 trim/empty edits in their own timescales, including API 26. */
    private object Mp4Timeline {
        private data class Atom(val kind: String, val data: Long, val end: Long)

        fun read(file: File, rate: Int): Timeline? = RandomAccessFile(file, "r").use { input ->
            val top = atoms(input, 0, input.length())
            val movie = top.firstOrNull { it.kind == "moov" } ?: return null
            val children = atoms(input, movie.data, movie.end)
            val movieHeader = children.firstOrNull { it.kind == "mvhd" } ?: error("MP4 has no movie clock.")
            val movieScale = clock(input, movieHeader).first
            for (track in children.filter { it.kind == "trak" }) {
                val parts = atoms(input, track.data, track.end)
                val media = parts.firstOrNull { it.kind == "mdia" } ?: continue
                val mediaParts = atoms(input, media.data, media.end)
                val handler = mediaParts.firstOrNull { it.kind == "hdlr" } ?: continue
                input.seek(handler.data + 8)
                if (input.readInt() != 0x736f756e) continue // soun
                val header = mediaParts.firstOrNull { it.kind == "mdhd" } ?: error("MP4 has no audio clock.")
                val (scale, _) = clock(input, header)
                val edits = parts.firstOrNull { it.kind == "edts" }?.let {
                    atoms(input, it.data, it.end).firstOrNull { atom -> atom.kind == "elst" }
                } ?: return null // Use extractor gapless tags when there is no edit list.
                input.seek(edits.data)
                val version = input.readUnsignedByte()
                input.skipBytes(3)
                val count = input.readInt()
                require(version in 0..1 && count in 1..2) { "Unsupported MP4 edit list; expected one audio edit with optional leading silence." }
                var lead = 0L
                var trim = 0L
                var length = 0L
                repeat(count) { i ->
                    val segment = if (version == 1) input.readLong() else input.readInt().toLong() and 0xffff_ffffL
                    val mediaTime = if (version == 1) input.readLong() else input.readInt().toLong()
                    require(input.readInt() == 0x00010000) { "Unsupported MP4 edit playback rate." }
                    require(segment >= 0 && segment <= Long.MAX_VALUE / rate) { "Invalid MP4 edit duration." }
                    val frames = (segment.toDouble() * rate / movieScale).roundToLong()
                    if (mediaTime == -1L && i == 0 && count == 2) lead = frames else {
                        require(mediaTime >= 0 && i == count - 1 && mediaTime <= Long.MAX_VALUE / rate) { "Unsupported MP4 edit sequence." }
                        trim = (mediaTime.toDouble() * rate / scale).roundToLong()
                        length = frames
                    }
                }
                return Timeline(trim, lead, lead + length)
            }
            error("MP4 has no audio timeline.")
        }

        private fun clock(input: RandomAccessFile, atom: Atom): Pair<Long, Long> {
            input.seek(atom.data)
            val version = input.readUnsignedByte()
            require(version in 0..1) { "Unsupported MP4 clock version." }
            input.seek(atom.data + if (version == 1) 20 else 12)
            val scale = input.readInt().toLong() and 0xffff_ffffL
            val duration = if (version == 1) input.readLong() else input.readInt().toLong() and 0xffff_ffffL
            require(scale > 0 && duration >= 0) { "Invalid MP4 audio clock." }
            return scale to duration
        }

        private fun atoms(input: RandomAccessFile, start: Long, end: Long): List<Atom> {
            val result = mutableListOf<Atom>()
            var position = start
            while (position + 8 <= end) {
                input.seek(position)
                var size = input.readInt().toLong() and 0xffff_ffffL
                val kindBytes = ByteArray(4).also { input.readFully(it) }
                val kind = String(kindBytes, Charsets.US_ASCII)
                var header = 8
                if (size == 1L) { size = input.readLong(); header = 16 }
                if (size == 0L) size = end - position
                require(size >= header && size <= end - position) { "Malformed MP4 atom $kind." }
                result.add(Atom(kind, position + header, position + size))
                position += size
            }
            return result
        }
    }
}
