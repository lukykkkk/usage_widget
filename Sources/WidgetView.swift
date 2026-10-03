import SwiftUI

// Continuous interpolation makes increasing usage change from green through amber to red.
func quotaColor(used: Double) -> Color {
    let t = max(0, min(1, used / 100))
    let green = (0.10, 0.70, 0.43), yellow = (0.93, 0.65, 0.12), red = (0.91, 0.24, 0.28)
    let a = t < 0.5 ? green : yellow
    let b = t < 0.5 ? yellow : red
    let p = t < 0.5 ? t * 2 : (t - 0.5) * 2
    return Color(red: a.0 + (b.0 - a.0) * p, green: a.1 + (b.1 - a.1) * p, blue: a.2 + (b.2 - a.2) * p)
}

struct WidgetView: View {
    @ObservedObject var model: UsageModel
    var onResize: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    private let accent = Color(red: 0.37, green: 0.45, blue: 0.95)
    private var dark: Bool { scheme == .dark }
    private var card: Color { dark ? Color.white.opacity(0.055) : Color.white.opacity(0.70) }

    var body: some View {
        VStack(alignment: .leading, spacing: model.small ? 12 : 16) {
            header
            if let limits = model.limits, !limits.windows.isEmpty {
                let rows = Array(limits.windows.enumerated())
                if rows.count <= 2 {
                    ForEach(rows, id: \.offset) { _, item in quota(item, multi: false) }
                } else {
                    ScrollView {
                        VStack(spacing: 12) { ForEach(rows, id: \.offset) { _, item in quota(item, multi: true) } }
                    }.scrollIndicators(.hidden).frame(height: model.small ? 254 : 272)
                }
            } else {
                Text(model.error == nil ? "Connecting to Codex…" : "Account limits unavailable")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            session
            if !model.small { account }
            footer
            if let error = model.error {
                HStack {
                    Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    Button("Reconnect") { model.connect() }.font(.caption2)
                }
            }
        }
        .padding(model.small ? 16 : 20)
        .frame(width: model.small ? 300 : 400)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(dark ? Color(red: 0.075, green: 0.085, blue: 0.13) : Color(red: 0.94, green: 0.95, blue: 0.98))
                .overlay(alignment: .topLeading) {
                    LinearGradient(colors: [accent.opacity(dark ? 0.18 : 0.09), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(dark ? 0.12 : 0.85), lineWidth: 1))
        .padding(8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [accent, Color(red: 0.52, green: 0.38, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex").font(.system(size: 17, weight: .bold))
                Text("USAGE MONITOR").font(.system(size: 8, weight: .semibold)).tracking(1.7).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onResize) { Image(systemName: model.small ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") }
                .help(model.small ? "Switch to medium size" : "Switch to small size")
                .accessibilityLabel("Change widget size")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh account usage").accessibilityLabel("Refresh usage")
        }.buttonStyle(HeaderButtonStyle())
    }

    private func quota(_ item: (String, LimitWindow), multi: Bool) -> some View {
        let window = item.1
        let tint = quotaColor(used: 100 - window.remaining)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: window.windowDurationMins == 10080 ? "calendar" : "clock")
                        .foregroundStyle(.secondary).font(.system(size: 11))
                    Text(multi ? "\(item.0) · \(window.title)" : window.title)
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Text("\(window.remaining, specifier: "%.0f")%")
                    .font(.system(size: model.small ? 22 : 26, weight: .bold, design: .rounded))
                    .foregroundStyle(tint).monospacedDigit()
                Text("left").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(dark ? 0.10 : 0.055))
                    Capsule().fill(LinearGradient(colors: [quotaColor(used: max(0, window.usedPercent - 16)), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * window.remaining / 100)
                }
            }.frame(height: 7)
                .animation(.easeInOut(duration: 0.6), value: window.remaining)
                .accessibilityLabel("\(window.title) usage remaining")
                .accessibilityValue("\(Int(window.remaining)) percent")
            if let reset = window.resetsAt { resetBadge(Date(timeIntervalSince1970: reset)) }
        }
        .padding(model.small ? 12 : 14)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.035), lineWidth: 1))
    }

    private func resetBadge(_ date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 8) {
                Image(systemName: "arrow.trianglehead.clockwise")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("RESETS").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(accent)
                    Text(date.formatted(.dateTime.month(.abbreviated).day()) + " · " + date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: model.small ? 10 : 12, weight: .semibold)).monospacedDigit()
                }
                Spacer(minLength: 0)
                Text(countdown(date, now: context.date))
                    .font(.system(size: model.small ? 9 : 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(accent.opacity(dark ? 0.16 : 0.09), in: Capsule())
            }
            .padding(9)
            .background(accent.opacity(dark ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .help("Resets " + date.formatted(date: .complete, time: .shortened))
        }
    }

    private func countdown(_ date: Date, now: Date) -> String {
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "Due now" }
        if minutes >= 1440 { return "in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "in \(minutes / 60)h \(minutes % 60)m" }
        return "in \(minutes)m"
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LOCAL SESSION").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                Text("3s sync").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.local.recordedAt == nil ? "—" : (model.small ? shortCount(model.local.total) : count(model.local.total)))
                    .font(.system(size: model.small ? 29 : 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1).help(count(model.local.total) + " tokens")
                Text("tokens").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !model.small {
                HStack(spacing: 8) {
                    metric("Input", model.local.input)
                    metric("Cached¹", model.local.cached)
                    metric("Output", model.local.output)
                }
                Text("¹ Cached tokens are included in input.").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let date = model.local.recordedAt {
                Text("Recorded " + date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            } else { Text("No recent local token records").font(.caption2).foregroundStyle(.secondary) }
        }.padding(model.small ? 12 : 14)
            .background(card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account lifetime").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(count(model.account?.summary?.lifetimeTokens)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Daily · " + (model.account?.latestDay?.startDate ?? "unavailable")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(count(model.account?.latestDay?.tokens)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }
            if let error = model.tokenError { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
            if let date = model.tokenDate {
                Text("Account tokens fetched " + date.formatted(date: .omitted, time: .standard)).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 4)
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let stale = model.limitDate.map { context.date.timeIntervalSince($0) > 90 } ?? true
            HStack(spacing: 5) {
                Circle().fill(stale || model.error != nil ? Color.orange : quotaColor(used: 0)).frame(width: 5, height: 5)
                Text(model.limitDate.map { "Limits updated " + $0.formatted(date: .omitted, time: .standard) } ?? "Waiting for account usage")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 4)
        }
    }

    private func metric(_ name: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(shortCount(value)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().help(count(value))
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(9).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.045), in: Circle())
    }
}
