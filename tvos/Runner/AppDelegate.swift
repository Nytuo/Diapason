import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Held for the life of the app: the channels stop answering once they are released.
  private var appleTvAudioChannel: AppleTvAudioChannel?
  private var appleTvSystemChannel: AppleTvSystemChannel?
  private var appleTvBonjourChannel: AppleTvBonjourChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Diapason's own tvOS channels: native audio playback and system integration.
    let messenger = engineBridge.applicationRegistrar.messenger()
    appleTvAudioChannel = AppleTvAudioChannel(messenger: messenger)
    appleTvSystemChannel = AppleTvSystemChannel(messenger: messenger)
    // Diapason Connect: announcing this TV and finding the other devices.
    appleTvBonjourChannel = AppleTvBonjourChannel(messenger: messenger)
  }
}
