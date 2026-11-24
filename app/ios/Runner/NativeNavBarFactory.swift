import Flutter
import UIKit

/// Vends a real UINavigationBar to Flutter as a platform view, so a detail
/// screen's back button and title are drawn by the system (Liquid Glass on
/// iOS 26) instead of imitated.
class NativeNavBarFactory: NSObject, FlutterPlatformViewFactory {
    static let viewType = "me.rabbitsayhello.wheresthebus/native_nav_bar"

    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        NativeNavBar(frame: frame, viewId: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

private class NativeNavBar: NSObject, FlutterPlatformView {
    private let bar: UINavigationBar
    private let item = UINavigationItem()
    private let channel: FlutterMethodChannel

    init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
        bar = UINavigationBar(frame: frame)
        channel = FlutterMethodChannel(
            name: "\(NativeNavBarFactory.viewType)_\(viewId)",
            binaryMessenger: messenger
        )
        super.init()

        // The bar is not owned by a UINavigationController, so nothing gives
        // it a back button; this item stands in for one.
        item.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain,
            target: self,
            action: #selector(backTapped)
        )
        bar.setItems([item], animated: false)

        // The Flutter surface behind shows through; before iOS 26 the default
        // appearance would paint its own material over it.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance

        apply(args)
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "update", let args = call.arguments as? [String: Any] else {
                result(FlutterMethodNotImplemented)
                return
            }
            self?.apply(args)
            result(nil)
        }
    }

    func view() -> UIView { bar }

    private func apply(_ args: [String: Any]) {
        let title = args["title"] as? String ?? ""
        let subtitle = args["subtitle"] as? String
        item.title = title
        if #available(iOS 26.0, *) {
            item.subtitle = subtitle
        } else {
            item.titleView = subtitle.map { Self.twoLineTitle(title, $0) }
        }
        item.leftBarButtonItem?.accessibilityLabel = args["backLabel"] as? String
        item.rightBarButtonItem = Self.spacer(width: args["trailingWidth"] as? Double ?? 0)
        if let tint = args["tint"] as? Int {
            bar.tintColor = UIColor(argb: tint)
        }
        // The app has its own appearance setting, which the bar would
        // otherwise ignore in favour of the device's.
        if let dark = args["dark"] as? Bool {
            bar.overrideUserInterfaceStyle = dark ? .dark : .light
        }
    }

    /// Reserves the trailing edge for the Flutter widgets drawn over it, so
    /// the system centres and truncates the title around them.
    private static func spacer(width: Double) -> UIBarButtonItem? {
        guard width > 0 else { return nil }
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        let spacer = UIBarButtonItem(customView: view)
        if #available(iOS 26.0, *) {
            // Otherwise the empty slot gets a glass plate of its own.
            spacer.hidesSharedBackground = true
        }
        return spacer
    }

    /// UINavigationItem has no subtitle before iOS 26.
    private static func twoLineTitle(_ title: String, _ subtitle: String) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        return stack
    }

    @objc private func backTapped() {
        channel.invokeMethod("back", arguments: nil)
    }
}
