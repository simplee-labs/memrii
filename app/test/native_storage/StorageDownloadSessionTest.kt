import java.io.File
import java.nio.file.Files

// The runner supplies OmiBleManager with the unmodified production inner class.
// Only Android scheduling/logging and connection-priority side effects are stubbed.
private val original = ByteArray(12) { (it + 1).toByte() }

private fun data(offset: Int, bytes: ByteArray): ByteArray = byteArrayOf(
    1, offset.toByte(), (offset shr 8).toByte(), (offset shr 16).toByte(), (offset shr 24).toByte()
) + bytes

// A whole-bin download by default; with [overlap], a sealed-chunk part whose first byte is
// the logical byte [start] and whose resend covers the bytes just before it.
private class Download(val file: File, start: Long = 0, overlap: ByteArray? = null, ts: Long = 123) {
    val manager = OmiBleManager()
    val results = mutableListOf<Result<Unit>>()
    val session = manager.StorageDownloadSession(
        "device", start, file.path, ts, chunkOverlap = overlap, callback = results::add
    )

    init {
        manager.activeDownloads["device"] = session
        session.readIssued = true
    }

    fun ack() = session.onPacket(byteArrayOf(3, 0, 123, 0, 0, 0))
    fun chunk(offset: Int, end: Int) = session.onPacket(data(offset, original.copyOfRange(offset, end)))
    fun eot() = session.onPacket(byteArrayOf(2))
    fun disconnect() = session.complete(Result.failure(Exception("Stream closed without EOT")))

    fun expectGap(expected: Long, incoming: Long) {
        val error = results.single().exceptionOrNull()!!
        check(PigeonCommunicatorPigeonUtils.wrapError(error) == listOf(
            "storage-integrity", "Non-contiguous storage DATA: incoming=$incoming expected=$expected",
            mapOf("expectedOffset" to expected, "incomingOffset" to incoming)
        ))
    }

    fun failReadBack() {
        val field = session.javaClass.getDeclaredField("readPart")
        field.isAccessible = true
        field.set(session, { _: Long, _: Long -> throw java.io.IOException("injected read failure") })
    }

    fun replaceWriter(writer: java.io.FileOutputStream) {
        val field = session.javaClass.getDeclaredField("fos")
        field.isAccessible = true
        (field.get(session) as java.io.FileOutputStream).close()
        field.set(session, writer)
    }

    fun expect(bytes: ByteArray, success: Boolean) {
        check(results.size == 1) { "Expected one completion, got ${results.size}" }
        check(results.single().isSuccess == success) { "Unexpected completion: ${results.single()}" }
        check(file.readBytes().contentEquals(bytes)) {
            "Expected ${bytes.toList()}, got ${file.readBytes().toList()}"
        }
    }
}

// Lets an injected writer write only part of what it was given, then fail.
class FileOutputStreamHook(private val stream: java.io.FileOutputStream, private val bytes: ByteArray) {
    fun partial(count: Int) {
        stream.write(bytes, 0, count)
        throw java.io.IOException("injected partial write")
    }
}

