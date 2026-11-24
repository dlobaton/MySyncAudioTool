import CoreBluetooth
import Foundation

enum Role: Equatable { case host, guest }

struct Packet {
    enum Kind: UInt8 {
        case hello = 1, ping, pong, clockReady, prepare, ready, arm, armed, stop, fault, verified
    }

    let kind: Kind
    let a: UInt64
    let b: UInt64

    init(_ kind: Kind, _ a: UInt64 = 0, _ b: UInt64 = 0) {
        self.kind = kind
        self.a = a
        self.b = b
    }

    init?(_ data: Data) {
        let bytes = Array(data)
        guard bytes.count == 17, let kind = Kind(rawValue: bytes[0]) else { return nil }
        func word(_ start: Int) -> UInt64 {
            bytes[start..<start + 8].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        self.init(kind, word(1), word(9))
    }

    var data: Data {
        var result = Data([kind.rawValue])
        for word in [a, b] {
            for shift in stride(from: 56, through: 0, by: -8) {
                result.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }
        return result
    }
}

final class BluetoothLink: NSObject {
    private let uuid = CBUUID(string: "8CEC0CF2-E2A4-49CE-AAD4-20C9663E9A9E")
    private let channel = CBUUID(string: "CE1C4247-2BC9-419C-B780-A1C85EC22F50")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var device: CBPeripheral?
    private var subscriber: CBCentral?
    private var remote: CBCharacteristic?
    private var local: CBMutableCharacteristic?
    private var outgoing: [Data] = []
    private var writing = false

    var onConnect: (() -> Void)?
    var onPacket: ((Packet) -> Void)?
    var onError: ((String) -> Void)?

    func start(_ role: Role) {
        switch role {
        case .host: peripheral = CBPeripheralManager(delegate: self, queue: .main)
        case .guest: central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func close() {
        central?.delegate = nil
        peripheral?.delegate = nil
        device?.delegate = nil
        if central?.state == .poweredOn {
            central?.stopScan()
            if let device = device { central?.cancelPeripheralConnection(device) }
        }
        if peripheral?.state == .poweredOn {
            peripheral?.stopAdvertising()
            peripheral?.removeAllServices()
        }
        central = nil
        peripheral = nil
        device = nil
        subscriber = nil
        remote = nil
        local = nil
        outgoing.removeAll()
        writing = false
    }

    func send(_ packet: Packet) {
        guard outgoing.count < 32 else {
            onError?("El enlace Bluetooth se ha saturado.")
            return
        }
        outgoing.append(packet.data)
        flush()
    }

    private func flush() {
        if let peripheral = peripheral, let local = local, let subscriber = subscriber {
            while let data = outgoing.first,
                  peripheral.updateValue(data, for: local, onSubscribedCentrals: [subscriber]) {
                outgoing.removeFirst()
            }
        } else if let device = device, let remote = remote, !writing,
                  let data = outgoing.first, remote.isNotifying {
            writing = true
            outgoing.removeFirst()
            device.writeValue(data, for: remote, type: .withResponse)
        }
    }

    private func stateOK(_ state: CBManagerState) -> Bool {
        switch state {
        case .poweredOn: return true
        case .poweredOff: onError?("Activa Bluetooth en Ajustes y vuelve a intentarlo.")
        case .unauthorized: onError?("Permite el acceso a Bluetooth en Ajustes y vuelve a intentarlo.")
        case .unsupported: onError?("Este dispositivo no admite este modo de Bluetooth.")
        case .resetting: onError?("Bluetooth se ha reiniciado. Vuelve a intentarlo.")
        default: break
        }
        return false
    }

    private func receive(_ data: Data?) {
        guard let data = data, let packet = Packet(data) else {
            onError?("Mensaje Bluetooth no válido. Usa la misma versión de la app en ambos iPhone.")
            return
        }
        onPacket?(packet)
    }
}

extension BluetoothLink: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        guard stateOK(manager.state), local == nil else { return }
        let characteristic = CBMutableCharacteristic(type: channel, properties: [.write, .notify],
                                                      value: nil, permissions: [.writeable])
        let service = CBMutableService(type: uuid, primary: true)
        service.characteristics = [characteristic]
        local = characteristic
        manager.add(service)
    }

    func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            onError?("No se pudo crear el servicio Bluetooth.")
            return
        }
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]])
    }

    func peripheralManagerDidStartAdvertising(_ manager: CBPeripheralManager, error: Error?) {
        if error != nil { onError?("No se pudo anunciar el anfitrión por Bluetooth.") }
    }

    func peripheralManager(_ manager: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == channel, subscriber == nil else { return }
        subscriber = central
        manager.stopAdvertising()
        onConnect?()
    }

    func peripheralManager(_ manager: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if central.identifier == subscriber?.identifier { onError?("Se ha perdido el enlace Bluetooth.") }
    }

    func peripheralManager(_ manager: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.count == 1, first.central.identifier == subscriber?.identifier,
              first.characteristic.uuid == channel, first.offset == 0 else {
            manager.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        manager.respond(to: first, withResult: .success)
        receive(first.value)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flush() }
}

extension BluetoothLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        if stateOK(manager.state), device == nil {
            manager.scanForPeripherals(withServices: [uuid])
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.device == nil else { return }
        self.device = device
        manager.stopScan()
        device.delegate = self
        manager.connect(device)
    }

    func centralManager(_ manager: CBCentralManager, didConnect device: CBPeripheral) {
        device.discoverServices([uuid])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        onError?("No se pudo conectar con el anfitrión.")
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        onError?("Se ha perdido el enlace Bluetooth.")
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = device.services?.first(where: { $0.uuid == uuid }) else {
            onError?("No se encontró el servicio Bluetooth del anfitrión.")
            return
        }
        device.discoverCharacteristics([channel], for: service)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let remote = service.characteristics?.first(where: { $0.uuid == channel }) else {
            onError?("No se encontró el canal Bluetooth del anfitrión.")
            return
        }
        self.remote = remote
        device.setNotifyValue(true, for: remote)
    }

    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, characteristic.isNotifying else {
            onError?("No se pudo abrir el canal Bluetooth.")
            return
        }
        onConnect?()
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil { receive(characteristic.value) }
        else { onError?("No se pudo recibir un mensaje Bluetooth.") }
    }

    func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if error == nil { flush() }
        else { onError?("No se pudo enviar un mensaje Bluetooth.") }
    }
}
