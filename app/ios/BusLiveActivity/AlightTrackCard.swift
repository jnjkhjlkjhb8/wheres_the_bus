import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Widget

struct AlightTrackWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlightTrackAttributes.self) { context in
            AlightTrackCard(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            // A Live Activity is system chrome, so it keeps the system's own
            // material. A card that paints its own background stops matching
            // the lock screen it sits on.
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            island(attributes: context.attributes, state: context.state, isStale: context.isStale)
        }
    }

    private func island(
        attributes: AlightTrackAttributes,
        state: AlightTrackAttributes.ContentState,
        isStale: Bool
    ) -> DynamicIsland {
        let tone = TrackTone(state)
        let copy = TrackCopy(attributes, state, isStale: isStale)
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                TrackIdentity(
                    attributes: attributes,
                    state: state,
                    copy: copy,
                    badgeSize: 24,
                    showsSubtitle: false
                )
                .padding(.leading, 4)
            }
            DynamicIslandExpandedRegion(.trailing) {
                TrackReading(state: state, tone: tone)
            }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(spacing: 9) {
                    TrackBar(state: state, tone: tone)
                    // The subtitle lands here rather than under the title: this
                    // is the island's only full-width row, and the next stop is
                    // the line that most needs the room.
                    TrackFoot(state: state, isStale: isStale, text: copy.subtitle)
                }
            }
        } compactLeading: {
            TrackBadge(
                mode: attributes.mode,
                lineCode: state.lineCode,
                lineColorHex: state.lineColorHex,
                size: 21
            )
        } compactTrailing: {
            CompactReading(state: state, tone: tone)
        } minimal: {
            MinimalReading(attributes: attributes, state: state, tone: tone)
        }
        // Distance reaches the collapsed island through its outline, which is
        // the only surface the system lets a Live Activity colour there.
        .keylineTint(tone.color)
    }
}

// MARK: - The card

struct AlightTrackCard: View {
    let attributes: AlightTrackAttributes
    let state: AlightTrackAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let tone = TrackTone(state)
        let copy = TrackCopy(attributes, state, isStale: isStale)
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                TrackIdentity(attributes: attributes, state: state, copy: copy, badgeSize: 27)
                Spacer(minLength: 8)
                TrackReading(state: state, tone: tone)
            }
            TrackBar(state: state, tone: tone)
            TrackFoot(state: state, isStale: isStale, text: copy.lead)
        }
        .padding(16)
    }
}

// MARK: - Copy

private struct TrackCopy {
    let title: String
    let subtitle: String
    let lead: String

    init(_ attributes: AlightTrackAttributes, _ state: AlightTrackAttributes.ContentState, isStale: Bool) {
        // The title is the destination, not the vehicle: the session exists to
        // get the rider off at one stop, and that stop is what they check for.
        switch state.phase {
        case .lost:
            title = "追蹤失效"
            subtitle = "請重新綁定"
        case .arrived:
            title = "已到 \(attributes.targetStation)"
            subtitle = "追蹤結束"
        case .waiting:
            title = "下一班 \(state.vehicleLabel)"
            let walk = state.walkMinutes > 0 ? " · 步行 \(state.walkMinutes) 分" : ""
            subtitle = "於 \(attributes.boardStation) 上車\(walk)"
        case .riding, .approaching:
            title = "往 \(attributes.targetStation)"
            subtitle = "\(state.vehicle) · 下一站 \(state.nextStation)"
        }

        if isStale, state.phase.isLive {
            lead = "資料已停止更新"
        } else {
            switch state.phase {
            case .lost: lead = "最後位置 \(state.nextStation)"
            case .arrived: lead = "感謝搭乘"
            case .waiting: lead = "尚未上車"
            case .riding, .approaching:
                if state.remainingStops <= 1 {
                    lead = "下一站就是 \(attributes.targetStation)"
                } else if state.remainingStops <= state.leadStops + 1 {
                    lead = "準備下車"
                } else {
                    lead = "車上"
                }
            }
        }
    }
}

// MARK: - Row 1: identity and reading

private struct TrackIdentity: View {
    let attributes: AlightTrackAttributes
    let state: AlightTrackAttributes.ContentState
    let copy: TrackCopy
    let badgeSize: CGFloat
    /// The island's leading region has no room for two stacked lines.
    var showsSubtitle = true

