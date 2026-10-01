import ActivityKit
import Flutter

class LiveActivityPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.wheres.bus/live_activity",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(LiveActivityPlugin(channel: channel), channel: channel)
        endOrphanedActivities()
    }

    private static func endOrphanedActivities() {
        guard #available(iOS 16.2, *) else { return }
        // Snapshotted here, synchronously, rather than inside the Task: a
        // restored session starts its own card within moments, and a list read
        // after that would sweep away the live one it just opened.
        let orphans = Activity<AlightTrackAttributes>.activities
        guard !orphans.isEmpty else { return }
        Task {
            for activity in orphans {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private let channel: FlutterMethodChannel
    private var activityID: String?

    private var lastPhase: AlightTrackAttributes.Phase?

    private var lastRemainingStops: Int?

    /// Streams this card's ActivityKit push token to Dart. Held so it can be
    /// cancelled with the card: the token dies with the activity, and a stream
    /// left running would outlive the session it belongs to.
    private var pushTokenTask: Task<Void, Never>?

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cardCancelled),
            name: .alightTrackCancelled,
            object: nil
        )
    }

    /// The 取消追蹤 button has already ended the activity; Dart still owns the
    /// session and has to hear about it to release its own lease.
    @objc private func cardCancelled() {
        activityID = nil
        lastPhase = nil
        stopObservingPushToken()
        DispatchQueue.main.async { [channel] in
            channel.invokeMethod("onCancelTrack", arguments: nil)
        }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 16.2, *) else { result(nil); return }
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "start": start(args: args, result: result)
        case "update": update(args: args, result: result)
        case "stop": stop(result: result)
        default: result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Commands

    @available(iOS 16.2, *)
    private func start(args: [String: Any], result: FlutterResult) {
        let state = contentState(from: args)
        let attributes = AlightTrackAttributes(
            mode: AlightTrackAttributes.Mode(rawValue: args["mode"] as? String ?? "") ?? .bus,
            boardStation: args["boardStation"] as? String ?? "",
            targetStation: args["targetStation"] as? String ?? ""
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content(state, mode: attributes.mode),
                pushType: .token
            )
            activityID = activity.id
            observePushToken(of: activity)
            lastPhase = state.phase
            // Seeds the crossing baseline, so a session that opens already
            // inside a threshold does not alert for a crossing that happened
            // before the card existed.
            lastRemainingStops = state.remainingStops
            result(activity.id)
        } catch {
            result(FlutterError(
                code: "LA_START_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    @available(iOS 16.2, *)
    private func update(args: [String: Any], result: @escaping FlutterResult) {
        guard let activity = current() else { result(nil); return }
        let state = contentState(from: args)
        // Computed before `lastPhase` moves: the alert is a crossing, not a
        // condition.
        let alert = reminderAlert(for: state, target: activity.attributes.targetStation)
        lastPhase = state.phase
        lastRemainingStops = state.remainingStops

        // A terminal reading is ended natively with a linger rather than left
        // for Dart to dismiss on a timer: an ending has to be seen, and a timer
        // in the app cannot fire once iOS has suspended it.
        if !state.phase.isLive {
            stopObservingPushToken()
            Task {
                await activity.end(
                    content(state, mode: activity.attributes.mode),
                    dismissalPolicy: .after(Date().addingTimeInterval(Self.lingerSeconds))
                )
                result(nil)
            }
            return
        }

        Task {
            await activity.update(
                content(state, mode: activity.attributes.mode),
                alertConfiguration: alert
            )
            result(nil)
        }
    }

    @available(iOS 16.2, *)
    private func stop(result: @escaping FlutterResult) {
        guard let activity = current() else { result(nil); return }
        activityID = nil
        lastPhase = nil
        stopObservingPushToken()
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            result(nil)
        }
    }

    @available(iOS 16.2, *)
    private func observePushToken(of activity: Activity<AlightTrackAttributes>) {
        pushTokenTask?.cancel()
        pushTokenTask = Task { [channel] in
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { channel.invokeMethod("onPushToken", arguments: token) }
            }
        }
    }

    /// Ends the token stream. Called wherever the card ends, so no session is
    /// left with a live stream and no card.
    private func stopObservingPushToken() {
        pushTokenTask?.cancel()
        pushTokenTask = nil
    }

    @available(iOS 16.2, *)
    private func current() -> Activity<AlightTrackAttributes>? {
        guard let id = activityID else { return nil }
        return Activity<AlightTrackAttributes>.activities.first { $0.id == id }
    }

    // MARK: - Payload

    /// How long a terminal card stays on screen before the system dismisses it.
    private static let lingerSeconds: TimeInterval = 8

    @available(iOS 16.2, *)
    private func content(
        _ state: AlightTrackAttributes.ContentState,
        mode: AlightTrackAttributes.Mode
    ) -> ActivityContent<AlightTrackAttributes.ContentState> {
        ActivityContent(state: state, staleDate: staleDate(state, mode: mode))
    }

    @available(iOS 16.2, *)
    private func staleDate(
        _ state: AlightTrackAttributes.ContentState,
        mode: AlightTrackAttributes.Mode
    ) -> Date? {
        // A waiting card carries a self-ticking countdown to a fixed date, so
        // it stays true without new data right up to the arrival it names.
        if state.phase == .waiting { return state.etaDate }
        guard state.phase.isLive else { return nil }
        let window: TimeInterval
        switch mode {
        case .bus: window = 3 * 60
        case .metro: window = 6 * 60
        case .tra, .thsr: window = 20 * 60
        }
        return state.asOfDate.addingTimeInterval(window)
    }

    @available(iOS 16.2, *)
    private func reminderAlert(
        for state: AlightTrackAttributes.ContentState,
        target: String
    ) -> AlertConfiguration? {
        guard state.phase.isLive, let previous = lastRemainingStops else { return nil }
        let remaining = state.remainingStops
        guard remaining < previous else { return nil }
        if remaining == 1 {
            return AlertConfiguration(
                title: "Get Set",
                body: "下一站 \(target)",
                sound: .default
            )
        }
        if state.leadStops > 0, remaining == state.leadStops + 1 {
            return AlertConfiguration(
                title: "Ready",
                body: "再過 \(remaining) 站到 \(target)",
                sound: .default
            )
        }
        return nil
    }

    /// Dart's `AlightTrackContent.toArgs()`, one field at a time.
    private func contentState(from args: [String: Any]) -> AlightTrackAttributes.ContentState {
        let etaUnix = (args["etaMs"] as? Int).flatMap { ms in
            ms > 0 ? ms / 1000 : nil
        }
        return AlightTrackAttributes.ContentState(
            phase: AlightTrackAttributes.Phase(rawValue: args["phase"] as? String ?? "") ?? .riding,
            vehicleLabel: args["vehicleLabel"] as? String ?? "",
            vehicleId: args["vehicleId"] as? String,
            nextStation: args["nextStation"] as? String ?? "",
            hopCount: max(1, args["hopCount"] as? Int ?? 1),
            currentIndex: args["currentIndex"] as? Int ?? 0,
            remainingStops: max(0, args["remainingStops"] as? Int ?? 0),
            leadStops: max(0, args["leadStops"] as? Int ?? 0),
            etaUnix: etaUnix,
            etaMinutes: args["etaMinutes"] as? Int,
            walkMinutes: args["walkMinutes"] as? Int ?? 0,
            lineCode: args["lineCode"] as? String,
            lineColorHex: args["lineColorHex"] as? String,
            asOfUnix: Int(Date().timeIntervalSince1970)
        )
    }
}
