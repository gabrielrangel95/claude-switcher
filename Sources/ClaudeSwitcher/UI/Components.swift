import SwiftUI

enum Format {
    static func relative(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(max(minutes, 1))m"
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}

func usageTint(_ utilization: Double) -> Color {
    switch utilization {
    case ..<70: return .green
    case ..<90: return .orange
    default: return .red
    }
}

struct UsageBar: View {
    let title: String
    let window: UsageWindow?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let window {
                    Text(Format.percent(window.utilization)).monospacedDigit()
                    if !compact, let reset = window.resetsAt {
                        Text("· resets \(Format.relative(reset))").foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(usageTint(window?.utilization ?? 0))
                        .frame(width: proxy.size.width * min(1, max(0, (window?.utilization ?? 0) / 100)))
                }
            }
            .frame(height: compact ? 4 : 5)
        }
    }
}

struct AccountDot: View {
    let color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}