fun main() {
    val dir = Files.createTempDirectory("storage-session-test").toFile()
    var passed = 0
    fun test(name: String, body: (File) -> Unit) {
        val file = File(dir, "${passed}.bin")
        body(file)
        passed++
        println("PASS $name")
    }
    try {
        test("contiguous packets produce the original file") { file ->
            Download(file).apply { ack(); chunk(0, 4); chunk(4, 8); chunk(8, 12); eot(); expect(original, true) }
        }
        test("duplicate packets are ignored without duplicating bytes") { file ->
            Download(file).apply { ack(); chunk(0, 4); chunk(0, 4); chunk(4, 12); eot(); expect(original, true) }
        }
        test("overlapping packet appends only its new suffix") { file ->
            Download(file).apply { ack(); chunk(0, 8); chunk(4, 12); eot(); expect(original, true) }
        }
        test("forward offset fails with a typed Pigeon error and preserves the exact prefix") { file ->
            Download(file).apply {
                ack(); chunk(0, 4); chunk(8, 12)
                expect(original.copyOfRange(0, 4), false); expectGap(4, 8)
                eot(); expect(original.copyOfRange(0, 4), false)
            }
        }
        test("late packets and EOT cannot mutate or succeed a failed session") { file ->
            Download(file).apply {
                ack(); chunk(0, 4); chunk(8, 12); chunk(4, 12); ack(); eot()
                expect(original.copyOfRange(0, 4), false)
            }
        }
        test("a leading gap fails without writing any bytes") { file ->
            Download(file).apply {
                ack(); chunk(4, 12); eot()
                expect(byteArrayOf(), false); expectGap(0, 4)
            }
        }
        test("a permanently lost final packet gives success but a short file") { file ->
            Download(file).apply { ack(); chunk(0, 8); eot(); expect(original.copyOfRange(0, 8), true) }
        }
        test("EOT before the start ACK is ignored") { file ->
            Download(file).apply {
                eot(); check(results.isEmpty())
                ack(); chunk(0, 12); eot(); expect(original, true)
            }
        }
        test("disconnect and resume from a contiguous prefix is byte-correct") { file ->
            Download(file).apply { ack(); chunk(0, 4); disconnect(); expect(original.copyOfRange(0, 4), false) }
            Download(file, file.length()).apply { ack(); chunk(4, 12); eot(); expect(original, true) }
        }
        test("resume after a gap fetches the missing range and is byte-correct") { file ->
            Download(file).apply {
                ack(); chunk(0, 4); chunk(8, 10); disconnect()
                expect(original.copyOfRange(0, 4), false)
            }
            Download(file, file.length()).apply { ack(); chunk(4, 12); eot(); expect(original, true) }
        }
        test("repeated gaps keep the prefix intact") { file ->
            Download(file).apply { ack(); chunk(0, 4); chunk(8, 10); expectGap(4, 8) }
            repeat(7) {
                Download(file, 4).apply { ack(); chunk(8, 12); eot(); expect(original.copyOfRange(0, 4), false) }
            }
            Download(file, 4).apply { ack(); chunk(4, 12); eot(); expect(original, true) }
        }
        test("a conservative earlier bookmark also resumes correctly") { file ->
            Download(file).apply { ack(); chunk(0, 4); chunk(8, 10); disconnect() }
            java.io.RandomAccessFile(file, "rw").use { it.setLength(2) }
            Download(file, 2).apply { ack(); chunk(2, 12); eot(); expect(original, true) }
        }
        test("maximum unsigned wire offset fails without allocating padding") { file ->
            Download(file).apply {
                ack(); session.onPacket(data(-1, byteArrayOf(42))); eot()
                expect(byteArrayOf(), false); expectGap(0, 0xFFFFFFFFL)
            }
        }
        test("legitimate zero content and old firmware ACK remain supported") { file ->
            Download(file).apply {
                session.onPacket(byteArrayOf(3, 0))
                session.onPacket(data(0, ByteArray(12))); eot(); expect(ByteArray(12), true)
            }
        }
        test("stale ACK DATA and EOT before READ or a matching ACK are ignored") { file ->
            Download(file).apply {
                session.readIssued = false
                ack(); chunk(0, 12); eot(); check(results.isEmpty())
                session.readIssued = true
                session.onPacket(byteArrayOf(3, 0, 124, 0, 0, 0))
                chunk(0, 12); eot(); check(results.isEmpty())
                ack(); chunk(0, 12); eot(); expect(original, true)
            }
        }
        test("an ACK naming another command can neither start nor fail this read") { file ->
            Download(file).apply {
                session.onPacket(byteArrayOf(3, 0, 0x12)) // a late delete's OK (oo-3.1.5 form)
                chunk(0, 12); eot(); check(results.isEmpty())
                session.onPacket(byteArrayOf(3, 7, 0x03)) // another command's failure
                check(results.isEmpty())
                session.onPacket(byteArrayOf(3, 0, 0x11)) // this read's own, three-byte form
                chunk(0, 12); eot(); expect(original, true)
            }
        }
        test("an old session completion cannot remove its replacement") { file ->
            val old = Download(file)
            val next = old.manager.StorageDownloadSession("device", 0, File(file.parent, "next.bin").path, 123) {}
            old.manager.activeDownloads["device"] = next
            old.disconnect()
            check(old.manager.activeDownloads["device"] === next)
            next.complete(Result.success(Unit))
        }
        test("partial write failure rolls back and does not advance the accepted offset") { file ->
            Download(file).apply {
                ack(); chunk(0, 4)
                replaceWriter(object : java.io.FileOutputStream(file, true) {
                    override fun write(bytes: ByteArray) {
                        super.write(bytes, 0, 2)
                        throw java.io.IOException("injected partial write")
                    }
                })
                chunk(4, 12); eot(); expect(original.copyOfRange(0, 4), false)
                val error = results.single().exceptionOrNull() as FlutterError
                check(error.code == "storage-integrity")
                check(error.details == mapOf("expectedOffset" to 4L))
            }
            Download(file, 4).apply { ack(); chunk(4, 12); eot(); expect(original, true) }
        }
        test("close failure is an integrity failure requiring a fresh read") { file ->
            Download(file).apply {
                replaceWriter(object : java.io.FileOutputStream(file, true) {
                    override fun close() { super.close(); throw java.io.IOException("injected close failure") }
                })
                ack(); chunk(0, 12); eot(); expect(original, false)
                val error = results.single().exceptionOrNull() as FlutterError
                check(error.code == "storage-integrity")
                check(error.details == mapOf("expectedOffset" to 0L))
            }
        }
        test("completion waits for an in-flight packet write") { file ->
            Download(file).apply {
                val entered = java.util.concurrent.CountDownLatch(1)
                val release = java.util.concurrent.CountDownLatch(1)
                replaceWriter(object : java.io.FileOutputStream(file, true) {
                    override fun write(bytes: ByteArray) {
                        entered.countDown()
                        check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
                        super.write(bytes)
                    }
                })
                ack()
                val writer = Thread { chunk(0, 4) }.apply { start() }
                check(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
                val closer = Thread { disconnect() }.apply { start() }
                try {
                    closer.join(100)
                    check(closer.isAlive) { "Completion raced the write" }
                } finally { release.countDown() }
                writer.join(); closer.join()
                chunk(4, 12); eot(); expect(original.copyOfRange(0, 4), false)
            }
        }
        // Sealed-chunk parts (RECORDINGS_PIPELINE_REDESIGN.md §1): offsets on the wire and
        // in errors stay logical; the part holds the bytes from its own start.
        fun part(file: File, append: Long, overlap: ByteArray = ByteArray(0)) =
            Download(file, start = append, overlap = overlap)
        fun failing(file: File, write: (FileOutputStreamHook) -> Unit = {}, channel: Boolean = true,
                    close: Boolean = true) = object : java.io.FileOutputStream(file, true) {
            override fun write(bytes: ByteArray) = write(FileOutputStreamHook(this, bytes))
            override fun getChannel(): java.nio.channels.FileChannel =
                if (channel) super.getChannel() else throw java.io.IOException("injected channel failure")
            override fun close() { super.close(); if (!close) throw java.io.IOException("injected close failure") }
        }
        test("a part asks the Omi to start at its overlap and holds only the bytes after it") { file ->
            part(file, 8, original.copyOfRange(4, 8)).apply {
                // CMD_READ_FILE: [0x11, index, offset 4B LE, timestamp 4B LE]; 123 is the test file's.
                check(session.readCommand(3).contentEquals(byteArrayOf(0x11, 3, 4, 0, 0, 0, 123, 0, 0, 0)))
                ack(); chunk(4, 12); eot(); expect(original.copyOfRange(8, 12), true)
                check(session.acceptedEnd() == 12L)
            }
            check(Download(File(file.parent, "whole.bin"), 5).session.readCommand(0)
                .contentEquals(byteArrayOf(0x11, 0, 5, 0, 0, 0, 123, 0, 0, 0)))
            // Every byte of a multi-byte offset and timestamp, little-endian.
            val wide = Download(File(file.parent, "wide.part"), start = 0x01020304, overlap = ByteArray(4), ts = 0x0A0B0C0D)
            check(wide.session.readCommand(9).contentEquals(byteArrayOf(0x11, 9, 0x00, 0x03, 0x02, 0x01, 0x0D, 0x0C, 0x0B, 0x0A)))
        }
        test("a resent byte that differs fails with storage-mismatch and writes nothing") { file ->
            val changed = original.copyOfRange(4, 8).also { it[2] = 99 }
            part(file, 8, changed).apply {
                ack(); chunk(4, 12); eot(); expect(byteArrayOf(), false)
                val error = results.single().exceptionOrNull() as FlutterError
                check(error.code == "storage-mismatch")
                check(error.details == mapOf("offset" to 6L))
                check(session.chunkFailure(error).details == mapOf("offset" to 6L, "acceptedEnd" to 8L, "echoedAck" to true))
            }
        }
        test("nothing is appended until the whole overlap has arrived and matched") { file ->
            // The packet resending [4, 8) is lost: [8, 12) cannot be accepted without it.
            part(file, 8, original.copyOfRange(4, 8)).apply {
                ack(); chunk(8, 12); eot(); expect(byteArrayOf(), false)
                val error = session.chunkFailure(results.single().exceptionOrNull()!!)
                check(error.code == "storage-integrity")
                check((error.details as Map<*, *>)["acceptedEnd"] == 8L)
            }
        }
        test("a file that ends on the Omi before the sealed end is a short source, not a success") { file ->
            part(file, 8, original.copyOfRange(4, 8)).apply {
                ack(); chunk(4, 6); eot(); expect(byteArrayOf(), false)
                val error = results.single().exceptionOrNull() as FlutterError
                check(error.code == "storage-short-source")
                check(error.details == mapOf("receivedEnd" to 6L))
            }
        }
        test("a resend inside the part is compared with what the part already holds") { file ->
            part(file, 4).apply {
                ack(); chunk(4, 8)
                session.onPacket(data(6, byteArrayOf(7, 42)))
                expect(original.copyOfRange(4, 8), false)
                check((results.single().exceptionOrNull() as FlutterError).details == mapOf("offset" to 7L))
            }
            part(File(file.parent, "same.part"), 4).apply {
                ack(); chunk(4, 8); chunk(6, 12); eot(); expect(original.copyOfRange(4, 12), true)
            }
        }
        test("a part that cannot be read back for a comparison ends the transfer, keeping what it holds") { file ->
            part(file, 4).apply {
                ack(); chunk(4, 8)
                failReadBack()
                chunk(4, 8)
                expect(original.copyOfRange(4, 8), false)
                val error = session.chunkFailure(results.single().exceptionOrNull()!!)
                check(error.code == "storage-compare")
                check((error.details as Map<*, *>)["acceptedEnd"] == 8L)
                check((error.details as Map<*, *>)["echoedAck"] == true)
            }
        }
        test("a partial write in a part rolls back to the part's own accepted length") { file ->
            part(file, 4).apply {
                ack(); chunk(4, 8)
                replaceWriter(failing(file, write = { it.partial(2) }))
                chunk(8, 12); eot(); expect(original.copyOfRange(4, 8), false)
                val error = session.chunkFailure(results.single().exceptionOrNull()!!)
                check(error.code == "storage-integrity")
                check((error.details as Map<*, *>)["acceptedEnd"] == 8L)
            }
        }
        test("a failed rollback keeps the bytes accepted before it") { file ->
            part(file, 4).apply {
                ack(); chunk(4, 8)
                replaceWriter(failing(file, write = { it.partial(2) }, channel = false))
                chunk(8, 12)
                val error = session.chunkFailure(results.single().exceptionOrNull()!!)
                check((error.details as Map<*, *>)["acceptedEnd"] == 8L) { "${error.details}" }
                // The partial write is still on disk; the caller cuts the part back to 8.
                check(file.readBytes().copyOfRange(0, 4).contentEquals(original.copyOfRange(4, 8)))
            }
        }
        test("a failed close keeps the bytes accepted before it") { file ->
            part(file, 4).apply {
                ack(); chunk(4, 8)
                replaceWriter(failing(file, close = false))
                eot(); expect(original.copyOfRange(4, 8), false)
                val error = session.chunkFailure(results.single().exceptionOrNull()!!)
                check(error.code == "storage-integrity")
                check((error.details as Map<*, *>)["acceptedEnd"] == 8L)
            }
        }
        test("the first start ACK decides the echo; a later ACK cannot change it") { file ->
            part(file, 0).apply { ack(); check(session.echoedAck); session.onPacket(byteArrayOf(3, 0)); check(session.echoedAck) }
            part(File(file.parent, "old-ack.part"), 0).apply {
                session.onPacket(byteArrayOf(3, 0)); chunk(0, 4); ack(); check(!session.echoedAck)
            }
        }
        test("any other failure keeps its message and reports the accepted end") { file ->
            part(file, 4).apply {
                ack(); chunk(4, 8)
                session.complete(Result.failure(Exception("Transfer stalled: 15s inactivity timeout")))
                val error = session.chunkFailure(results.single().exceptionOrNull()!!)
                check(error.code == "storage-transfer")
                check(error.message == "Transfer stalled: 15s inactivity timeout")
                check(error.details == mapOf("acceptedEnd" to 8L, "echoedAck" to true))
            }
        }
        println("$passed native session regression tests passed")
    } finally {
        dir.deleteRecursively()
    }
}
