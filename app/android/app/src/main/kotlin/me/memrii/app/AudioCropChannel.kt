package me.memrii.app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Engine-owned so crops and cloud sidecars also work without an Activity. */
class AudioCropChannel(messenger: BinaryMessenger) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "me.memrii.app/audioCrop").setMethodCallHandler { call, result ->
            if (call.method != "crop") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val source = call.argument<String>("sourcePath")
            val output = call.argument<String>("outputPath")
            val start = call.argument<Number>("startUs")?.toLong()
            val end = call.argument<Number>("endUs")?.toLong()
            if (source == null || output == null || start == null || end == null || start < 0 || end <= start) {
                result.error("INVALID_ARGS", "Choose a source, output and non-empty crop range.", null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    AudioCropDecoder.crop(source, output, start, end)
                    main.post { result.success(null) }
                } catch (e: Exception) {
                    main.post { result.error("AUDIO_CROP_ERROR", e.message ?: "Could not decode recording.", null) }
                }
            }
        }
    }
}
