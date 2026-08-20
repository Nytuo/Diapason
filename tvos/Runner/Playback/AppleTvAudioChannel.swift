import AVFoundation
import Flutter
import MediaPlayer

/// Native audio playback + Now Playing / Siri Remote integration for tvOS.
///
/// Diapason's other platforms drive playback through just_audio +
/// audio_service, neither of which has a tvOS build. Rather than porting
/// that stack, tvOS gets its own thin AVPlayer + MPNowPlayingInfoCenter
/// bridge, talked to from Dart over this MethodChannel. This is a
/// foundational stub: load/play/pause/seek/stop and Now Playing metadata
/// are wired up; queue/session logic stays on the Dart side and drives this
/// channel the way it drives just_audio today.
final class AppleTvAudioChannel: NSObject {
    static let channelName = "fr.nytuo.diapason/appletv_audio"

    private let channel: FlutterMethodChannel
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemEndObserver: NSObjectProtocol?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler(handle)
        configureAudioSession()
        configureRemoteCommandCenter()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            NSLog("AppleTvAudioChannel: failed to configure audio session: \(error)")
        }
    }

    // MARK: - Dart -> native

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "load":
            guard let urlString = args?["url"] as? String, let url = URL(string: urlString) else {
                result(FlutterError(code: "bad_args", message: "load requires a url", details: nil))
                return
            }
            load(url: url)
            result(nil)
        case "play":
            player?.play()
            result(nil)
        case "pause":
            player?.pause()
            result(nil)
        case "stop":
            teardownPlayer()
            result(nil)
        case "seek":
            guard let positionMs = args?["positionMs"] as? Int else {
                result(FlutterError(code: "bad_args", message: "seek requires positionMs", details: nil))
                return
            }
            let time = CMTime(value: CMTimeValue(positionMs), timescale: 1000)
            player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            result(nil)
        case "setVolume":
            guard let volume = args?["volume"] as? Double else {
                result(FlutterError(code: "bad_args", message: "setVolume requires volume", details: nil))
                return
            }
            player?.volume = Float(volume)
            result(nil)
        case "setNowPlayingInfo":
            setNowPlayingInfo(args ?? [:])
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func load(url: URL) {
        teardownPlayer()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                let durationMs = item.duration.isNumeric ? Int(item.duration.seconds * 1000) : 0
                self.channel.invokeMethod("onReady", arguments: ["durationMs": durationMs])
            case .failed:
                self.channel.invokeMethod(
                    "onError",
                    arguments: ["message": item.error?.localizedDescription ?? "unknown player error"]
                )
            default:
                break
            }
        }

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.channel.invokeMethod("onComplete", arguments: nil)
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.channel.invokeMethod("onPositionChanged", arguments: ["positionMs": Int(time.seconds * 1000)])
        }
    }

    private func teardownPlayer() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let observer = itemEndObserver {
            NotificationCenter.default.removeObserver(observer)
            itemEndObserver = nil
        }
        player?.pause()
        player = nil
    }

    // MARK: - Now Playing / Siri Remote

    private func configureRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onRemoteCommand", arguments: ["command": "play"])
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onRemoteCommand", arguments: ["command": "pause"])
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onRemoteCommand", arguments: ["command": "next"])
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onRemoteCommand", arguments: ["command": "previous"])
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.channel.invokeMethod(
                "onRemoteCommand",
                arguments: ["command": "seek", "positionMs": Int(event.positionTime * 1000)]
            )
            return .success
        }
    }

    private func setNowPlayingInfo(_ args: [String: Any]) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = args["title"] as? String
        info[MPMediaItemPropertyArtist] = args["artist"] as? String
        info[MPMediaItemPropertyAlbumTitle] = args["album"] as? String
        if let durationMs = args["durationMs"] as? Int {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000
        }
        if let positionMs = args["positionMs"] as? Int {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(positionMs) / 1000
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = player?.rate ?? 0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let artworkUrlString = args["artworkUrl"] as? String, let artworkUrl = URL(string: artworkUrlString) {
            loadArtwork(from: artworkUrl)
        }
    }

    private func loadArtwork(from url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }.resume()
    }
}
