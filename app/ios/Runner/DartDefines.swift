import Foundation

enum DartDefines {
    static func decode(_ rawDartDefines: String) -> [String: String] {
        guard !rawDartDefines.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for item in rawDartDefines.split(separator: ",", omittingEmptySubsequences: true) {
            guard let data = Data(base64Encoded: String(item)),
                  let decoded = String(data: data, encoding: .utf8)
            else { continue }
            guard let separatorIndex = decoded.firstIndex(of: "=") else { continue }
            let key = String(decoded[decoded.startIndex..<separatorIndex])
            let value = String(decoded[decoded.index(after: separatorIndex)...])
            if key.lowercased().hasPrefix("flutter") { continue }
            result[key] = value
        }
        return result
    }

    /// Whether a missing Maps key must hard-fail this build rather than
    /// silently render a blank map. Debug builds (local development,
    /// simulator) are allowed to run without a key configured.
    static func isFailClosed(isDebug: Bool = _isDebugAssertConfiguration()) -> Bool {
        !isDebug
    }

    static func resolvedMapsAPIKey(from infoDictionary: [String: Any]?) -> String? {
        let key = (infoDictionary?["GOOGLE_MAPS_API_KEY"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    static func mapsAPIKey(
        from infoDictionary: [String: Any]?,
        failClosed: Bool
    ) -> String {
        if let key = resolvedMapsAPIKey(from: infoDictionary) {
            return key
        }
        if failClosed {
            assertionFailure(
                "GOOGLE_MAPS_API_KEY is missing from Info.plist. This should have " +
                "failed the build in the \"Validate Dart Defines\" phase " +
                "(Flutter/validate_dart_defines.sh) — pass " +
                "--dart-define=GOOGLE_MAPS_API_KEY=... when building (see app/env/*.json)."
            )
        }
        return ""
    }
}
