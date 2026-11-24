import Flutter
import UIKit

/// UIKit controls vended to Flutter as platform views. Each view type has a
/// factory here and a Dart widget in `native_controls.dart`; the two talk on
/// a per-view channel named `<viewType>_<id>`: Dart sends `update` with the
/// full parameter map, the control sends its events back.
enum NativeControls {
    static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        registrar.register(ControlFactory<TimeWheelControl>(messenger), withId: TimeWheelControl.viewType)
        registrar.register(ControlFactory<IconButtonControl>(messenger), withId: IconButtonControl.viewType)
    }
}

/// One hosted control: builds its view, applies parameter maps, and reports
/// input through `send`.
private protocol Control: AnyObject {
    /// Must match the Dart widget's `viewType`.
    static var viewType: String { get }
    init(send: @escaping (String, Any?) -> Void)
    var view: UIView { get }
    func apply(_ args: [String: Any])
}

private class ControlFactory<C: Control>: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(_ messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        ControlHost<C>(viewId: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

private class ControlHost<C: Control>: NSObject, FlutterPlatformView {
    private let control: C
    private let channel: FlutterMethodChannel

    init(viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "\(C.viewType)_\(viewId)",
            binaryMessenger: messenger
        )
        self.channel = channel
        control = C(send: { [weak channel] method, arguments in
            channel?.invokeMethod(method, arguments: arguments)
        })
        super.init()
        control.apply(args)
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "update", let args = call.arguments as? [String: Any] else {
                result(FlutterMethodNotImplemented)
                return
            }
            self?.control.apply(args)
            result(nil)
        }
    }

    func view() -> UIView { control.view }
}

private extension Control {
    /// The app has its own appearance setting, which a UIKit view would
    /// otherwise ignore in favour of the device's.
    func applyAppearance(_ args: [String: Any]) {
        if let dark = args["dark"] as? Bool {
            view.overrideUserInterfaceStyle = dark ? .dark : .light
        }
    }
}

private final class TimeWheelControl: NSObject, Control {
    static let viewType = "me.rabbitsayhello.wheresthebus/native_time_wheel"

    private let send: (String, Any?) -> Void
    private let picker = UIDatePicker()
    private var shown: DateComponents?

    init(send: @escaping (String, Any?) -> Void) {
        self.send = send
        super.init()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        // 24-hour, matching every other time the app shows.
        picker.locale = Locale(identifier: "en_GB")
        picker.addTarget(self, action: #selector(changed), for: .valueChanged)
    }

    var view: UIView { picker }

    func apply(_ args: [String: Any]) {
        let wanted = DateComponents(hour: args["hour"] as? Int, minute: args["minute"] as? Int)
        // Only a new time from Dart moves the wheel; re-applying the one it
        // opened with must not undo what the rider has scrolled to.
        if wanted != shown, let date = Calendar.current.date(
            bySettingHour: wanted.hour ?? 0, minute: wanted.minute ?? 0, second: 0, of: Date()
        ) {
            shown = wanted
            picker.setDate(date, animated: false)
        }
        applyAppearance(args)
    }

    @objc private func changed() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
        send("changed", ["hour": parts.hour ?? 0, "minute": parts.minute ?? 0])
    }
}

private final class IconButtonControl: NSObject, Control {
    static let viewType = "me.rabbitsayhello.wheresthebus/native_icon_button"

    private let send: (String, Any?) -> Void
    private let button = UIButton(type: .system)

    init(send: @escaping (String, Any?) -> Void) {
        self.send = send
        super.init()
        button.addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
    }

    var view: UIView { button }

    func apply(_ args: [String: Any]) {
        let prominent = args["prominent"] as? Bool ?? false
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = prominent ? .prominentGlass() : .glass()
        } else {
            config = prominent ? .filled() : .plain()
        }
        config.image = UIImage(systemName: args["symbol"] as? String ?? "")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        config.cornerStyle = .capsule
        button.configuration = config
        button.accessibilityLabel = args["label"] as? String
        button.tintColor = (args["tint"] as? Int).map(UIColor.init(argb:))
        applyAppearance(args)
    }

    @objc private func tapped() {
        send("tap", nil)
    }
}

extension UIColor {
    convenience init(argb: Int) {
        self.init(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }
}
