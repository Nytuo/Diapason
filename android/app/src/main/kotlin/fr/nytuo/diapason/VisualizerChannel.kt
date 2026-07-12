package fr.nytuo.diapason

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Streams real FFT frames off the platform [Visualizer] effect, attached to the
 * ExoPlayer audio session that just_audio is currently playing through.
 */
class VisualizerChannel(messenger: BinaryMessenger) : EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL = "fr.nytuo.diapason/visualizer"
        private const val EVENT_CHANNEL = "fr.nytuo.diapason/visualizer_fft"
        private const val LOG_TAG = "VisualizerChannel"
    }

    private val handler = Handler(Looper.getMainLooper())

    private var visualizer: Visualizer? = null
    private var eventSink: EventChannel.EventSink? = null

    init {
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val sessionId = call.argument<Int>("sessionId")
                    val captureSize = call.argument<Int>("captureSize") ?: 1024
                    val fps = call.argument<Int>("fps") ?: 30
                    if (sessionId == null) {
                        result.error("INVALID_ARGS", "sessionId is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(start(sessionId, captureSize, fps))
                    } catch (e: Exception) {
                        Log.w(LOG_TAG, "Failed to start visualizer for session $sessionId", e)
                        stop()
                        result.error("VISUALIZER_ERROR", e.message, null)
                    }
                }
                "stop" -> {
                    stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(sessionId: Int, requestedCaptureSize: Int, requestedFps: Int): Map<String, Any> {
        stop()

        val range = Visualizer.getCaptureSizeRange()
        val captureSize = requestedCaptureSize.coerceIn(range[0], range[1])
        val rate = (requestedFps * 1000).coerceAtMost(Visualizer.getMaxCaptureRate())

        val created = Visualizer(sessionId).apply {
            enabled = false
            this.captureSize = captureSize
            setDataCaptureListener(
                object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(v: Visualizer?, waveform: ByteArray?, rate: Int) = Unit

                    override fun onFftDataCapture(v: Visualizer?, fft: ByteArray?, rate: Int) {
                        if (fft == null) return
                        handler.post { eventSink?.success(fft) }
                    }
                },
                rate,
                false,
                true,
            )
            enabled = true
        }
        visualizer = created

        Log.i(LOG_TAG, "Visualizer started: session=$sessionId captureSize=$captureSize rate=${rate}mHz")
        return mapOf(
            "captureSize" to captureSize,
            "samplingRate" to created.samplingRate,
            "captureRate" to rate,
        )
    }

    private fun stop() {
        visualizer?.let {
            try {
                it.enabled = false
                it.release()
            } catch (e: Exception) {
                Log.w(LOG_TAG, "Failed to release visualizer", e)
            }
        }
        visualizer = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stop()
    }
}
