import Flutter
import UIKit

/// Home-screen quick actions. Dart sets the items (so titles follow the
/// in-app language) and receives the picked one's route path. See
/// `home_shortcuts.dart`.
class HomeShortcutsPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
    private let channel: FlutterMethodChannel

    /// The action that launched the app, held until Dart asks for it: on a
    /// cold launch nothing is listening yet when the scene connects.
    private var pending: String?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "me.rabbitsayhello.wheresthebus/home_shortcuts",
            binaryMessenger: registrar.messenger()
        )
        let plugin = HomeShortcutsPlugin(channel: channel)
        registrar.addMethodCallDelegate(plugin, channel: channel)
        registrar.addSceneDelegate(plugin)
    }

    private init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "set":
            let items = call.arguments as? [[String: String]] ?? []
            UIApplication.shared.shortcutItems = items.compactMap(Self.item)
            result(nil)
        case "pending":
            result(pending)
            pending = nil
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func item(_ spec: [String: String]) -> UIApplicationShortcutItem? {
        guard let path = spec["path"], let title = spec["title"] else { return nil }
        let symbol = spec["icon"] == "bookmark" ? "bookmark" : "magnifyingglass"
        return UIApplicationShortcutItem(
            type: path,
            localizedTitle: title,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: symbol)
        )
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions?
    ) -> Bool {
        guard let item = connectionOptions?.shortcutItem else { return false }
        pending = item.type
        return true
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) -> Bool {
        channel.invokeMethod("open", arguments: shortcutItem.type)
        completionHandler(true)
        return true
    }
}
