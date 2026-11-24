import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let mapsAPIKey = DartDefines.mapsAPIKey(
      from: Bundle.main.infoDictionary,
      failClosed: DartDefines.isFailClosed()
    )
    if !mapsAPIKey.isEmpty {
      GMSServices.provideAPIKey(mapsAPIKey)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    if !registry.hasPlugin("NativeDialogPlugin"),
      let registrar = registry.registrar(forPlugin: "NativeDialogPlugin") {
      NativeDialogPlugin.register(with: registrar)
    }
    if !registry.hasPlugin("NativeNavBarFactory"),
      let registrar = registry.registrar(forPlugin: "NativeNavBarFactory") {
      registrar.register(
        NativeNavBarFactory(messenger: registrar.messenger()),
        withId: NativeNavBarFactory.viewType
      )
    }
    if !registry.hasPlugin("HomeShortcutsPlugin"),
      let registrar = registry.registrar(forPlugin: "HomeShortcutsPlugin") {
      HomeShortcutsPlugin.register(with: registrar)
    }
    if !registry.hasPlugin("NativeControls"),
      let registrar = registry.registrar(forPlugin: "NativeControls") {
      NativeControls.register(with: registrar)
    }
    guard !registry.hasPlugin("LiveActivityPlugin") else { return }
    guard let registrar = registry.registrar(forPlugin: "LiveActivityPlugin") else { return }
    LiveActivityPlugin.register(with: registrar)
  }
}
