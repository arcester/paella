import PaellaCore
import Charts
import SwiftUI

struct PaellaApp: App {
    @State private var model = AppModel(dryRun: CommandLine.arguments.contains("--dry-run"))
    @AppStorage(Key.menuBarTemp) private var menuBarIcon = "smoothed"
    @AppStorage(Key.menuBarPower) private var showPower = true
    @AppStorage(Key.menuBarIndicator) private var indicator = "always"
    @AppStorage(Key.menuBarWeight) private var weight = "regular"
    @AppStorage(Key.tempUnit) private var tempUnit = "auto" // re-renders the label when the unit changes

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // The menu bar shows only the label's first image, so dot, pan and values are drawn into one.
            let text = model.menuLabel.trimmingCharacters(in: .whitespaces)
            let power = showPower ? model.power.map { "\(dec($0)) W" } : nil
            let p = model.pressure
            Image(nsImage: .menuBarLabel(dot: indicator == "always" || (indicator == "alert" && p != .none) ? p.color : nil,
                                         color: indicator == "text" && p != .none ? p.color : .labelColor,
                                         weight: NSFont.Weight(menuBarWeight: weight),
                                         pan: menuBarIcon == "pan", lines: [text.isEmpty ? nil : text, power].compactMap { $0 }))
                .accessibilityLabel([model.pressure.label, text, power ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsView(model: model)
        }
    }
}

extension NSFont.Weight {
    init(menuBarWeight: String) {
        self = switch menuBarWeight {
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        default: .regular
        }
    }
}

extension AppModel.Pressure {
    var color: NSColor {
        switch self {
        case .none: .systemGreen
        case .limiting: .systemOrange
        case .atLimit: .systemRed
        }
    }

    var label: String {
        switch self {
        case .none: String(localized: "Nada limitado")
        case .limiting: String(localized: "Limitando procesos")
        case .atLimit: String(localized: "Al límite")
        }
    }
}

