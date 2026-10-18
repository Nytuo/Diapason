import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    AudioDecodeChannel.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
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
