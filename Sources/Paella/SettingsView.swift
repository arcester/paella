import PaellaCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            MenuSettings().tabItem { Label("Menú", systemImage: "menubar.rectangle") }.tag("menu")
            PermissionSettings(model: model).tabItem { Label("Permisos", systemImage: "lock.shield") }.tag("permissions")
            AdvancedSettings(model: model).tabItem { Label("Avanzado", systemImage: "slider.horizontal.3") }.tag("advanced")
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @AppStorage(Key.tempUnit) private var tempUnit = "auto"
    @AppStorage(Key.appearance) private var appearance = "system"
    @AppStorage(Key.leaveFrontmost) private var leaveFrontmost = true
    @AppStorage(Key.eCoresFirst) private var eCoresFirst = true
    @AppStorage(Key.lpmFallback) private var lpmFallback = false

    var body: some View {
        Form {
            Section("Inicio") {
                Toggle("Abrir al iniciar sesión", isOn: $model.launchAtLogin)
                Toggle(isOn: Binding(get: { model.watchdogInstalled }, set: { model.setWatchdog($0) })) {
                    Text("Vigilante")
                    Text("Si la app se cierra a la fuerza, macOS la vuelve a abrir y reanuda al instante los procesos que estuvieran pausados. Al activarlo, la app se reinicia bajo launchd.")
                }
            }
            Section("Apariencia") {
                Picker("Aspecto", selection: $appearance) {
                    Text("Según el sistema").tag("system")
                    Text("Claro").tag("light")
                    Text("Oscuro").tag("dark")
                }
                .onChange(of: appearance) { applyAppearance() }
            }
            Section("Unidades") {
                Picker("Temperatura", selection: $tempUnit) {
                    Text("Según el sistema").tag("auto")
                    Text("Celsius (°C)").tag("c")
                    Text("Fahrenheit (°F)").tag("f")
                }
            }
            Section("Comportamiento") {
                Toggle(isOn: $leaveFrontmost) {
                    Text("No limitar la app en primer plano")
                    Text("La app que estás usando nunca se limita, aunque sea la que más exige.")
                }
                Toggle(isOn: $eCoresFirst) {
                    Text("Usar primero los núcleos de eficiencia")
                    Text("\(tempDelta(2)) antes del objetivo, los procesos pesados pasan a los núcleos de eficiencia. Enfría mucho antes de tener que pausarlos.")
                }
                Toggle(isOn: $lpmFallback) {
                    Text("Modo de bajo consumo como último recurso")
                    Text(model.sudoersInstalled
                         ? String(localized: "Si tras 3 min en el ciclo mínimo la temperatura sigue \(tempDelta(5)) por encima del objetivo, se activa el Modo de bajo consumo. Se devuelve a como estaba cuando baja \(tempDelta(5)) por debajo durante 2 min.")
                         : String(localized: "Necesita el permiso de la pestaña Permisos."))
                }
                .disabled(!model.sudoersInstalled)
            }
            if let m = model.message { Text(m).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}

private struct MenuSettings: View {
    @AppStorage(Key.menuBarTemp) private var menuBarTemp = "smoothed"
    @AppStorage(Key.menuBarPower) private var menuBarPower = true
    @AppStorage(Key.menuBarIndicator) private var menuBarIndicator = "always"
    @AppStorage(Key.menuBarWeight) private var menuBarWeight = "regular"
    @AppStorage(Key.autoRefresh) private var autoRefresh = true
    @AppStorage(Key.refreshInterval) private var refreshInterval = 10.0
    @AppStorage(Key.listMinCPU) private var listMinCPU = 0.05
    @AppStorage(Key.listMinGPU) private var listMinGPU = 0.02
    @AppStorage(Key.listWindow) private var listWindow = 10.0
    @AppStorage(Key.listSmoothing) private var listSmoothing = 10.0

    private var menuBarDetail: String {
        switch menuBarTemp {
        case "max": String(localized: "El sensor más caliente en cada momento: reacciona al instante pero salta mucho.")
        case "pan": String(localized: "Solo la paellera, con el punto de color que indica si se está limitando algo.")
        default: String(localized: "Media del último minuto: es la que usa el control para compararla con el objetivo.")
        }
    }

    var body: some View {
        Form {
            Section("Barra de menús") {
                Picker(selection: $menuBarTemp) {
                    Text("Temperatura suavizada").tag("smoothed")
                    Text("Máximo del chip").tag("max")
                    Label { Text("Paellera") } icon: { Image(nsImage: .paellaTemplate) }.tag("pan")
                } label: {
                    Text("Icono de la barra de menús")
                    Text(menuBarDetail)
                }
                Toggle(isOn: $menuBarPower) {
                    Text("Mostrar la potencia debajo")
                    Text("Consumo total del equipo en vatios, según el controlador de la batería.")
                }
                Picker(selection: $menuBarIndicator) {
                    Text("Punto siempre visible").tag("always")
                    Text("Punto solo al limitar").tag("alert")
                    Text("Color del texto").tag("text")
                } label: {
                    Text("Indicador de limitación")
                    Text("Verde: nada limitado. Naranja: limitando procesos. Rojo: al límite.")
                }
                Picker("Grosor de la fuente", selection: $menuBarWeight) {
                    Text("Normal").tag("regular")
                    Text("Media").tag("medium")
                    Text("Seminegrita").tag("semibold")
                    Text("Negrita").tag("bold")
                }
            }
            Section("Lista de procesos") {
                Toggle(isOn: $autoRefresh) {
                    Text("Actualizar con el menú abierto")
                    Text("Si está desactivado, la lista no cambia mientras la miras.")
                }
                SliderRow(title: "Cada", detail: "Cada cuánto entran y salen procesos de la lista", value: $refreshInterval,
                          range: Limits.refreshInterval, step: 5) { "\(Int($0)) s" }
                    .disabled(!autoRefresh)
                SliderRow(title: "Suavizado", detail: "Cada cifra es la media de este tiempo: los picos más cortos apenas cuentan",
                          value: $listSmoothing, range: Limits.listSmoothing, step: 2) { "\(Int($0)) s" }
                SliderRow(title: "Ventana", detail: "La lista ordena los procesos por el máximo que han alcanzado en este tiempo",
                          value: $listWindow, range: Limits.listWindow, step: 1) { "\(Int($0)) min" }
                SliderRow(title: "Mínimo de CPU", detail: "Máximo de CPU a partir del cual un proceso aparece en la lista", value: $listMinCPU,
                          range: Limits.listMinCPU, step: 0.01) { String(localized: "\(Int(($0 * 100).rounded())) % de núcleo") }
                SliderRow(title: "Mínimo de GPU", detail: "Máximo de GPU a partir del cual un proceso aparece en la lista", value: $listMinGPU,
                          range: Limits.listMinGPU, step: 0.01) { "\(Int(($0 * 100).rounded())) %" }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Modo de bajo consumo") {
                Label(model.sudoersInstalled ? String(localized: "Permiso instalado") : String(localized: "Permiso no instalado"),
                      systemImage: model.sudoersInstalled ? "checkmark.seal.fill" : "xmark.seal")
                    .foregroundStyle(model.sudoersInstalled ? .green : .secondary)
                Text("Para activar y desactivar el Modo de bajo consumo, la app instala una regla en /etc/sudoers.d/paella que solo permite «pmset -a lowpowermode 0» y «pmset -a lowpowermode 1». Instalarla o quitarla pide una vez la contraseña de administrador.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Instalar…") { model.installSudoers() }.disabled(model.sudoersInstalled)
                    Button("Quitar…") { model.removeSudoers() }.disabled(!model.sudoersInstalled)
                }
            }
            Section("Sin permisos especiales") {
                Text("Leer las temperaturas, medir el uso de CPU y GPU, pausar procesos y pasarlos a los núcleos de eficiencia no requieren permisos: solo se actúa sobre procesos de tu usuario.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let m = model.message { Text(m).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @Bindable var model: AppModel
    @AppStorage(Key.kp) private var kp = 0.1
    @AppStorage(Key.ki) private var ki = 0.0005
    @AppStorage(Key.tau) private var tau = 60.0
    @AppStorage(Key.period) private var period = 0.2
    @AppStorage(Key.cpuThreshold) private var cpuThreshold = 0.8
    @AppStorage(Key.gpuThreshold) private var gpuThreshold = 0.2
    @AppStorage(Key.sensorFilters) private var sensorFilters = ""
    @AppStorage(Key.sensorExcludes) private var sensorExcludes = ""

    var body: some View {
        Form {
            Section("Control") {
                SliderRow(title: "Kp", detail: "Ciclo que se resta por cada °C sobre el objetivo", value: $kp, range: Limits.kp, step: 0.01) { String(format: "%.2f", $0) }
                SliderRow(title: "Ki", detail: "Ciclo que se resta por cada °C·s acumulado sobre el objetivo", value: $ki, range: Limits.ki, step: 0.0001) { String(format: "%.4f", $0) }
                SliderRow(title: "Suavizado τ", detail: "Tiempo de la media móvil de temperatura", value: $tau, range: Limits.tau, step: 5) { "\(Int($0)) s" }
                SliderRow(title: "Periodo del ciclo", detail: "Duración de cada ciclo de pausa y reanudación", value: $period, range: Limits.period, step: 0.05) { "\(Int(($0 * 1000).rounded())) ms" }
            }
            Section("Qué cuenta como proceso exigente") {
                SliderRow(title: "Umbral de CPU", detail: "Uso de CPU a partir del cual un proceso se puede limitar", value: $cpuThreshold, range: Limits.cpuThreshold, step: 0.1) { String(localized: "\(Int(($0 * 100).rounded())) % de núcleo") }
                SliderRow(title: "Umbral de GPU", detail: "Fracción del tiempo de GPU a partir de la cual se puede limitar", value: $gpuThreshold, range: Limits.gpuThreshold, step: 0.05) { "\(Int(($0 * 100).rounded())) %" }
                Text(model.gpuAvailable ? String(localized: "Estadísticas de GPU por proceso: disponibles") : String(localized: "Estadísticas de GPU por proceso: no disponibles"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sensores") {
                TextField("Incluir (subcadenas)", text: $sensorFilters, prompt: Text("tdie, PMU…"))
                TextField("Excluir (subcadenas)", text: $sensorExcludes, prompt: Text("tcal"))
                Text("Qué sensores de temperatura cuentan para el máximo del chip.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restaurar valores por defecto") {
                    // Only this tab's keys: exclusions ("Ilimitado") and the saved LPM state must survive.
                    for k in [Key.kp, Key.ki, Key.tau, Key.period, Key.cpuThreshold, Key.gpuThreshold, Key.sensorFilters, Key.sensorExcludes] {
                        UserDefaults.standard.removeObject(forKey: k)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SliderRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Text(format(clamp(value, range))).monospacedDigit().foregroundStyle(.secondary)
            } label: {
                Text(title)
                Text(detail)
            }
            // Values stored outside the range (older versions, `defaults write`) snap into it.
            Slider(value: snapped($value, range, step), in: range)
                .labelsHidden()
        }
    }
}
