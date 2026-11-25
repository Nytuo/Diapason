package fr.nytuo.diapason

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Bit-perfect output on USB DACs (Android 14+): asks the framework for a mixer with
 * [AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT] at the track's rate and encoding, for USAGE_MEDIA on that
 * device. The framework then sends the player's PCM to the DAC untouched, as long as the player's own format
 * matches (see lib/services/hifi/native_output.dart and docs/HIFI_AUDIO.md).
 */
class HifiChannel(context: Context, messenger: BinaryMessenger) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mediaAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()
    private var preferredOn: AudioDeviceInfo? = null

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "outputDevice" -> result.success(outputDevice())
                    "setBitPerfect" -> {
                        val rate = (call.argument<Number>("rate") ?: 0).toInt()
                        val encoding = call.argument<String>("encoding") ?: "pcm16"
                        result.success(setBitPerfect(rate, encoding))
                    }
                    "clear" -> {
                        clear()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(TAG, "${call.method} failed", e)
                result.error("HIFI_FAILED", e.message, null)
            }
        }
    }

    private fun usbOutput(): AudioDeviceInfo? =
        audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }

    private fun encodingName(encoding: Int): String = when (encoding) {
        AudioFormat.ENCODING_PCM_16BIT -> "pcm16"
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> "pcm24"
        AudioFormat.ENCODING_PCM_32BIT -> "pcm32"
        AudioFormat.ENCODING_PCM_FLOAT -> "float"
        AudioFormat.ENCODING_PCM_8BIT -> "pcm8"
        else -> "encoding$encoding"
    }

    private fun encodingOf(name: String): Int = when (name) {
        "pcm24" -> AudioFormat.ENCODING_PCM_24BIT_PACKED
        "pcm32" -> AudioFormat.ENCODING_PCM_32BIT
        "float" -> AudioFormat.ENCODING_PCM_FLOAT
        else -> AudioFormat.ENCODING_PCM_16BIT
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun describe(attributes: AudioMixerAttributes): Map<String, Any> {
        val format = attributes.format
        return mapOf(
            "rate" to format.sampleRate,
            "encoding" to encodingName(format.encoding),
            "channels" to format.channelCount,
            "bitPerfect" to (attributes.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT),
        )
    }

    /** The USB output, what bit-perfect mixers it offers, and the one in use; `sdk` lets Dart explain an old OS. */
    private fun outputDevice(): Map<String, Any?> {
        val usb = usbOutput()
        val base = mutableMapOf<String, Any?>("sdk" to Build.VERSION.SDK_INT, "usb" to (usb != null))
        if (usb == null) {
            val current = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull()
            base["name"] = current?.productName?.toString()
            return base
        }
        base["name"] = usb.productName?.toString()
        base["rates"] = usb.sampleRates.toList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            base["mixers"] = audioManager.getSupportedMixerAttributes(usb).map { describe(it) }
            base["preferred"] = audioManager.getPreferredMixerAttributes(mediaAttributes, usb)?.let { describe(it) }
        }
        return base
    }

    /**
     * Picks the bit-perfect mixer at [rate] and [encoding] and makes it the preferred one for media on the USB
     * device. Returns the mixer that was set, or null when there is no USB device, the OS is older than 14,
     * or the DAC offers no bit-perfect mixer in that format.
     */
    private fun setBitPerfect(rate: Int, encoding: String): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
        val usb = usbOutput() ?: return null
        val wanted = encodingOf(encoding)
        val choice = audioManager.getSupportedMixerAttributes(usb).firstOrNull {
            it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT &&
                it.format.sampleRate == rate &&
                it.format.encoding == wanted
        } ?: return null
        if (!audioManager.setPreferredMixerAttributes(mediaAttributes, usb, choice)) return null
        preferredOn = usb
        return describe(choice)
    }

    private fun clear() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        val device = preferredOn ?: usbOutput() ?: return
        audioManager.clearPreferredMixerAttributes(mediaAttributes, device)
        preferredOn = null
    }

    companion object {
        private const val TAG = "HifiChannel"
        const val CHANNEL = "fr.nytuo.diapason/hifi"
    }
}