    var body: some View {
        HStack(spacing: 10) {
            TrackBadge(
                mode: attributes.mode,
                lineCode: state.lineCode,
                lineColorHex: state.lineColorHex,
                size: badgeSize
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if showsSubtitle {
                    Text(copy.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The headline reading: `剩 N 站` while riding, a self-ticking countdown while
/// waiting, nothing once the session has ended.
private struct TrackReading: View {
    let state: AlightTrackAttributes.ContentState
    let tone: TrackTone

    var body: some View {
        switch state.phase {
        case .arrived, .lost:
            // Nothing to read: there are no stops left to count.
            EmptyView()
        case .waiting:
            if let minutes = state.etaMinutes, minutes > 0 {
                Reading(value: "\(minutes)", unit: "分", color: tone.color)
            } else {
                Text("進站中").font(.headline)
            }
        case .riding, .approaching:
            Reading(value: "\(state.remainingStops)", unit: "站", color: tone.color)
        }
    }
}

/// One shape for every headline number: a big tabular figure and its unit.
/// Minutes before boarding and stops after are the same reading of the same
/// question, so they are the same object.
private struct Reading: View {
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .countdownDigits()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Row 2: progress

private struct TrackBar: View {
    let state: AlightTrackAttributes.ContentState
    let tone: TrackTone

    var body: some View {
        if state.phase != .waiting {
            ProgressView(value: state.progress)
                .progressViewStyle(.linear)
                .tint(tone.color)
        }
    }
}

// MARK: - Row 3: next step and the action

private struct TrackFoot: View {
    let state: AlightTrackAttributes.ContentState
    let isStale: Bool
    /// The lock screen puts the next step here. The island's bottom region is
    /// the only full-width row it has, so there this carries the subtitle the
    /// leading region could not fit.
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isStale, state.phase.isLive {
                Text(state.asOfDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if state.phase.isLive {
                if #available(iOS 17.0, *) {
                    Button(intent: CancelTrackIntent()) {
                        Text("取消追蹤").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.primary)
                }
            }
        }
    }
}

// MARK: - Dynamic Island readings

private struct CompactReading: View {
    let state: AlightTrackAttributes.ContentState
    let tone: TrackTone

    var body: some View {
        switch state.phase {
        case .arrived:
            Text("已到站").font(.caption).lineLimit(1)
        case .lost:
            Text("失效").font(.caption).lineLimit(1)
        case .waiting:
            if let minutes = state.etaMinutes, minutes > 0 {
                Text("\(minutes) 分")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Text("進站中").font(.caption).lineLimit(1)
            }
        case .riding, .approaching:
            Text("剩 \(state.remainingStops) 站")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tone.color)
                .lineLimit(1)
        }
    }
}

/// The minimal slot is one number, because the number is the answer. A ring
/// with no number in it would be decoration at 24pt.
private struct MinimalReading: View {
    let attributes: AlightTrackAttributes
    let state: AlightTrackAttributes.ContentState
    let tone: TrackTone

    var body: some View {
        switch state.phase {
        case .riding, .approaching:
            Gauge(value: state.progress) {
                EmptyView()
            } currentValueLabel: {
                Text("\(state.remainingStops)")
                    .monospacedDigit()
                    .countdownDigits()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tone.color)
        case .waiting, .arrived, .lost:
            // No stop count to show: the glyph says a session is running, and
            // the pill next to it says which.
            Image(systemName: attributes.mode.glyph)
                .font(.caption)
                .foregroundStyle(tone.color)
        }
    }
}

// MARK: - Badge

private struct TrackBadge: View {
    let mode: AlightTrackAttributes.Mode
    let lineCode: String?
    let lineColorHex: String?
    let size: CGFloat

    var body: some View {
        if mode == .metro, let code = lineCode, !code.isEmpty {
            Circle()
                .fill(Color(hex: lineColorHex) ?? .secondary)
                .frame(width: size, height: size)
                .overlay(
                    Text(code)
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                )
        } else {
            Image(systemName: mode.glyph)
                .font(.system(size: size * 0.72))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Tone

enum TrackTone {
    case calm, warm, go, spent

    init(_ state: AlightTrackAttributes.ContentState) {
        switch state.phase {
        case .lost:
            self = .spent
        case .waiting, .arrived:
            self = .calm
        case .riding, .approaching:
            if state.remainingStops <= 1 {
                self = .go
            } else if state.remainingStops <= state.leadStops + 1 {
                self = .warm
            } else {
                self = .calm
            }
        }
    }

    var color: Color {
        switch self {
        case .calm: return .primary
        case .spent: return .secondary
        case .warm: return .dual(light: 0xB5_4708, dark: 0xF7_9009)
        case .go: return .dual(light: 0x0E_7C42, dark: 0x12_B76A)
        }
    }
}

// MARK: - Helpers

private extension View {
    @ViewBuilder
    func countdownDigits() -> some View {
        if #available(iOS 17.0, *) {
            contentTransition(.numericText(countsDown: true))
        } else {
            contentTransition(.numericText())
        }
    }
}

private extension Color {
    /// One token, both appearances. The lock screen follows the device's
    /// light/dark setting and the widget bundle carries no asset catalogue, so
    /// every literal has to name its two values here.
    static func dual(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Parses `#RRGGBB` line colours arriving as data; nil when malformed so
    /// the caller can fall back.
    init?(hex: String?) {
        guard var value = hex else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(uiColor: UIColor(rgb: rgb))
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
