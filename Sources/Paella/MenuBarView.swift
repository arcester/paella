import PaellaCore
import Charts
import SwiftUI

struct PaellaApp: App {
    @State private var model = AppModel(dryRun: CommandLine.arguments.contains("--dry-run"))
    @AppStorage(Key.menuBarTemp) private var menuBarIcon = "smoothed"

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            if menuBarIcon == "pan" {
                Image(nsImage: .paellaTemplate)
                    .accessibilityLabel("Paella")
            }
            Text(model.menuLabel.trimmingCharacters(in: .whitespaces)).monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsView(model: model)
        }
    }
}

extension NSImage {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sparkline
            Toggle(isOn: $enabled.animation(.easeInOut(duration: 1.5))) {
                Text("Control automático").font(.headline)
            }
            .toggleStyle(.switch)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .onChange(of: enabled) { _, on in if !on { model.resumeAll() } } // release now, not at next tick
            Divider()
            // Cross-fade in the same space: the menu bar window doesn't follow height changes.
            ZStack {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledSlider(title: "Objetivo", value: $target, range: 65...95, step: 1,
                                  format: { "\(Int($0)) °C" }, caption: targetCaption, info: targetInfo)
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
            Divider()
            processList
            Divider()
            HStack {
                Button("Ajustes…") {
                    NSApp.keyWindow?.close() // the menu panel is key while open
                    NSApp.activate() // menu bar apps must come forward or the window opens behind others
                    model.settingsTab = "general"
                    openSettings()
                }
                if model.dryRun { Text("SIMULACIÓN").font(.caption.bold()).foregroundStyle(.orange) }
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(WindowVisibility { visible in model.menuVisible = visible })
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.sample.map { "\(dec($0.dieSmoothed)) °C" } ?? "–")
                    .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                VStack(alignment: .leading) {
                    if model.sample?.usingFallback == true {
                        Label("Sin sensores: temperatura aproximada", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Ningún sensor HID coincide con los filtros; se usa el estado térmico de macOS")
                    } else {
                        Text(model.sample.map { String(localized: "máx. chip \(dec($0.dieMax)) °C · \($0.matchedSensors) sensores") } ?? " ")
                    }
                    Text(status.text).foregroundStyle(status.color)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
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

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(model.history) { p in
                    LineMark(x: .value("t", p.time), y: .value("°C", p.dieMax), series: .value("s", "máx. chip"))
                        .foregroundStyle(.orange.opacity(0.5))
                }
                ForEach(model.history) { p in
                    LineMark(x: .value("t", p.time), y: .value("°C", p.smoothed), series: .value("s", "suavizada"))
                        .foregroundStyle(.red)
                }
                RuleMark(y: .value("objetivo", target)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [3, 3]))
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 60)
            .help("Últimos 10 minutos")
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("Suavizada", .red)
            legendItem("Máx. chip", .orange.opacity(0.5))
            legendItem("Objetivo", .secondary, dashed: true)
            Spacer()
            Text("últimos 10 min").foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ title: LocalizedStringKey, _ color: some ShapeStyle, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Path { $0.move(to: CGPoint(x: 0, y: 1)); $0.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 3] : []))
                .frame(width: 14, height: 2)
            Text(title)
        }
    }

    // MARK: Explanations

    private var targetCaption: String {
        let base = String(localized: "Temperatura media que la app intenta no superar.")
        return model.sample.map { base + " " + String(localized: "Ahora: \(dec($0.dieSmoothed, 0)) °C.") } ?? base
    }

    private var targetInfo: String {
        let t = Int(target)
        let eCores = eCoresFirst
            ? String(localized: "• Desde \(t - 2) °C: los procesos pesados pasan a los núcleos de eficiencia (más lentos y fríos).") + "\n"
            : ""
        return String(localized: """
        Se mide la temperatura más alta del chip y se promedia durante ~1 minuto: el calor del chasis depende de la potencia sostenida, no de los picos de unos segundos.

        • Por debajo de \(t - 2) °C: no se limita nada.
        \(eCores)• Por encima de \(t) °C: además se pausan a intervalos, más cuanto más se supere.

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

        Este ajuste es el suelo: por mucho calor que haga, nunca baja de \(percent(dutyMin)). Solo importa si, incluso en el mínimo, la temperatura sigue por encima del objetivo (verás ▼\(percent(dutyMin)) fijo en la barra de menús).

        Más bajo = más frío pero el trabajo tarda más. Más alto = avanza más rápido pero se calienta más. El paso a núcleos de eficiencia se suma a esto, así que la ralentización real puede ser mayor.
        """)
    }

    // MARK: Process list

    static let maxRows = 6
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 6

    private var processList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Procesos que más exigen").font(.headline)
                Button { model.refreshProcessList() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Actualizar la lista. Mientras el menú está abierto no entran ni salen procesos solos.")
                Spacer()
                Text("Ilimitado").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
            if model.monitored.isEmpty {
                Text("Nada exigente ahora mismo").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.monitored.prefix(Self.maxRows)) { m in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.group.name).lineLimit(1)
                        Text(m.active ? usage(m.group) : String(localized: "Sin actividad ahora"))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    StateBadge(text: badgeText(m.state), color: badgeColor(m.state))
                    Toggle("Ilimitado", isOn: Binding(
                        get: { m.state == .unlimited },
                        set: { model.setUnlimited(m.group, $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.green)
                        .disabled(m.state == .system)
                        .help(m.state == .system ? String(localized: "Componente del sistema: nunca se limita") : String(localized: "Ilimitado: nunca se limitará (se recuerda por nombre)"))
                }
                .frame(height: Self.rowHeight)
            }
            }
            // Fixed height for 6 rows, whatever the list holds: no window resizing.
            .frame(height: CGFloat(Self.maxRows) * Self.rowHeight + CGFloat(Self.maxRows - 1) * Self.rowSpacing, alignment: .top)
            Text("Activa «Ilimitado» para que la app no limite nunca ese proceso; se recuerda para la próxima vez.")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func usage(_ g: TargetGroup) -> String {
        let gpu = g.gpu.map { String(format: " · GPU %.0f %%", $0 * 100) } ?? ""
        return String(format: "CPU %.0f %%", g.cpu * 100) + gpu
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

func percent(_ x: Double) -> String { "\(Int((x * 100).rounded())) %" }

/// Decimal in the user's locale: 68,2 / 68.2.
func dec(_ x: Double, _ digits: Int = 1) -> String {
    x.formatted(.number.precision(.fractionLength(digits)))
}

/// Reports whether the hosting window (the menu) is on screen.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: ObserverView, context: Context) { v.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var timer: Timer?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            timer = nil
            report()
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
            Slider(value: $value, in: range, step: step)
            // Always two lines tall: the menu window must never change height (it repaints badly when it does).
            Text(caption).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
        }
    }
}
