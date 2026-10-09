import XCTest

final class ConfigurationTests: XCTestCase {

  /// `RunnerTests/ConfigurationTests.swift` -> `app/ios`.
  private var iosRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func plist(at relativePath: String) throws -> [String: Any] {
    let url = iosRoot.appendingPathComponent(relativePath)
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(plist as? [String: Any])
  }

  private func pbxprojText() throws -> String {
    let url = iosRoot.appendingPathComponent("Runner.xcodeproj/project.pbxproj")
    return try String(contentsOf: url, encoding: .utf8)
  }

  // MARK: - Info.plist: location privacy (F01)

  func testRunnerInfoPlistHasLocationWhenInUseUsageDescription() throws {
    let info = try plist(at: "Runner/Info.plist")
    let description = info["NSLocationWhenInUseUsageDescription"] as? String
    XCTAssertNotNil(description, "Missing NSLocationWhenInUseUsageDescription")
    XCTAssertFalse(description?.isEmpty ?? true, "Location usage description must not be blank")
  }

  func testRunnerInfoPlistDoesNotRequestBackgroundLocation() throws {
    let info = try plist(at: "Runner/Info.plist")
    let modes = info["UIBackgroundModes"] as? [String] ?? []
    XCTAssertFalse(
      modes.contains("location"),
      "Background location is not proven-required by product use (nearby-stop lookup is foreground-only)"
    )
  }

  // MARK: - Info.plist: Live Activities (F04)

  func testRunnerInfoPlistSupportsLiveActivities() throws {
    let info = try plist(at: "Runner/Info.plist")
    XCTAssertEqual(info["NSSupportsLiveActivities"] as? Bool, true)
  }

  // MARK: - Info.plist: product name (F49, iOS side)

  func testRunnerInfoPlistDisplayNameIsProductName() throws {
    let info = try plist(at: "Runner/Info.plist")
    XCTAssertEqual(info["CFBundleDisplayName"] as? String, "我公車呢")
  }

  // MARK: - Widget extension Info.plist (F03)

  func testBusLiveActivityInfoPlistDeclaresWidgetKitExtensionPoint() throws {
    let info = try plist(at: "BusLiveActivity/Info.plist")
    let extensionDict = info["NSExtension"] as? [String: Any]
    XCTAssertEqual(
      extensionDict?["NSExtensionPointIdentifier"] as? String,
      "com.apple.widgetkit-extension"
    )
  }

  // MARK: - Project wiring (F02/P0-06, F03, F07)

  func testLiveActivityPluginIsARunnerSource() throws {
    let text = try pbxprojText()
    XCTAssertTrue(
      text.contains("LiveActivityPlugin.swift in Sources"),
      "LiveActivityPlugin.swift must be a member of Runner's Sources build phase"
    )
  }

  func testDartDefinesIsARunnerSource() throws {
    let text = try pbxprojText()
    XCTAssertTrue(
      text.contains("DartDefines.swift in Sources"),
      "DartDefines.swift must be a member of Runner's Sources build phase"
    )
  }

  func testSharedAttributesAreMembersOfBothRunnerAndWidgetExtension() throws {
    let text = try pbxprojText()
    let occurrences = text.components(separatedBy: "BusLiveActivityAttributes.swift in Sources").count - 1
    XCTAssertEqual(
      occurrences, 2,
      "BusLiveActivityAttributes.swift must be a Sources member of both Runner and BusLiveActivity"
    )
  }

  func testBusLiveActivityTargetExists() throws {
    let text = try pbxprojText()
    XCTAssertTrue(text.contains("productType = \"com.apple.product-type.app-extension\""))
    XCTAssertTrue(text.contains("name = BusLiveActivity;"))
  }

  func testBusLiveActivityIsEmbeddedInRunner() throws {
    let text = try pbxprojText()
    XCTAssertTrue(text.contains("Embed Foundation Extensions"))
    XCTAssertTrue(text.contains("BusLiveActivity.appex in Embed Foundation Extensions"))
  }

  func testBusLiveActivityDeploymentTargetIsAtLeast16_1() throws {
    let text = try pbxprojText()
    XCTAssertTrue(text.contains("IPHONEOS_DEPLOYMENT_TARGET = 16.1;"))
  }

  func testDartDefinesXcconfigIsBridgedIntoBuildConfigs() throws {
    let debug = try String(
      contentsOf: iosRoot.appendingPathComponent("Flutter/Debug.xcconfig"), encoding: .utf8
    )
    let release = try String(
      contentsOf: iosRoot.appendingPathComponent("Flutter/Release.xcconfig"), encoding: .utf8
    )
    XCTAssertTrue(debug.contains("Dart-Defines.xcconfig"))
    XCTAssertTrue(release.contains("Dart-Defines.xcconfig"))
  }
}
