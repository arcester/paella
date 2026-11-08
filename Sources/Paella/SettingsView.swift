import PaellaCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            PermissionSettings(model: model).tabItem { Label("Permisos", systemImage: "lock.shield") }
            AdvancedSettings(model: model).tabItem { Label("Avanzado", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @AppStorage(Key.leaveFrontmost) private var leaveFrontmost = true
    @AppStorage(Key.eCoresFirst) private var eCoresFirst = true
    @AppStorage(Key.lpmFallback) private var lpmFallback = false
    @AppStorage(Key.menuBarTemp) private var menuBarTemp = "smoothed"

    var body: some View {
        Form {
            Section("Inicio") {
                Toggle("Abrir al iniciar sesión", isOn: $model.launchAtLogin)
                Toggle(isOn: Binding(get: { model.watchdogInstalled }, set: { model.setWatchdog($0) })) {
                    Text("Vigilante")
                    Text("Si la app se cierra a la fuerza, macOS la vuelve a abrir y reanuda al instante los procesos que estuvieran pausados. Al activarlo, la app se reinicia bajo launchd.")
                }
            }
            Section("Barra de menús") {
                Picker(selection: $menuBarTemp) {
                    Text("Suavizada").tag("smoothed")
                    Text("Máximo del chip").tag("max")
                } label: {
                    Text("Temperatura en la barra de menús")
                    Text(menuBarTemp == "max"
                         ? "El sensor más caliente en cada momento: reacciona al instante pero salta mucho."
                         : "Media del último minuto: es la que usa el control para compararla con el objetivo.")
                }
            }
            Section("Comportamiento") {
                Toggle(isOn: $leaveFrontmost) {
                    Text("No limitar la app en primer plano")
                    Text("La app que estás usando nunca se limita, aunque sea la que más exige.")
                }
                Toggle(isOn: $eCoresFirst) {
                    Text("Usar primero los núcleos de eficiencia")
                    Text("2 °C antes del objetivo, los procesos pesados pasan a los núcleos de eficiencia. Enfría mucho antes de tener que pausarlos.")
                }
                Toggle(isOn: $lpmFallback) {
                    Text("Modo de bajo consumo como último recurso")
                    Text(model.sudoersInstalled
                         ? "Si tras 3 min en el ciclo mínimo la temperatura sigue 5 °C por encima del objetivo, se activa el Modo de bajo consumo. Se devuelve a como estaba cuando baja 5 °C por debajo durante 2 min."
                         : "Necesita el permiso de la pestaña Permisos.")
                }
                .disabled(!model.sudoersInstalled)
            }
            if let m = model.message { Text(m).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Modo de bajo consumo") {
                Label(model.sudoersInstalled ? "Permiso instalado" : "Permiso no instalado",
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
                NumberRow(title: "Kp", detail: "Ciclo que se resta por cada °C sobre el objetivo", value: $kp)
                NumberRow(title: "Ki", detail: "Ciclo que se resta por cada °C·s acumulado sobre el objetivo", value: $ki)
                NumberRow(title: "Suavizado τ (s)", detail: "Tiempo de la media móvil de temperatura", value: $tau)
                NumberRow(title: "Periodo del ciclo (s)", detail: "Duración de cada ciclo de pausa y reanudación", value: $period)
            }
            Section("Qué cuenta como proceso exigente") {
                NumberRow(title: "Umbral de CPU (núcleos)", detail: "0,8 = 80 % de un núcleo", value: $cpuThreshold)
                NumberRow(title: "Umbral de GPU (fracción)", detail: "0,2 = 20 % del tiempo de GPU", value: $gpuThreshold)
                Text(model.gpuAvailable ? "Estadísticas de GPU por proceso: disponibles" : "Estadísticas de GPU por proceso: no disponibles")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sensores") {
                TextField("Incluir (subcadenas)", text: $sensorFilters, prompt: Text("tdie, PMU…"))
                TextField("Excluir (subcadenas)", text: $sensorExcludes, prompt: Text("tcal"))
                Text("Qué sensores de temperatura cuentan para el máximo del chip.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NumberRow: View {
    let title: String
    let detail: String
    @Binding var value: Double

    var body: some View {
        LabeledContent {
            TextField(title, value: $value, format: .number.precision(.significantDigits(1...6)))
                .labelsHidden().frame(width: 90).multilineTextAlignment(.trailing)
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
