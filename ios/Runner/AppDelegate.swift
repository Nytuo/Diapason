import app_links
import UIKit
import Flutter
import MediaPlayer
import Intents
import AVFoundation

// Shared engine for CarPlay - the flutter_carplay plugin requires this
let flutterEngine = FlutterEngine(name: "SharedEngine", project: nil, allowHeadlessExecution: true)

@main
@objc class AppDelegate: FlutterAppDelegate, INPlayMediaIntentHandling {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Start the shared engine and register plugins with it for CarPlay
        flutterEngine.run()
        GeneratedPluginRegistrant.register(with: flutterEngine)

        // Set up method channel for playback state sync to MPNowPlayingInfoCenter
        // TODO: This is a workaround because audio_service doesn't set playbackState on iOS.
        // Consider contributing a fix to audio_service to set MPNowPlayingInfoCenter.playbackState on iOS.
        setupPlaybackStateChannel()

        // Set up method channel for Siri media intent handling
        setupSiriIntentChannel()

        // Set up widget playback controls (Darwin notification -> Flutter)
        setupWidgetControlChannel()

        // Decodes tracks for Automix's beat analysis
        AudioDecodeChannel.register(messenger: flutterEngine.binaryMessenger)

        // Exclude the documents and support folders from iCloud backup since we keep songs there.
        if let documentsDir = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? setExcludeFromiCloudBackup(documentsDir, isExcluded: true)
        }
        
        if let appSupportDir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? setExcludeFromiCloudBackup(appSupportDir, isExcluded: true)
        }
        
        // Retrieve the link from parameters
        if let url = AppLinks.shared.getLink(launchOptions: launchOptions) {
            // We have a link, propagate it to your Flutter app or not
            AppLinks.shared.handleLink(url: url)
            return true  // Returning true will stop the propagation to other packages
        }
            
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // Tell iOS to dispatch media intents to this AppDelegate (in-app intent handling, iOS 14+)
    override func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent {
            return self
        }
        return nil
    }

    // Required for scene-based lifecycle to properly configure CarPlay scene
    @available(iOS 13.0, *)
    override func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Check if this is a CarPlay scene (CPTemplateApplicationSceneSessionRoleApplication)
        if connectingSceneSession.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication" {
            let sceneConfig = UISceneConfiguration(
                name: "CarPlay Configuration",
                sessionRole: connectingSceneSession.role
            )
            // Use the flutter_carplay plugin's delegate directly (now that it's @objc accessible)
            sceneConfig.delegateClass = NSClassFromString("flutter_carplay.FlutterCarPlaySceneDelegate")
            return sceneConfig
        }

        // For the main app window scene, return configuration with SceneDelegate
        let sceneConfig = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        sceneConfig.delegateClass = SceneDelegate.self
        sceneConfig.storyboard = UIStoryboard(name: "Main", bundle: nil)
        return sceneConfig
    }
}

private func setExcludeFromiCloudBackup(_ dir: URL, isExcluded: Bool) throws {
//    Awkwardly make a mutable copy of the dir
    var mutableDir = dir

    var values = URLResourceValues()
    values.isExcludedFromBackup = isExcluded
    try mutableDir.setResourceValues(values)
}

// TODO: This is a workaround because audio_service doesn't set MPNowPlayingInfoCenter.playbackState on iOS.
// The audio_service plugin only sets playbackState on macOS (see AudioServicePlugin.m line 293-295).
// This causes CarPlay's Now Playing screen to not reflect the correct play/pause state when
// playback is started from the phone. Consider contributing a fix upstream to audio_service.

extension AppDelegate {
    func setupPlaybackStateChannel() {
        let channel = FlutterMethodChannel(
            name: "\(Bundle.main.bundleIdentifier!)/playback_state",
            binaryMessenger: flutterEngine.binaryMessenger
        )

        channel.setMethodCallHandler { [weak self] (call, result) in
            switch call.method {
            case "setPlaybackState":
                guard let args = call.arguments as? [String: Any],
                      let isPlaying = args["isPlaying"] as? Bool else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Missing isPlaying argument", details: nil))
                    return
                }

                if #available(iOS 13.0, *) {
                    let center = MPNowPlayingInfoCenter.default()
                    center.playbackState = isPlaying ? .playing : .paused
                }
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

let widgetControlDarwinPrefix = "fr.nytuo.diapason.widget."

private var widgetControlChannel: FlutterMethodChannel?

extension AppDelegate {
    /// Bridges the widget's play/pause/next/previous buttons to Flutter.
    func setupWidgetControlChannel() {
        widgetControlChannel = FlutterMethodChannel(
            name: "\(Bundle.main.bundleIdentifier!)/widget_control",
            binaryMessenger: flutterEngine.binaryMessenger
        )

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in ["playpause", "next", "previous"] {
            CFNotificationCenterAddObserver(
                center,
                nil,
                { (_, _, name, _, _) in
                    guard let raw = name?.rawValue as String? else { return }
                    let command = (raw as NSString)
                        .replacingOccurrences(of: widgetControlDarwinPrefix, with: "")
                    DispatchQueue.main.async {
                        widgetControlChannel?.invokeMethod("control", arguments: command)
                    }
                },
                "\(widgetControlDarwinPrefix)\(command)" as CFString,
                nil,
                .deliverImmediately
            )
        }
    }
}

// Handles voice commands like "Hey Siri, play [track/artist] on Diapason"

private var siriIntentChannel: FlutterMethodChannel?

extension AppDelegate {
    func setupSiriIntentChannel() {
        siriIntentChannel = FlutterMethodChannel(
            name: "\(Bundle.main.bundleIdentifier!)/siri_intent",
            binaryMessenger: flutterEngine.binaryMessenger
        )
    }

    /// Resolves media items for Siri so it knows the app can handle the request.
    /// Without this, Siri says "That action is not supported on Diapason."
    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        // If Siri provided media items, accept them
        if let mediaItems = intent.mediaItems, !mediaItems.isEmpty {
            completion(mediaItems.map { INPlayMediaMediaItemResolutionResult.success(with: $0) })
            return
        }

        // Otherwise, create a media item from the search to tell Siri we can handle it
        let mediaSearch = intent.mediaSearch
        let title = mediaSearch?.mediaName ?? mediaSearch?.artistName ?? mediaSearch?.albumName ?? "Music"
        let mediaItem = INMediaItem(
            identifier: nil,
            title: title,
            type: .music,
            artwork: nil
        )
        completion([INPlayMediaMediaItemResolutionResult.success(with: mediaItem)])
    }

    /// Handles the play media intent from Siri by forwarding to Flutter.
    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        activateAudioSessionForPlayIntent()

        let searchData = extractSearchData(from: intent)

        NSLog("[DIAPASON] Siri handle play intent - query: \(searchData["query"] ?? "nil"), artist: \(searchData["artist"] ?? "nil"), album: \(searchData["album"] ?? "nil")")

        siriIntentChannel?.invokeMethod("playFromSearch", arguments: searchData)

        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
    }

