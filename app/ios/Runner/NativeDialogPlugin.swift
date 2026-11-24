import Flutter
import UIKit

/// Presents system alerts on behalf of Dart, so confirmations look and behave
/// like the rest of iOS instead of a drawn imitation.
class NativeDialogPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "me.rabbitsayhello.wheresthebus/native_dialog",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(NativeDialogPlugin(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "confirm" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard
            let args = call.arguments as? [String: Any],
            let title = args["title"] as? String,
            let confirmLabel = args["confirmLabel"] as? String,
            let cancelLabel = args["cancelLabel"] as? String
        else {
            result(FlutterError(code: "bad_args", message: "confirm needs title and labels", details: nil))
            return
        }
        guard let presenter = Self.topViewController() else {
            result(FlutterError(code: "no_presenter", message: "no view controller to present from", details: nil))
            return
        }
        let alert = UIAlertController(
            title: title,
            message: args["message"] as? String,
            preferredStyle: .alert
        )
        // The app has its own appearance setting, which the system alert
        // would otherwise ignore in favour of the device's.
        if let dark = args["dark"] as? Bool {
            alert.overrideUserInterfaceStyle = dark ? .dark : .light
        }
        alert.addAction(UIAlertAction(title: cancelLabel, style: .cancel) { _ in result(false) })
        alert.addAction(UIAlertAction(title: confirmLabel, style: .destructive) { _ in result(true) })
        presenter.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
