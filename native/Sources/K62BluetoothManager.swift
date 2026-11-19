import Foundation
import CoreBluetooth

final class K62BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var status = "Iniciando Core Bluetooth…"
    @Published private(set) var currentName = "Ninguno"
    @Published private(set) var lastRead = "—"
    @Published private(set) var candidates: [CBPeripheral] = []
    @Published private(set) var logs: [String] = []

    private var central: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private let fee7 = CBUUID(string: "FEE7")
    private let fec9 = CBUUID(string: "FEC9")
    private let knownServices = [
        CBUUID(string: "FEE7"),
        CBUUID(string: "000001FF-3C17-D293-8E48-14FE2E4DA212"),
        CBUUID(string: "0000D0FF-3C17-D293-8E48-14FE2E4DA212")
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.insert(formatter.string(from: Date()) + " · " + text, at: 0)
        if logs.count > 100 { logs.removeLast() }
    }

    private func ensureReady() -> Bool {
        guard central.state == .poweredOn else {
            status = "Bluetooth no está disponible: " + String(describing: central.state.rawValue)
            return false
        }
        return true
    }

    private func add(_ peripheral: CBPeripheral) {
        if !candidates.contains(where: { $0.identifier == peripheral.identifier }) {
            candidates.append(peripheral)
        }
    }

    func recoverConnected() {
        guard ensureReady() else { return }
        let recovered = central.retrieveConnectedPeripherals(withServices: knownServices)
        recovered.forEach(add)
        log("Core Bluetooth: recuperados " + String(recovered.count) + " periféricos conectados")
        status = recovered.isEmpty ? "No hay periféricos conectados para estos servicios" : "Selecciona un periférico para intentar conexión"
    }

    func recoverIdentifier(_ text: String) {
        guard ensureReady() else { return }
        guard let identifier = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = "Introduce un UUID válido de periférico iOS"
            return
        }
        let recovered = central.retrievePeripherals(withIdentifiers: [identifier])
        recovered.forEach(add)
        log("Recuperación por UUID: " + String(recovered.count) + " resultado(s)")
        if recovered.isEmpty { status = "Identificador no encontrado en caché de Core Bluetooth" }
    }

    func scan() {
        guard ensureReady() else { return }
        candidates = []
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        status = "Buscando BLE…"
        log("Escaneo iniciado; no se modifica el emparejamiento")
    }

    func stopScan() {
        central.stopScan()
        log("Escaneo detenido")
    }

    func connect(_ peripheral: CBPeripheral) {
        guard ensureReady() else { return }
        stopScan()
        activePeripheral = peripheral
        currentName = peripheral.name ?? "Sin nombre"
        peripheral.delegate = self
        status = "Conectando a " + currentName + "…"
        central.connect(peripheral, options: nil)
    }
}

extension K62BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "Bluetooth listo"
        case .poweredOff:
            status = "Activa Bluetooth en el iPhone"
        case .unauthorized:
            status = "Permiso Bluetooth denegado"
        case .unsupported:
            status = "Bluetooth LE no compatible"
        default:
            status = "Bluetooth no disponible aún"
        }
        log(status)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if (peripheral.name ?? "").localizedCaseInsensitiveContains("K62") {
            add(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Conectado a " + (peripheral.name ?? "reloj")
        log("Conexión GATT establecida")
        peripheral.discoverServices([fee7])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Error al conectar: " + (error?.localizedDescription ?? "desconocido")
        log(status)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        status = "Desconectado" + (error.map { ": " + $0.localizedDescription } ?? "")
        log(status)
    }
}

extension K62BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("Servicios: " + error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == fee7 }) else {
            log("FEE7 no está disponible")
            return
        }
        peripheral.discoverCharacteristics([fec9], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("Características: " + error.localizedDescription); return }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == fec9 }) else {
            log("No se encontró FEC9")
            return
        }
        guard characteristic.properties.contains(.read) else {
            log("FEC9 no declara permiso de lectura")
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("Lectura: " + error.localizedDescription); return }
        guard characteristic.uuid == fec9, let data = characteristic.value else { return }
        lastRead = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        log("FEC9 leído correctamente (" + String(data.count) + " bytes)")
    }
}
