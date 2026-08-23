import UIKit
import Flutter

@main
class AppDelegate: FlutterAppDelegate {
    private var appleTvAudioChannel: AppleTvAudioChannel?
    private var appleTvSystemChannel: AppleTvSystemChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let flutterViewController = FlutterViewController(project: nil, nibName: nil, bundle: nil)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = flutterViewController
        window.makeKeyAndVisible()
        self.window = window

        appleTvAudioChannel = AppleTvAudioChannel(messenger: flutterViewController.binaryMessenger)
        appleTvSystemChannel = AppleTvSystemChannel(messenger: flutterViewController.binaryMessenger)

        GeneratedPluginRegistrant.register(with: self)

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
