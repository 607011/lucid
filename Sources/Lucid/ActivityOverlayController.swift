import AppKit

/// Screensaver-style alternative to `DisplayController.sleepNow()` /
/// `DisplayDimController`: instead of turning displays off or down, shows
/// a full-screen, borderless CPU/GPU activity chart on every screen. The
/// display never actually sleeps or dims here, so there's nothing for
/// `NSWorkspace.screensDidWakeNotification` to fire on – like "Dim
/// Display", restoring (i.e. closing the overlay) relies on
/// `IdleActivityMonitor` instead (wired up in `AppDelegate`).
final class ActivityOverlayController {

    private(set) var isShowing = false

    private var windows: [NSWindow] = []
    private var chartViews: [ActivityChartView] = []
    private let sampler = SystemActivitySampler()

    func show() {
        guard !isShowing else { return }
        isShowing = true

        for screen in NSScreen.screens {
            let chartView = ActivityChartView(frame: NSRect(origin: .zero, size: screen.frame.size))

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
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false

        sampler.stop()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        chartViews.removeAll()
    }
}
