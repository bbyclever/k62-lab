import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject private var bluetooth: K62BluetoothManager
    @State private var knownIdentifier = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Estado Bluetooth") {
                    Text(bluetooth.status)
                    Text("Dispositivo: " + bluetooth.currentName)
                    Text("Lectura FEC9: " + bluetooth.lastRead)
                        .font(.system(.body, design: .monospaced))
                }

                Section("Encontrar K62 sin desvincularlo") {
                    Button("Recuperar dispositivos ya conectados a iOS") {
                        bluetooth.recoverConnected()
                    }
                    Button("Buscar dispositivos cercanos") {
                        bluetooth.scan()
                    }
                    Button("Detener búsqueda") {
                        bluetooth.stopScan()
                    }
                    TextField("UUID de periférico de iOS (opcional)", text: $knownIdentifier)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Recuperar por identificador") {
                        bluetooth.recoverIdentifier(knownIdentifier)
                    }
                    Text("La recuperación desde iOS no garantiza una conexión GATT simultánea con FitCloudPro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Dispositivos encontrados") {
                    if bluetooth.candidates.isEmpty {
                        Text("Sin candidatos. Prueba «Recuperar dispositivos ya conectados a iOS».")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bluetooth.candidates, id: \.identifier) { peripheral in
                        Button {
                            bluetooth.connect(peripheral)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(peripheral.name ?? "Sin nombre")
                                    .foregroundStyle(.primary)
                                Text(peripheral.identifier.uuidString)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Registro local") {
                    ForEach(Array(bluetooth.logs.enumerated()), id: \.offset) { _, event in
                        Text(event).font(.caption.monospaced())
                    }
                    Text("No se envían datos a ningún servidor. Sin escrituras BLE ni firmware DFU.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("K62 Lab Native")
        }
    }
}
