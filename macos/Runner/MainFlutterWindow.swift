import AVFoundation
import Cocoa
import CoreAudio
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    AudioDecodeChannel.register(messenger: flutterViewController.engine.binaryMessenger)
    HifiChannel.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
    positionTrafficLights()
  }

  // MARK: Traffic lights

  /// Where the close / minimise / zoom buttons sit: inset from the corner of the sidebar panel, level with the
  /// panel's own top padding, instead of crowding the window edge. Re-applied whenever AppKit lays the title bar out
  /// again (resizing, leaving fullscreen), since it resets their frames.
  private func positionTrafficLights() {
    if styleMask.contains(.fullScreen) { return }
    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let buttons = types.compactMap { standardWindowButton($0) }
    guard buttons.count == 3, let bar = buttons[0].superview else { return }
    let originX: CGFloat = 20
    let spacing: CGFloat = 20
    let centreFromTop: CGFloat = 26
    for (i, button) in buttons.enumerated() {
      let y = bar.frame.height - centreFromTop - button.frame.height / 2
      let x = originX + CGFloat(i) * spacing
      if button.frame.origin.x != x || button.frame.origin.y != y {
        button.setFrameOrigin(NSPoint(x: x, y: y))
      }
    }
  }

  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    positionTrafficLights()
  }

  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    super.setFrame(frameRect, display: flag)
    positionTrafficLights()
  }
}

// MARK: - Automix audio analysis decoding

/// Decodes a window of a local track to mono float PCM at a low sample rate, for Automix's beat analysis
/// (see lib/services/automix/audio_analysis_decoder.dart). The same code lives in the iOS and macOS runners;
/// keep them in sync.
final class AudioDecodeChannel {
    private static let queue = DispatchQueue(label: "fr.nytuo.diapason.audio_decode", qos: .utility)

    static func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "fr.nytuo.diapason/audio_decode", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "decode",
                  let args = call.arguments as? [String: Any],
                  let source = args["source"] as? String else {
                result(FlutterMethodNotImplemented)
                return
            }
            let startMs = (args["startMs"] as? NSNumber)?.doubleValue ?? 0
            let durationMs = (args["durationMs"] as? NSNumber)?.doubleValue ?? 30000
            let sampleRate = (args["sampleRate"] as? NSNumber)?.doubleValue ?? 11025
            queue.async {
                do {
                    let samples = try decode(source: source, startMs: startMs, durationMs: durationMs, outRate: sampleRate)
                    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
                    DispatchQueue.main.async { result(FlutterStandardTypedData(float32: data)) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "DECODE_FAILED", message: "\(error)", details: nil))
                    }
                }
            }
        }
    }

    private static func decode(source: String, startMs: Double, durationMs: Double, outRate: Double) throws -> [Float] {
        let url = source.hasPrefix("file://") ? URL(string: source)! : URL(fileURLWithPath: source)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat // deinterleaved float32
        let inRate = format.sampleRate
        let channels = Int(format.channelCount)

        let startFrame = AVAudioFramePosition(startMs / 1000 * inRate)
        if startFrame >= file.length { return [] }
        file.framePosition = max(0, startFrame)
        var remaining = AVAudioFrameCount(min(Double(file.length - file.framePosition), durationMs / 1000 * inRate))

        let chunk: AVAudioFrameCount = 32768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }
        var out = [Float]()
        out.reserveCapacity(Int(durationMs / 1000 * outRate) + 1)

        // Box-filter decimation: average every input frame into its output slot.
        let step = outRate / inRate
        var acc: Float = 0
        var count = 0
        var position = 0.0
        while remaining > 0 {
            try file.read(into: buffer, frameCount: min(chunk, remaining))
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][frame] }
                acc += sum / Float(channels)
                count += 1
                position += step
                if position >= 1 {
                    out.append(acc / Float(count))
                    acc = 0
                    count = 0
                    position -= 1
                }
            }
            remaining -= AVAudioFrameCount(frames)
        }
        return out
    }
}

// MARK: - Bit-perfect output (CoreAudio)

/// Matches the default output device's nominal rate to the track's (so AVPlayer's converter runs 1:1), optionally
/// takes the device in hog mode (exclusive to this process), and reports the device state for the signal path panel
/// (see lib/services/hifi/native_output.dart and docs/HIFI_AUDIO.md).
final class HifiChannel {
    private static var originalRate: (AudioDeviceID, Float64)?
    private static var hogged: AudioDeviceID?

    static func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "fr.nytuo.diapason/hifi", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            let args = call.arguments as? [String: Any] ?? [:]
            switch call.method {
            case "outputDevice":
                result(describe())
            case "prepare":
                let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 0
                let exclusive = (args["exclusive"] as? Bool) ?? false
                result(prepare(rate: rate, exclusive: exclusive))
            case "clear":
                clear()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func name(_ device: AudioDeviceID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func nominalRate(_ device: AudioDeviceID) -> Float64? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    private static func availableRates(_ device: AudioDeviceID) -> [AudioValueRange] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges
    }

    private static func hogPid(_ device: AudioDeviceID) -> pid_t {
        var pid = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var addr = address(kAudioDevicePropertyHogMode)
        _ = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &pid)
        return pid
    }

    private static func setHog(_ device: AudioDeviceID, _ value: pid_t) -> Bool {
        var pid = value
        var addr = address(kAudioDevicePropertyHogMode)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<pid_t>.size), &pid) == noErr
    }

    /// Bits per channel of the device's first output stream's physical format (what reaches the DAC).
    private static func physicalBits(_ device: AudioDeviceID) -> UInt32? {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr, let stream = streams.first else {
            return nil
        }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = address(kAudioStreamPropertyPhysicalFormat)
        guard AudioObjectGetPropertyData(stream, &formatAddr, 0, nil, &formatSize, &format) == noErr else { return nil }
        return format.mBitsPerChannel
    }

    private static func describe() -> [String: Any]? {
        guard let device = defaultOutput() else { return nil }
        let pid = hogPid(device)
        var out: [String: Any] = [
            "name": name(device) ?? "",
            "hog": pid == getpid(),
            "hoggedByOther": pid != -1 && pid != getpid(),
            "rates": availableRates(device).flatMap { $0.mMinimum == $0.mMaximum ? [$0.mMinimum] : [$0.mMinimum, $0.mMaximum] },
        ]
        if let rate = nominalRate(device) { out["rate"] = rate }
        if let bits = physicalBits(device) { out["bits"] = bits }
        return out
    }

    private static func prepare(rate: Double, exclusive: Bool) -> [String: Any]? {
        guard let device = defaultOutput() else { return nil }
        if originalRate == nil || originalRate?.0 != device, let current = nominalRate(device) {
            originalRate = (device, current)
        }
        if rate > 0, nominalRate(device) != rate,
           availableRates(device).contains(where: { rate >= $0.mMinimum && rate <= $0.mMaximum }) {
            var value = Float64(rate)
            var addr = address(kAudioDevicePropertyNominalSampleRate)
            _ = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        }
        if exclusive, hogPid(device) == -1, setHog(device, getpid()) {
            hogged = device
        } else if !exclusive, let h = hogged {
            _ = setHog(h, -1)
            hogged = nil
        }
        return describe()
    }

    private static func clear() {
        if let h = hogged {
            _ = setHog(h, -1)
            hogged = nil
        }
        if let (device, rate) = originalRate {
            var value = rate
            var addr = address(kAudioDevicePropertyNominalSampleRate)
            _ = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
            originalRate = nil
        }
    }
}
