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

    /// Fraction of the *available margin* (see `randomizeDrift()`) the
    /// whole chart+legend composition actually uses when drifting, rather
    /// than the full margin – a fixed safety buffer so drift never quite
    /// touches the true edge.
    private static let driftMarginUsage: CGFloat = 0.8

    private var cpuHistory: [Double] = []
    private var gpuHistory: [Double] = []
    private var hasGPU = false
    private var driftOffset = CGPoint.zero

    override var isFlipped: Bool { true }

    /// Picks a new random on-screen position for the whole composition.
    /// `ActivityOverlayController` calls this periodically while showing
    /// (not just once) since a static position held for hours is exactly
    /// the burn-in risk this exists to avoid, not only the position it
    /// happens to start at.
    ///
    /// The range comes directly from the actual on-screen margins rather
    /// than an independently-guessed fraction of `bounds` – a first
    /// version used a flat ±3.5%, which turned out small enough in
    /// practice to be imperceptible at a glance (confirmed by forcing the
    /// two extremes and comparing pixel offsets), defeating the point. A
    /// second version derived it from `chartFrame`'s full top inset,
    /// which is wrong: that inset also contains the legend's own height,
    /// so treating all of it as free upward travel let the "CPU"/"GPU"
    /// caption drift clean off the top edge – confirmed the same way, by
    /// forcing the extremes and looking at the render. The legend's own
    /// `topMargin` (the small gap above the caption, not the whole
    /// reserved band) is the real upward bound; `bottomInset` is the real
    /// downward one, and `drawBigValue` now aligns the legend horizontally
    /// to `chartFrame` exactly, so `sideInset` bounds both consistently.
    func randomizeDrift() {
        let metrics = legendMetrics()
        let frame = chartFrame(metrics)
        let horizontalMargin = frame.minX
        let verticalMargin = min(metrics.topMargin, bounds.height - frame.maxY)

        let maxDx = horizontalMargin * Self.driftMarginUsage
        let maxDy = verticalMargin * Self.driftMarginUsage
        driftOffset = CGPoint(x: .random(in: -maxDx...maxDx), y: .random(in: -maxDy...maxDy))
        needsDisplay = true
    }

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

        // Everything but the full-bleed background fill above shifts by
        // `driftOffset` – translating the whole coordinate space once
        // here is simpler and less error-prone than adding the offset to
        // every rect/point computed below individually.
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.translateBy(x: driftOffset.x, y: driftOffset.y)

        let metrics = legendMetrics()
        let chartRect = chartFrame(metrics)
        drawGrid(chartRect)
        drawSeries(cpuHistory, color: Self.cpuColor, in: chartRect)
        if hasGPU {
            drawSeries(gpuHistory, color: Self.gpuColor, in: chartRect)
        }
        drawLegend(metrics, chartRect: chartRect)
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
            // Matches chartFrame's bottomInset so randomizeDrift() gets an
            // equally generous, symmetric range in both directions – this
            // is also the actual upward drift bound (see randomizeDrift's
            // doc comment), not just a layout margin.
            topMargin: bounds.height * 0.14,
            gap: bounds.height * 0.015
        )
    }

    /// Leaves headroom at the top for the large current-value text (see
    /// `LegendMetrics`), and generous side/bottom margins – beyond just
    /// visual breathing room, `randomizeDrift()` derives how far the
    /// whole composition is allowed to wander from exactly these margins,
    /// so they double as the drift range.
    private func chartFrame(_ metrics: LegendMetrics) -> NSRect {
        let topInset = metrics.totalHeight + bounds.height * 0.04
        let sideInset: CGFloat = bounds.width * 0.14
        let bottomInset: CGFloat = bounds.height * 0.14
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

    private func drawLegend(_ metrics: LegendMetrics, chartRect: NSRect) {
        let cpuPercent = Int(round((cpuHistory.last ?? 0) * 100))
        drawBigValue(label: "CPU", percent: cpuPercent, color: Self.cpuColor, slot: 0, metrics: metrics, chartRect: chartRect)

        if hasGPU {
            let gpuPercent = Int(round((gpuHistory.last ?? 0) * 100))
            drawBigValue(label: "GPU", percent: gpuPercent, color: Self.gpuColor, slot: 1, metrics: metrics, chartRect: chartRect)
        }
    }

    /// Draws one "CPU / 89%"-style block: small caption above, big value
    /// below. `slot` 0 is left-of-center, 1 is right-of-center – laid out
    /// that way (rather than e.g. stacked) because a single, wide value
    /// reads more like a screensaver and less like a cramped dashboard.
    ///
    /// Each slot's width is a fraction of `chartRect`'s width (not an
    /// independently guessed fraction of `bounds`), so the legend's own
    /// left/right edges land exactly on the chart's – otherwise, with two
    /// slots, the legend's own margin could end up *tighter* than the
    /// chart's `sideInset`, which `randomizeDrift()` assumes bounds both.
    private func drawBigValue(label: String, percent: Int, color: NSColor, slot: Int, metrics: LegendMetrics, chartRect: NSRect) {
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

        let slotCount = hasGPU ? 2 : 1
        let blockWidth = chartRect.width / CGFloat(slotCount)
        let centerX = chartRect.minX + blockWidth * (CGFloat(slot) + 0.5)

        let labelY = metrics.topMargin
        let valueY = labelY + metrics.labelHeight + metrics.gap

        labelString.draw(at: NSPoint(x: centerX - labelString.size().width / 2, y: labelY))
        valueString.draw(at: NSPoint(x: centerX - valueString.size().width / 2, y: valueY))
    }
}