extension NSImage {
    /// Menu bar label: traffic-light dot, optional pan, then one or two lines of values.
    /// Not a template (the dot keeps its colour), so the rest is drawn in labelColor, resolved at draw time
    /// against the menu bar's own appearance. Lines are laid out on cap height, not line height: digits have
    /// no descenders, so 11.5 pt fits two lines in 22.
    static func menuBarLabel(dot: NSColor?, color: NSColor, weight: NSFont.Weight, pan: Bool, lines: [String]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: lines.count > 1 ? 11.5 : 13, weight: weight)
        let measure: [NSAttributedString.Key: Any] = [.font: font]
        let sizes = lines.map { ($0 as NSString).size(withAttributes: measure) }
        let textWidth = ceil(sizes.map(\.width).max() ?? 0)
        let height: CGFloat = 22, gap: CGFloat = 3, dotSize: CGFloat = 7
        let panWidth = pan ? paellaTemplate.size.width : 0
        let panX = dot == nil ? 0 : dotSize + 4, textX = panX + (pan ? panWidth + (lines.isEmpty ? 0 : 4) : 0)
        let block = font.capHeight * CGFloat(lines.count) + gap * CGFloat(max(lines.count - 1, 0))
        return NSImage(size: NSSize(width: textX + textWidth, height: height), flipped: true) { _ in
            if let dot {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: (height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
            }
            if pan {
                let r = NSRect(x: panX, y: (height - paellaTemplate.size.height) / 2, width: panWidth, height: paellaTemplate.size.height)
                paellaTemplate.tinted(color).draw(in: r)
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            var baseline = (height - block) / 2 + font.capHeight
            for (line, size) in zip(lines, sizes) {
                (line as NSString).draw(at: NSPoint(x: textX + textWidth - size.width, y: baseline - font.ascender), withAttributes: attrs)
                baseline += font.capHeight + gap
            }
            return true
        }
    }

    /// A template image filled with `color` (its alpha kept).
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { [self] rect in
            draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// Monochrome pan for the menu bar: rim, sloped wall, handles; the rice is a lighter fill.
    static let paellaTemplate: NSImage = {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            let wall = NSBezierPath(ovalIn: NSRect(x: 5.5, y: 7.5, width: 11, height: 4))
            wall.append(NSBezierPath(rect: NSRect(x: 5.5, y: 7, width: 11, height: 2.5)))
            wall.fill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 4, width: 16, height: 6.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 4.5, y: 5.2, width: 13, height: 4.1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(ovalIn: NSRect(x: 4.5, y: 5.2, width: 13, height: 4.1)).fill()
            NSColor.black.setStroke()
            for x in [0.6, 18.4] {
                let h = NSBezierPath(ovalIn: NSRect(x: x, y: 5.6, width: 3, height: 2.6))
                h.lineWidth = 1.3
                h.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Key.enabled) private var enabled = true
    @AppStorage(Key.target) private var target = 82.0
    @AppStorage(Key.dutyMin) private var dutyMin = 0.3
    @AppStorage(Key.period) private var period = 0.2
    @AppStorage(Key.eCoresFirst) private var eCoresFirst = true
    @AppStorage(Key.autoRefresh) private var autoRefresh = true
    @AppStorage(Key.tempUnit) private var tempUnit = "auto" // re-renders when the unit changes
    @State private var menuWindow: NSWindow?
    @State private var rowCapacity = MenuBarView.minRows
    @State private var hoverTime: Date?
    @AppStorage(Key.refreshInterval) private var refreshInterval = 10.0
    @AppStorage(Key.listWindow) private var listWindow = 10.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            summary.padding(.top, 12)
            control.padding(.top, 12)
            processList
        }
        .padding(14)
        .frame(width: 380)
        .background(WindowVisibility(onChange: { visible in model.menuVisible = visible },
                                     onWindow: { menuWindow = $0; fitRows() }))
        .onChange(of: model.monitored.count) { fitRows() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            Text("Paella").font(.title3.weight(.semibold))
            if model.dryRun { Text("SIMULACIÓN").font(.caption.bold()).foregroundStyle(.orange) }
            Spacer()
            HStack(spacing: 14) {
                ToolbarButton(symbol: "gearshape", help: "Ajustes…") {
                    NSApp.keyWindow?.close() // the menu panel is key while open
                    NSApp.activate() // menu bar apps must come forward or the window opens behind others
                    model.settingsTab = "general"
                    openSettings()
                }
                ToolbarButton(symbol: "power", help: "Salir") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(.separator))
        }
    }

    // MARK: Control

    private var control: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cross-fade in the same space: the menu bar window doesn't follow height changes.
            ZStack {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledSlider(title: "Objetivo", value: $target, range: 65...95, step: 1,
                                  format: { temp($0) }, caption: targetCaption, info: targetInfo)
                    Divider()
                    LabeledSlider(title: "Ciclo de trabajo mínimo", value: $dutyMin, range: 0.1...1, step: 0.05,
                                  format: { "\(Int(($0 * 100).rounded())) %" }, caption: dutyCaption, info: dutyInfo)
                }
                .opacity(enabled ? 1 : 0)
                .allowsHitTesting(enabled)
                .accessibilityHidden(!enabled)
                VStack(spacing: 6) {
                    Image(systemName: "pause.circle").font(.largeTitle)
                    Text("Ningún proceso está limitado.\nActiva el control automático para ajustar el objetivo.")
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .opacity(enabled ? 0 : 1)
                .accessibilityHidden(enabled)
            }
            .padding(.vertical, 10)
            // Keyed on the value, not the toggle's binding: @AppStorage changes arrive via UserDefaults,
            // outside the binding's transaction, so a binding animation never ran.
            .animation(.easeInOut(duration: 0.8), value: enabled)
        }
        .padding(.horizontal, 12)
        .outlinedBox()
    }

    // MARK: Header

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(model.sample.map { temp($0.dieSmoothed, 1) } ?? "–")
                    .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Toggle(isOn: $enabled) {
                        Text("Control automático").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Pasa los procesos pesados a los núcleos de eficiencia y los pausa a intervalos")
                    .onChange(of: enabled) { _, on in if !on { model.resumeAll() } } // release now, not at next tick
                    StateBadge(text: status.text, color: status.color)
                }
            }
            if model.sample?.usingFallback == true {
                Label("Sin sensores: temperatura aproximada", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Ningún sensor HID coincide con los filtros; se usa el estado térmico de macOS")
            }
            HStack(alignment: .top) {
                stat("Máx. chip", model.sample.map { temp($0.dieMax, 1) })
                stat("Potencia", model.power.map { "\(dec($0)) W" })
                stat("Sensores", model.sample.map { "\($0.matchedSensors)" })
            }
            sparkline
        }
        .padding(12)
        .outlinedBox()
    }

    private func stat(_ title: LocalizedStringKey, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "–").font(.callout.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: (text: String, color: Color) {
        if !enabled { return (String(localized: "Control automático desactivado"), .secondary) }
        if model.lowPowerModeEngaged { return (String(localized: "Modo de bajo consumo (último recurso)"), .red) }
        if model.throttling && !model.targets.isEmpty {
            return model.duty < 1
                ? (String(localized: "Limitados al \(percent(model.duty)) del tiempo"), .orange)
                : (String(localized: "Limitados a los núcleos de eficiencia"), .orange)
        }
        return (String(localized: "Nada limitado"), .green)
    }

    /// The history sample nearest the pointer, while hovering either chart.
    private var hovered: HistoryPoint? {
        guard let t = hoverTime else { return nil }
        return model.history.min { abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t)) }
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 14) { // room for the edge axis labels of both charts
            Chart {
                ForEach(model.history) { p in
                    LineMark(x: .value("t", p.time), y: .value("°", displayTemp(p.dieMax)), series: .value("s", "máx. chip"))
                        .foregroundStyle(.orange.opacity(0.5))
                }
                ForEach(model.history) { p in
                    LineMark(x: .value("t", p.time), y: .value("°", displayTemp(p.smoothed)), series: .value("s", "suavizada"))
                        .foregroundStyle(.red)
                }
                RuleMark(y: .value("objetivo", displayTemp(target))).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [3, 3]))
                if let h = hovered {
                    RuleMark(x: .value("t", h.time)).foregroundStyle(.secondary.opacity(0.6))
                    PointMark(x: .value("t", h.time), y: .value("°", displayTemp(h.dieMax))).foregroundStyle(.orange).symbolSize(20)
                    PointMark(x: .value("t", h.time), y: .value("°", displayTemp(h.smoothed))).foregroundStyle(.red).symbolSize(20)
                }
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis { Self.axis { "\(Int($0)) \(TempUnit.symbol)" } }
            .chartOverlay(content: hoverTracker)
            .frame(height: 60)
            if model.history.contains(where: { $0.power != nil }) {
                Chart {
                    ForEach(model.history) { p in
                        if let w = p.power {
                            AreaMark(x: .value("t", p.time), y: .value("W", w)).foregroundStyle(.blue.opacity(0.15))
                            LineMark(x: .value("t", p.time), y: .value("W", w)).foregroundStyle(.blue)
                        }
                    }
                    if let h = hovered {
                        RuleMark(x: .value("t", h.time)).foregroundStyle(.secondary.opacity(0.6))
                        if let w = h.power { PointMark(x: .value("t", h.time), y: .value("W", w)).foregroundStyle(.blue).symbolSize(20) }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis { Self.axis(count: 2) { "\(Int($0)) W" } }
                .chartOverlay(content: hoverTracker)
                .frame(height: 36)
            }
            if let h = hovered { readout(h) } else { legend }
        }
    }

    /// Maps the pointer to a time on the plot, shared by both charts so their rules move together.
    private func hoverTracker(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let loc) = phase, let plot = proxy.plotFrame else { hoverTime = nil; return }
                    hoverTime = proxy.value(atX: loc.x - geo[plot].minX, as: Date.self)
                }
        }
    }

    /// Replaces the legend while hovering: the values under the pointer, in each line's colour.
    private func readout(_ p: HistoryPoint) -> some View {
        HStack(spacing: 12) {
            Text(p.time, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
            Text(temp(p.smoothed, 1)).foregroundStyle(.red)
            Text(temp(p.dieMax, 1)).foregroundStyle(.orange)
            if let w = p.power { Text("\(dec(w, 1)) W").foregroundStyle(.blue) }
            Spacer(minLength: 0)
        }
        .font(.caption2.monospacedDigit())
    }

    /// Trailing y-axis with fixed-width labels, so both charts' plot areas line up in time.
    static func axis(count: Int = 3, _ label: @escaping (Double) -> String) -> some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: count)) { v in
            AxisGridLine()
            AxisValueLabel {
                if let d = v.as(Double.self) { Text(label(d)).frame(width: 40, alignment: .leading) } // fits "100 °F"
            }
        }
    }

    private var legend: some View {
        // One line always: the time span is dropped first when a language's labels don't fit.
        ViewThatFits(in: .horizontal) {
            legendRow(span: true)
            legendRow(span: false)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendRow(span: Bool) -> some View {
        HStack(spacing: 12) {
            legendItem("Suavizada", .red)
            legendItem("Máx. chip", .orange.opacity(0.5))
            legendItem("Objetivo", .secondary, dashed: true)
            if model.power != nil { legendItem("Potencia", .blue) }
            Spacer(minLength: 0)
            if span { Text("últimos 10 min").foregroundStyle(.tertiary).fixedSize() }
        }
    }

    private func legendItem(_ title: LocalizedStringKey, _ color: some ShapeStyle, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Path { $0.move(to: CGPoint(x: 0, y: 1)); $0.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 3] : []))
                .frame(width: 14, height: 2)
            Text(title).fixedSize()
        }
    }

    // MARK: Explanations

    private var targetCaption: String {
        let base = String(localized: "Temperatura media que la app intenta no superar.")
        return model.sample.map { base + " " + String(localized: "Ahora: \(temp($0.dieSmoothed)).") } ?? base
    }

    private var targetInfo: String {
        let t = Int(target)
        let eCores = eCoresFirst
            ? String(localized: "• Desde \(temp(Double(t - 2))): los procesos pesados pasan a los núcleos de eficiencia (más lentos y fríos).") + "\n"
            : ""
        return String(localized: """
        Se mide la temperatura más alta del chip y se promedia durante ~1 minuto: el calor del chasis depende de la potencia sostenida, no de los picos de unos segundos.

        • Por debajo de \(temp(Double(t - 2))): no se limita nada.
        \(eCores)• Por encima de \(temp(Double(t))): además se pausan a intervalos, más cuanto más se supere.

        Más alto = más rendimiento y chasis más caliente. Más bajo = más fresco y más lento.
        """)
    }

    private var dutyCaption: String {
        dutyMin >= 0.999
            ? String(localized: "Los procesos nunca se pausan; solo se pasan a los núcleos de eficiencia.")
            : String(localized: "Un proceso limitado funcionará al menos el \(percent(dutyMin)) del tiempo: como mucho \(dec(1 / dutyMin)) veces más lento.")
    }

    private var dutyInfo: String {
        let ms = Int((clamp(period, Limits.period) * 1000).rounded())
        return String(localized: """
        Para enfriar sin cerrar nada, la app pausa y reanuda los procesos pesados muchas veces por segundo: en cada ciclo de \(ms) ms funcionan una parte y están pausados el resto. Esa parte es el ciclo de trabajo, y la app la ajusta sola cada 2 s según la temperatura.

        Este ajuste es el suelo: por mucho calor que haga, nunca baja de \(percent(dutyMin)). Solo importa si, incluso en el mínimo, la temperatura sigue por encima del objetivo (el punto de la barra de menús se pondrá rojo).

        Más bajo = más frío pero el trabajo tarda más. Más alto = avanza más rápido pero se calienta más. El paso a núcleos de eficiencia se suma a esto, así que la ralentización real puede ser mayor.
        """)
    }

    // MARK: Process list

    static let minRows = 6
    static let maxRows = 12
    static let rowStep = rowHeight
    static let rowHeight: CGFloat = 40

    private var processList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionCaption("Procesos que más exigen · media de \(Int(clamp(listWindow, Limits.listWindow))) min")
                Spacer()
                SectionCaption("Ilimitado")
            }
            VStack(alignment: .leading, spacing: 0) {
            if model.monitored.isEmpty {
                Text("Nada exigente ahora mismo").font(.caption).foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight)
                    .transition(.opacity)
            }
            ForEach(Array(model.monitored.prefix(rowCapacity).enumerated()), id: \.element.id) { i, m in
                HStack(spacing: 10) {
                    AppIcon(group: m.group, system: m.state == .system)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(m.group.name).fontWeight(.semibold).lineLimit(1)
                                .foregroundStyle(m.state == .system ? .secondary : .primary)
                            StateBadge(text: badgeText(m.state), color: badgeColor(m.state))
                        }
                        Text(m.active ? usage(m) : usage(m) + " · " + String(localized: "Sin actividad ahora"))
                            .lineLimit(1)
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Toggle("Ilimitado", isOn: Binding(
                        get: { m.state == .unlimited || m.state == .system }, // system rows are never limited anyway
                        set: { model.setUnlimited(m.group, $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .disabled(m.state == .system)
                        .help(m.state == .system ? String(localized: "Componente del sistema: nunca se limita") : String(localized: "Ilimitado: nunca se limitará (se recuerda por nombre)"))
                }
                .frame(height: Self.rowHeight)
                .overlay(alignment: .top) { if i > 0 { Divider().padding(.leading, 32) } }
                .transition(.opacity)
            }
            }
            .animation(.easeInOut(duration: 0.8), value: model.monitored.map(\.id))
            .task(id: "\(autoRefresh)-\(refreshInterval)") {
                while autoRefresh, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(clamp(refreshInterval, Limits.refreshInterval)))
                    if autoRefresh { model.refreshProcessList() }
                }
            }
            // Room for 6 rows at least; more (up to 12) only when there are processes for them and the screen allows.
            .frame(height: CGFloat(rowCapacity) * Self.rowStep, alignment: .top)
            .clipped() // while rows cross-fade, leaving and arriving rows are both laid out: up to 12 for a moment
            .padding(.horizontal, 12)
            .outlinedBox()
            Text("Activa el interruptor de un proceso para marcarlo como ilimitado: la app no lo limitará nunca y se recuerda para la próxima vez.")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2...3).fixedSize(horizontal: false, vertical: true) // 3 for German
                .padding(.horizontal, 2).padding(.top, 6)
        }
    }

    /// Grows or shrinks the list to fit the processes, within what the screen below the menu bar allows.
    /// The menu window doesn't follow content size, so it is resized here, top edge fixed, in step with the rows.
    private func fitRows() {
        guard let w = menuWindow, let screen = w.screen else { return }
        let f = w.frame
        let heightAtMin = f.height - CGFloat(rowCapacity - Self.minRows) * Self.rowStep
        let room = f.maxY - screen.visibleFrame.minY - 12 - heightAtMin
        let fit = Self.minRows + max(0, Int(room / Self.rowStep))
        let rows = min(max(model.monitored.count, Self.minRows), fit, Self.maxRows)
        guard rows != rowCapacity else { return }
        let height = f.height + CGFloat(rows - rowCapacity) * Self.rowStep
        withAnimation(.easeInOut(duration: 0.8)) { rowCapacity = rows }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.8
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height), display: true)
        }
    }

    private func usage(_ m: MonitoredGroup) -> String {
        let gpu = m.gpu.map { String(format: " · GPU %.0f %%", $0 * 100) } ?? ""
        return String(format: "CPU %.0f %%", m.cpu * 100) + gpu
    }

    private func badgeText(_ s: ProcessState) -> String {
        switch s {
        case .limited: model.duty < 1 ? String(localized: "Limitado \(percent(model.duty))") : String(localized: "Limitado")
        case .unlimited: String(localized: "Ilimitado")
        case .foreground: String(localized: "Primer plano")
        case .system: String(localized: "Sistema")
        case .normal: String(localized: "Sin limitar")
        }
    }

    private func badgeColor(_ s: ProcessState) -> Color {
        switch s {
        case .limited: .orange
        case .unlimited: .green
        case .foreground: .blue
        case .system, .normal: .secondary
        }
    }
}

