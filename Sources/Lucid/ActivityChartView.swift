import AppKit

/// Screensaver-style full-screen chart: a scrolling line graph of recent
/// CPU (and, on Apple Silicon, GPU) utilization plus the current
/// percentage as large text. One instance per screen
/// (`ActivityOverlayController` creates one window per `NSScreen`), all
/// fed the same samples.
final class ActivityChartView: NSView {

    /// How many samples the scrolling graph keeps on screen. At the
    /// sampler's 1-second interval this is 3 minutes of history.
    private static let historyCapacity = 180

    private static let cpuColor = NSColor.systemCyan
    private static let gpuColor = NSColor.systemOrange
    private static let backgroundColor = NSColor.black
    private static let gridColor = NSColor(white: 1, alpha: 0.08)

    /// Fonts plus their *measured* heights for the "CPU / 89%"-style
    /// legend, computed once per draw from `bounds` and shared between
    /// `chartFrame()` and `drawBigValue` so the chart's top inset always
    /// matches exactly how tall the legend actually rendered – guessing
    /// both independently as fixed fractions of `bounds.height` previously
    /// let the legend text overlap the chart on real font metrics, which
    /// don't scale as simply as the point size does.
    private struct LegendMetrics {
        let valueFont: NSFont
        let labelFont: NSFont
        let valueHeight: CGFloat
        let labelHeight: CGFloat
        let topMargin: CGFloat
        let gap: CGFloat

        var totalHeight: CGFloat { topMargin + labelHeight + gap + valueHeight }
    }

    private var cpuHistory: [Double] = []
    private var gpuHistory: [Double] = []
    private var hasGPU = false

    override var isFlipped: Bool { true }

    func append(_ sample: SystemActivitySample) {
        cpuHistory.append(sample.cpu)
        if cpuHistory.count > Self.historyCapacity {
            cpuHistory.removeFirst(cpuHistory.count - Self.historyCapacity)
        }
        if let gpu = sample.gpu {
            hasGPU = true
            gpuHistory.append(gpu)
            if gpuHistory.count > Self.historyCapacity {
                gpuHistory.removeFirst(gpuHistory.count - Self.historyCapacity)
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.backgroundColor.setFill()
        dirtyRect.fill()

        let metrics = legendMetrics()
        drawGrid(chartFrame(metrics))
        let chartRect = chartFrame(metrics)
        drawSeries(cpuHistory, color: Self.cpuColor, in: chartRect)
        if hasGPU {
            drawSeries(gpuHistory, color: Self.gpuColor, in: chartRect)
        }
        drawLegend(metrics)
    }

    private func legendMetrics() -> LegendMetrics {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: bounds.height * 0.11, weight: .thin)
        let labelFont = NSFont.systemFont(ofSize: bounds.height * 0.022, weight: .medium)
        // Measured from a representative fixed string ("100%"/"CPU")
        // rather than the actual current value, so the layout doesn't
        // shift by a pixel or two as the digit count/glyphs change from
        // sample to sample.
        let valueHeight = NSAttributedString(string: "100%", attributes: [.font: valueFont]).size().height
        let labelHeight = NSAttributedString(string: "CPU", attributes: [.font: labelFont]).size().height
        return LegendMetrics(
            valueFont: valueFont,
            labelFont: labelFont,
            valueHeight: valueHeight,
            labelHeight: labelHeight,
            topMargin: bounds.height * 0.06,
            gap: bounds.height * 0.015
        )
    }

    /// Leaves headroom at the top for the large current-value text (see
    /// `LegendMetrics`) so the graph itself doesn't run underneath it.
    private func chartFrame(_ metrics: LegendMetrics) -> NSRect {
        let topInset = metrics.totalHeight + bounds.height * 0.04
        let sideInset: CGFloat = bounds.width * 0.06
        let bottomInset: CGFloat = bounds.height * 0.08
        return NSRect(
            x: sideInset,
            y: topInset,
            width: bounds.width - sideInset * 2,
            height: bounds.height - topInset - bottomInset
        )
    }

    private func drawGrid(_ rect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1
        let horizontalLines = 4
        for i in 0...horizontalLines {
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(horizontalLines)
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
        }
        Self.gridColor.setStroke()
        path.stroke()
    }

    /// `history` holds fractions 0...1, oldest first; drawn right-aligned
    /// so the most recent sample is always at the chart's right edge,
    /// scrolling left as new samples arrive.
    private func drawSeries(_ history: [Double], color: NSColor, in rect: NSRect) {
        guard history.count > 1 else { return }

        let path = NSBezierPath()
        path.lineWidth = 2.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round

        let stepX = rect.width / CGFloat(Self.historyCapacity - 1)
        let startIndex = Self.historyCapacity - history.count

        for (offset, value) in history.enumerated() {
            let x = rect.minX + CGFloat(startIndex + offset) * stepX
            let y = rect.maxY - CGFloat(max(0, min(1, value))) * rect.height
            let point = NSPoint(x: x, y: y)
            if offset == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }

        color.setStroke()
        path.stroke()
    }

    private func drawLegend(_ metrics: LegendMetrics) {
        let cpuPercent = Int(round((cpuHistory.last ?? 0) * 100))
        drawBigValue(label: "CPU", percent: cpuPercent, color: Self.cpuColor, slot: 0, metrics: metrics)

        if hasGPU {
            let gpuPercent = Int(round((gpuHistory.last ?? 0) * 100))
            drawBigValue(label: "GPU", percent: gpuPercent, color: Self.gpuColor, slot: 1, metrics: metrics)
        }
    }

    /// Draws one "CPU / 89%"-style block: small caption above, big value
    /// below. `slot` 0 is left-of-center, 1 is right-of-center – laid out
    /// that way (rather than e.g. stacked) because a single, wide value
    /// reads more like a screensaver and less like a cramped dashboard.
    private func drawBigValue(label: String, percent: Int, color: NSColor, slot: Int, metrics: LegendMetrics) {
        let valueString = NSAttributedString(
            string: "\(percent)%",
            attributes: [.font: metrics.valueFont, .foregroundColor: color]
        )
        let labelString = NSAttributedString(
            string: label.uppercased(),
            attributes: [
                .font: metrics.labelFont,
                .foregroundColor: NSColor(white: 1, alpha: 0.55),
                .kern: 3.0
            ]
        )

        let blockWidth = bounds.width * 0.4
        let slotCount = hasGPU ? 2 : 1
        let totalWidth = blockWidth * CGFloat(slotCount)
        let originX = (bounds.width - totalWidth) / 2 + blockWidth * CGFloat(slot)
        let centerX = originX + blockWidth / 2

        let labelY = metrics.topMargin
        let valueY = labelY + metrics.labelHeight + metrics.gap

        labelString.draw(at: NSPoint(x: centerX - labelString.size().width / 2, y: labelY))
        valueString.draw(at: NSPoint(x: centerX - valueString.size().width / 2, y: valueY))
    }
}
