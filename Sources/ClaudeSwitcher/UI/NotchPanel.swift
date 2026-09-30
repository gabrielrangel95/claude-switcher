import AppKit
import Combine
import SwiftUI

/// A borderless panel that sits over the notch (or top-center on screens without one).
/// Collapsed it shows the active account and 5-hour usage; hovering expands it into a
/// quick switcher.
@MainActor
final class NotchController: ObservableObject {
    @Published private(set) var isExpanded = false

    private var panel: NotchWindow?
    private let store: AccountStore
    private var collapseWork: DispatchWorkItem?
    private var screenObserver: Any?
    private var storeObserver: AnyCancellable?

    static let expandedSize = CGSize(width: 380, height: 0) // height is computed from content
    static let earWidth: CGFloat = 70

    init(store: AccountStore) {
        self.store = store
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? show() : hide()
    }

    private func show() {
        guard panel == nil else { return }
        let panel = NotchWindow()
        let root = NotchView(controller: self).environmentObject(store)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        layout(animated: false)
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layout(animated: false) }
        }
        // Expanded height depends on the number of accounts.
        storeObserver = store.$accounts.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout(animated: false) }
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        storeObserver = nil
    }

    func hover(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            guard !isExpanded else { return }
            isExpanded = true
            layout(animated: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isExpanded = false
                self.layout(animated: true)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    // MARK: Geometry

    static var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    struct Metrics {
        var notchWidth: CGFloat
        var barHeight: CGFloat
    }

    static func metrics(for screen: NSScreen) -> Metrics {
        let barHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, 24)
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return Metrics(notchWidth: screen.frame.width - left.width - right.width, barHeight: barHeight)
        }
        return Metrics(notchWidth: 0, barHeight: barHeight)
    }

    private func layout(animated: Bool) {
        guard let panel, let screen = Self.targetScreen else { return }
        let metrics = Self.metrics(for: screen)
        let size: CGSize
        if isExpanded {
            let rows = max(store.accounts.count, 1)
            size = CGSize(width: max(Self.expandedSize.width, metrics.notchWidth + 40),
                          height: metrics.barHeight + CGFloat(rows) * 58 + 20)
        } else {
            // Without a notch there is no gap to leave, so size the pill for label + percentage.
            let width = metrics.notchWidth > 0 ? metrics.notchWidth + Self.earWidth * 2 : 190
            size = CGSize(width: width, height: metrics.barHeight)
        }
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    var metrics: Metrics {
        Self.targetScreen.map(Self.metrics(for:)) ?? Metrics(notchWidth: 0, barHeight: 24)
    }
}

final class NotchWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Allow the window to sit in the menu bar area instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct NotchView: View {
    @EnvironmentObject var store: AccountStore
    @ObservedObject var controller: NotchController

    var body: some View {
        let metrics = controller.metrics
        VStack(spacing: 0) {
            collapsedBar(metrics: metrics)
            if controller.isExpanded {
                expandedContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: controller.isExpanded ? 22 : 12,
                                   bottomTrailingRadius: controller.isExpanded ? 22 : 12)
                .fill(.black)
        )
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover { controller.hover($0) }
        .animation(.easeInOut(duration: 0.2), value: controller.isExpanded)
    }

    private func collapsedBar(metrics: NotchController.Metrics) -> some View {
        let account = store.activeAccount
        let window = account.flatMap { store.usage[$0.id]?.usage?.fiveHour }
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                AccountDot(color: account?.color ?? .gray, size: 8)
                if controller.isExpanded || metrics.notchWidth == 0 {
                    Text(account?.label ?? "Claude").font(.caption.weight(.semibold)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)

            Color.clear.frame(width: metrics.notchWidth)

            Text(window.map { Format.percent($0.utilization) } ?? "—")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(window.map { usageTint($0.utilization) } ?? .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .foregroundStyle(.white)
        .frame(height: metrics.barHeight)
    }

    private var expandedContent: some View {
        VStack(spacing: 6) {
            if store.accounts.isEmpty {
                Text("Open the menu bar icon to add accounts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 50)
            }
            ForEach(store.accounts) { account in
                NotchAccountRow(account: account)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}

private struct NotchAccountRow: View {
    @EnvironmentObject var store: AccountStore
    let account: Account

    var body: some View {
        let isActive = store.activeID == account.id
        let usage = store.usage[account.id]?.usage
        HStack(spacing: 10) {
            AccountDot(color: account.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(account.label).font(.callout.weight(.semibold))
                    Spacer()
                    if let reset = usage?.fiveHour?.resetsAt {
                        Text("resets \(Format.relative(reset))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    UsageBar(title: "5h", window: usage?.fiveHour, compact: true)
                    UsageBar(title: "7d", window: usage?.sevenDay, compact: true)
                }
            }
            Group {
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(account.color)
                } else if store.switchingTo == account.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button { store.switchTo(account.id) } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Switch to \(account.label)")
                }
            }
            .font(.title3)
            .frame(width: 26)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(isActive ? 0.12 : 0.06)))
        .foregroundStyle(.white)
    }
}