    /// Extracts search parameters from an INPlayMediaIntent into a dictionary for Flutter.
    private func extractSearchData(from intent: INPlayMediaIntent) -> [String: Any] {
        let mediaSearch = intent.mediaSearch
        var searchData: [String: Any] = [:]

        if let mediaName = mediaSearch?.mediaName {
            searchData["query"] = mediaName
        }
        if let artistName = mediaSearch?.artistName {
            searchData["artist"] = artistName
        }
        if let albumName = mediaSearch?.albumName {
            searchData["album"] = albumName
        }
        if let genreNames = mediaSearch?.genreNames, !genreNames.isEmpty {
            searchData["genre"] = genreNames.first
        }
        if let mediaType = mediaSearch?.mediaType {
            switch mediaType {
            case .artist: searchData["mediaType"] = "artist"
            case .album: searchData["mediaType"] = "album"
            case .song: searchData["mediaType"] = "song"
            case .playlist: searchData["mediaType"] = "playlist"
            case .genre: searchData["mediaType"] = "genre"
            default: break
            }
        }
        if intent.playShuffled == true {
            searchData["shuffle"] = true
        }

        return searchData
    }

    // Handle Siri media intents via NSUserActivity (fallback path)
    override func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        // Check if this is a Siri media intent
        if userActivity.activityType == NSStringFromClass(INPlayMediaIntent.self) ||
           userActivity.activityType == "INPlayMediaIntent" {
            return handlePlayMediaIntent(userActivity: userActivity)
        }

        if userActivity.activityType == NSStringFromClass(INSearchForMediaIntent.self) ||
           userActivity.activityType == "INSearchForMediaIntent" {
            return handleSearchForMediaIntent(userActivity: userActivity)
        }

        // Fall back to default handling (e.g., app links)
        return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    private func handlePlayMediaIntent(userActivity: NSUserActivity) -> Bool {
        guard let interaction = userActivity.interaction,
              let intent = interaction.intent as? INPlayMediaIntent else {
            NSLog("[DIAPASON] Could not extract INPlayMediaIntent from user activity")
            return false
        }

        activateAudioSessionForPlayIntent()

        let searchData = extractSearchData(from: intent)

        NSLog("[DIAPASON] Play media intent via NSUserActivity - query: \(searchData["query"] ?? "nil"), artist: \(searchData["artist"] ?? "nil"), album: \(searchData["album"] ?? "nil")")

        siriIntentChannel?.invokeMethod("playFromSearch", arguments: searchData)

        return true
    }

    /// Activates the audio session before Flutter processes a play intent.
    /// This prevents other apps from briefly resuming during the Siri-to-Flutter handoff gap.
    /// Calling setActive(true) on an already-active session is a no-op.
    private func activateAudioSessionForPlayIntent() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            NSLog("[DIAPASON] Failed to activate audio session for play intent: \(error)")
        }
    }

    private func handleSearchForMediaIntent(userActivity: NSUserActivity) -> Bool {
        guard let interaction = userActivity.interaction,
              let intent = interaction.intent as? INSearchForMediaIntent else {
            NSLog("[DIAPASON] Could not extract INSearchForMediaIntent from user activity")
            return false
        }

        let mediaSearch = intent.mediaSearch
        var searchData: [String: Any] = [:]

        if let mediaName = mediaSearch?.mediaName {
            searchData["query"] = mediaName
        }
        if let artistName = mediaSearch?.artistName {
            searchData["artist"] = artistName
        }
        if let albumName = mediaSearch?.albumName {
            searchData["album"] = albumName
        }
        searchData["searchOnly"] = true

        NSLog("[DIAPASON] Search media intent - query: \(searchData["query"] ?? "nil")")

        siriIntentChannel?.invokeMethod("searchMedia", arguments: searchData)

        return true
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