/// Slider binding that rounds to `step` itself: a stepped Slider draws a tick per step, too many to read.
func snapped(_ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double) -> Binding<Double> {
    Binding(get: { clamp(value.wrappedValue, range) },
            set: { value.wrappedValue = clamp(range.lowerBound + (($0 - range.lowerBound) / step).rounded() * step, range) })
}

func percent(_ x: Double) -> String { "\(Int((x * 100).rounded())) %" }

/// Decimal in the user's locale: 68,2 / 68.2.
func dec(_ x: Double, _ digits: Int = 1) -> String {
    x.formatted(.number.precision(.fractionLength(digits)))
}

/// Reports whether the hosting window (the menu) is on screen.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onChange = onChange
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ v: ObserverView, context: Context) { v.onChange = onChange; v.onWindow = onWindow }

    final class ObserverView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        var onWindow: (@MainActor (NSWindow?) -> Void)?
        private var timer: Timer?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            timer = nil
            report()
            Task { @MainActor [onWindow, window] in onWindow?(window) }
            guard window != nil else { return }
            // Polling isVisible: occlusionState proved unreliable here, and there is no order-out notification.
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            RunLoop.main.add(t, forMode: .common) // keeps firing while the menu is tracking
            timer = t
        }

        private func report() {
            let visible = window?.isVisible == true
            guard visible != last else { return }
            last = visible
            // Defer: this can run during a SwiftUI update pass.
            Task { @MainActor [onChange] in onChange?(visible) }
        }
    }
}

/// Small caption over a section's box, as in Connecter.
private struct SectionCaption: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 2).padding(.top, 14).padding(.bottom, 6)
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel(Text(help))
    }
}

/// The app's own icon; a symbol for system components and command-line tools.
private struct AppIcon: View {
    let group: TargetGroup
    let system: Bool

    var body: some View {
        Group {
            if let path = group.bundles.min() {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: system ? "gearshape" : "terminal").foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Flat panel with a hairline border, the container style shared with Connecter.
    func outlinedBox(cornerRadius: CGFloat = 8) -> some View {
        background(.background.secondary, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator))
    }
}

private struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}

private struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let caption: String
    let info: String
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help("Cómo funciona")
                    .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                        Text(info).font(.callout).padding(14).frame(width: 320).fixedSize(horizontal: false, vertical: true)
                    }
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: snapped($value, range, step), in: range)
            // Always two lines tall: the menu window must never change height (it repaints badly when it does).
            Text(caption).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
        }
    }
}
