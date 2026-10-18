package fr.nytuo.diapason

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * Decodes a window of a track to mono float PCM at a low sample rate, for Automix's beat analysis
 * (see lib/services/automix/audio_analysis_decoder.dart). Files and http(s) URLs (with headers) both work.
 */
class AudioDecodeChannel(messenger: BinaryMessenger) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "decode") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val source = call.argument<String>("source")
            if (source == null) {
                result.error("INVALID_ARGS", "source is required", null)
                return@setMethodCallHandler
            }
            @Suppress("UNCHECKED_CAST")
            val headers = (call.argument<Map<String, String>>("headers") ?: emptyMap())
            val startMs = (call.argument<Number>("startMs") ?: 0).toLong()
            val durationMs = (call.argument<Number>("durationMs") ?: 30000).toLong()
            val sampleRate = (call.argument<Number>("sampleRate") ?: 11025).toInt()

            executor.execute {
                try {
                    val samples = decode(source, headers, startMs, durationMs, sampleRate)
                    main.post { result.success(samples) }
                } catch (e: Exception) {
                    Log.w(TAG, "Could not decode $source: ${e.message}")
                    main.post { result.error("DECODE_FAILED", e.message, null) }
                }
            }
        }
    }

    private fun decode(source: String, headers: Map<String, String>, startMs: Long, durationMs: Long, outRate: Int): FloatArray {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            if (source.startsWith("http://") || source.startsWith("https://")) {
                extractor.setDataSource(source, headers)
            } else {
                extractor.setDataSource(source.removePrefix("file://"))
            }

            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            if (trackIndex < 0 || format == null) throw IllegalStateException("no audio track")
            extractor.selectTrack(trackIndex)
            val startUs = startMs * 1000
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()

            var inRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var floatPcm = false

            val endUs = startUs + durationMs * 1000
            val out = FloatArrayBuilder((durationMs * outRate / 1000).toInt() + outRate)
            // Box-filter decimation: average every input frame into its output slot.
            var acc = 0.0
            var accCount = 0
            var outPos = 0.0
            var step = outRate.toDouble() / inRate

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0 || extractor.sampleTime > endUs) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        inRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        floatPcm = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                            f.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
                        step = outRate.toDouble() / inRate
                    }
                    outIndex >= 0 -> {
                        val buffer = codec.getOutputBuffer(outIndex)!!.order(ByteOrder.nativeOrder())
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val bytesPerSample = if (floatPcm) 4 else 2
                        val frames = info.size / (bytesPerSample * channels)
                        // Frames before the window (the seek lands on a sync point before it) are dropped.
                        var frameTimeUs = info.presentationTimeUs
                        val frameUs = 1_000_000.0 / inRate
                        for (frame in 0 until frames) {
                            var sum = 0f
                            for (c in 0 until channels) {
                                sum += if (floatPcm) buffer.float else buffer.short / 32768f
                            }
                            val t = frameTimeUs + (frame * frameUs).toLong()
                            if (t < startUs) continue
                            if (t >= endUs) {
                                outputDone = true
                                break
                            }
                            acc += sum / channels
                            accCount++
                            outPos += step
                            if (outPos >= 1.0) {
                                out.add((acc / accCount).toFloat())
                                acc = 0.0
                                accCount = 0
                                outPos -= 1.0
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }
            return out.toArray()
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }

    private class FloatArrayBuilder(capacity: Int) {
        private var data = FloatArray(maxOf(capacity, 1024))
        private var size = 0
        fun add(v: Float) {
            if (size == data.size) data = data.copyOf(data.size * 2)
            data[size++] = v
        }
        fun toArray(): FloatArray = data.copyOf(size)
    }

    companion object {
        private const val CHANNEL = "fr.nytuo.diapason/audio_decode"
        private const val TAG = "AudioDecode"
    }
}
