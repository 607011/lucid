import AppKit

/// Screensaver-style alternative to `DisplayController.sleepNow()` /
/// `DisplayDimController`: instead of turning displays off or down, shows
/// a full-screen, borderless CPU/GPU activity chart on every screen. The
/// display never actually sleeps or dims here, so there's nothing for
/// `NSWorkspace.screensDidWakeNotification` to fire on – like "Dim
/// Display", restoring (i.e. closing the overlay) relies on
/// `IdleActivityMonitor` instead (wired up in `AppDelegate`).
final class ActivityOverlayController {

    /// How often each screen's chart picks a new random on-screen
    /// position (`ActivityChartView.randomizeDrift()`) while showing –
    /// burn-in mitigation for content that could otherwise sit in one
    /// spot for hours. Slow enough to not be distracting/look like
    /// flicker, frequent enough that no single position is held for long.
    private static let driftInterval: TimeInterval = 20

    private(set) var isShowing = false

    private var windows: [NSWindow] = []
    private var chartViews: [ActivityChartView] = []
    private let sampler = SystemActivitySampler()
    private var driftTimer: Timer?

    func show() {
        guard !isShowing else { return }
        isShowing = true

        for screen in NSScreen.screens {
            let chartView = ActivityChartView(frame: NSRect(origin: .zero, size: screen.frame.size))
            chartView.randomizeDrift()

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = true
            window.backgroundColor = .black
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.contentView = chartView
            window.orderFrontRegardless()

            windows.append(window)
            chartViews.append(chartView)
        }

        sampler.start { [weak self] sample in
            guard let self else { return }
            for chartView in self.chartViews {
                chartView.append(sample)
            }
        }

        // Each screen's chart drifts independently (not the same offset
        // mirrored across every screen) – no correctness reason to keep
        // them in sync, and independent movement reads less mechanical.
        driftTimer = Timer.scheduledTimer(withTimeInterval: Self.driftInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            for chartView in self.chartViews {
                chartView.randomizeDrift()
            }
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false

        sampler.stop()
        driftTimer?.invalidate()
        driftTimer = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        chartViews.removeAll()
    }
}
