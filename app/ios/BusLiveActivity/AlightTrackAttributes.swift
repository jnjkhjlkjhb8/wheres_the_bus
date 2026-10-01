import ActivityKit
import Foundation

struct AlightTrackAttributes: ActivityAttributes {
    /// Which network. Selects the leading glyph, and nothing else.
    enum Mode: String, Codable, Hashable {
        case bus, tra, thsr, metro

        var glyph: String {
            switch self {
            case .bus: return "bus.fill"
            case .metro: return "tram.fill"
            case .tra, .thsr: return "train.side.front.car"
            }
        }
    }

    /// Where the rider is in one session. Drives copy and colour; never layout.
    enum Phase: String, Codable, Hashable {
        case waiting, riding, approaching, arrived, lost

        /// A live session still has something to cancel and something to show
        /// a progress bar for. `arrived` and `lost` are terminal readings.
        var isLive: Bool {
            self == .waiting || self == .riding || self == .approaching
        }
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase

        /// Route or train identity as the rider reads it: `307`, `自強 408`,
        /// `高鐵 663`, `板南線`.
        var vehicleLabel: String

        /// The specific vehicle — plate, or the metro carID. Nil when the
        /// session tracks a route rather than one vehicle.
        var vehicleId: String?

        var nextStation: String

        /// Hops from the board stop to the alight stop. At least 1, so the
        /// progress bar never divides by nothing.
        var hopCount: Int
        var currentIndex: Int
        var remainingStops: Int

        /// The rider's own 提前站數. Doubles as the colour threshold: the card
        /// turns warm at the same count the reminder fires on.
        var leadStops: Int

        var etaUnix: Int?

        var etaMinutes: Int?

        /// Walk to the board stop, minutes. Only meaningful while waiting.
        var walkMinutes: Int

        /// The metro line's identity as data: roundel code and colour.
        var lineCode: String?
        var lineColorHex: String?

        /// When this reading was taken, unix seconds. Read only once the system
        /// has marked the activity stale, where the exact distance is the useful
        /// part of the answer. Unix seconds for the same reason as [etaUnix].
        var asOfUnix: Int
    }

    let mode: Mode
    let boardStation: String
    let targetStation: String
}

extension AlightTrackAttributes.ContentState {
    /// [asOfUnix] as a date, for the one place that renders a distance from it.
    var asOfDate: Date { Date(timeIntervalSince1970: Double(asOfUnix)) }

    /// [etaUnix] as a date, for the stale window a waiting card sets from it.
    var etaDate: Date? { etaUnix.map { Date(timeIntervalSince1970: Double($0)) } }

    var progress: Double {
        switch phase {
        case .waiting:
            return 0
        case .arrived:
            return 1
        case .riding, .approaching, .lost:
            let hops = Double(max(1, hopCount))
            return min(1, max(0, Double(currentIndex) / hops))
        }
    }

    /// Route and vehicle as one string: `307 KKA-1234`, or just `307` when the
    /// session is not pinned to a vehicle.
    var vehicle: String {
        guard let id = vehicleId, !id.isEmpty else { return vehicleLabel }
        return "\(vehicleLabel) \(id)"
    }
}
