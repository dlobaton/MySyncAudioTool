import AVFoundation
import SwiftUI
import UIKit

final class SyncSession: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Stage: Equatable {
        case loading, idle, connecting, measuring, linked, testing, listening, verified, playing, failed
    }

    private final class Cue {
        let token: UInt64
        let index: Int
        let player: AVAudioPlayer
        var start: Int64?
        var deadline: Int64
        var armed = false
        var mediaOffset = 0.0
        var replacesCurrent = false
        var countdownStart = false

        init(token: UInt64, index: Int, player: AVAudioPlayer, deadline: Int64) {
            self.token = token
            self.index = index
            self.player = player
            self.deadline = deadline
        }

        var end: Int64? {
            start.map { $0 + Monotonic.ns(max(0, player.duration - mediaOffset)) }
        }
    }

    private struct PendingControl {
        enum Kind: UInt8 {
            case pause = 1, resume
        }

        let token: UInt64
        let kind: Kind
        let time: Int64
        var acknowledged: Bool
    }

    @Published private(set) var stage: Stage = .loading
    @Published private(set) var message = "Leyendo la carpeta songs…"
    @Published private(set) var titles: [String] = []
    @Published private(set) var role: Role?
    @Published private(set) var correction = 0
    @Published private(set) var acousticOK = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentTrackIndex: Int?
    @Published private(set) var countdownSeconds: Int?

    private let audio = AVAudioSession.sharedInstance()
    private var library: AudioLibrary?
    private var link: BluetoothLink?
    private var audioActive = false
    private var audioClock: AVAudioPlayer?
    private lazy var testAudio = AudioLibrary.clickTest()
    private var timer: Timer?
    private var connected = false
    private var handshake = false
    private var timeout: Int64 = 0
    private var lastPeer: Int64 = 0
    private var nextPing: Int64 = 0
    private var ping: Int64?
    private var lastClockReady: Int64 = 0
    private var clock = ClockSync()
    private var sequence: UInt64 = 0
    private var queued: Cue?
    private var current: Cue?
    private var retiring: [Cue] = []
    private var target: Int64 = 0
    private var pendingControl: PendingControl?
    private var controlSequence: UInt64 = 0
    private var remoteOutputVolume: Float?
    private var matchedTargetVolume: Float?
    private var appliedGain: Float = 1
    private var lastVolumeReport: Int64 = 0
    private var lastGainReport: Int64 = 0
    private var reportedOutputVolume: Float = -1

    override init() {
        super.init()
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(interrupted(_:)),
                                  name: AVAudioSession.interruptionNotification, object: audio)
        notifications.addObserver(self, selector: #selector(routeChanged(_:)),
                                  name: AVAudioSession.routeChangeNotification, object: audio)
        notifications.addObserver(self, selector: #selector(backgrounded(_:)),
                                  name: UIApplication.didEnterBackgroundNotification, object: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AudioLibrary.load() }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let library):
                    self.library = library
                    self.titles = library.songs.map(\.lastPathComponent)
                    self.show(.idle, "Activa Bluetooth en ambos iPhone, abre la app y mantenlos cerca.")
                case .failure(let error):
                    self.fail("No se pudo leer la carpeta songs: \(error.localizedDescription)")
                }
            }
        }
    }

    var canConnect: Bool { library != nil && link == nil }
    var isConnected: Bool { link != nil }
    var canControlMusic: Bool {
        role == .host && acousticOK && queued == nil && pendingControl == nil &&
            (stage == .verified || stage == .playing)
    }

    func connect(_ role: Role) {
        guard canConnect else { return }
        do {
            try audio.setCategory(.playback, mode: .default)
            try audio.setActive(true)
            audioActive = true
            guard usingSpeaker else {
                fail("Selecciona el altavoz del iPhone como salida. Desconecta auriculares o AirPlay.")
                return
            }
            // Keep the output clock running even when no song is playing.
            let player = try AVAudioPlayer(data: AudioLibrary.clickTest(silent: true))
            player.numberOfLoops = -1
            guard player.play() else {
                fail("No se pudo iniciar el reloj de audio.")
                return
            }
            audioClock = player
        } catch {
            fail("No se pudo activar el audio: \(error.localizedDescription)")
            return
        }

        UIApplication.shared.isIdleTimerDisabled = true
        self.role = role
        correction = 0
        timeout = Monotonic.now + Monotonic.ns(35)
        show(.connecting, role == .host
             ? "En el otro iPhone, pulsa «Sincronizar» y elige «Unirme»."
             : "Buscando al anfitrión. Comprueba que haya elegido «Ser anfitrión».")
        let transport = BluetoothLink()
        transport.onConnect = { [weak self] in self?.didConnect() }
        transport.onPacket = { [weak self] in self?.receive($0) }
        transport.onError = { [weak self] in self?.fail($0) }
        link = transport
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        transport.start(role)
    }

    func disconnect() {
        link?.onError = nil
        link?.send(Packet(.stop))
        reset()
        show(.idle, "Sesión cerrada. Puedes sincronizar los iPhone otra vez.")
    }

    func test() {
        guard role == .host, [.linked, .listening, .verified].contains(stage) else { return }
        acousticOK = false
        begin(index: -1, earliest: Monotonic.now + Monotonic.ns(2.5))
    }

    func adjust(_ change: Int) {
        guard role == .host, stage == .listening || stage == .linked else { return }
        correction = max(-120, min(120, correction + change))
        show(.linked, "Repite la prueba con el nuevo ajuste. Un valor positivo retrasa al invitado.")
    }

    func verify() {
        guard role == .host, stage == .listening else { return }
        acousticOK = true
        link?.send(Packet(.verified))
        if link != nil { showVerified() }
    }

    func reject() {
        guard role == .host, stage == .listening else { return }
        fail("Los pulsos no sonaron al unísono. Acerca los iPhone y vuelve a sincronizar.")
    }

    func play() {
        guard role == .host, acousticOK, stage == .verified, !titles.isEmpty else { return }
        begin(index: 0, earliest: Monotonic.now + Monotonic.ns(30), countdownStart: true)
    }

    func playTrack(_ index: Int) {
        guard canControlMusic, titles.indices.contains(index) else { return }
        begin(index: index, earliest: Monotonic.now + Monotonic.ns(2.5), manualSelection: true)
    }

    func togglePlayback() {
        guard role == .host, stage == .playing, current.map({ $0.index >= 0 }) == true,
              queued == nil, pendingControl == nil else { return }
        let kind: PendingControl.Kind = isPaused ? .resume : .pause
        controlSequence += 1
        let time = Monotonic.now + Monotonic.ns(1.5)
        if kind == .resume, let cue = current {
            cue.mediaOffset = cue.player.currentTime
            cue.player.currentTime = cue.mediaOffset
            guard schedule(cue, at: time) else {
                fail("No se pudo programar la reanudación sincronizada.")
                return
            }
        }
        pendingControl = PendingControl(token: controlSequence, kind: kind, time: time,
                                        acknowledged: false)
        link?.send(Packet(kind == .pause ? .pause : .resume,
                          controlSequence, UInt64(time)))
    }

    private var usingSpeaker: Bool {
        audio.currentRoute.outputs.map(\.portType) == [.builtInSpeaker]
    }

    @objc private func interrupted(_ event: Notification) {
        guard event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ==
                AVAudioSession.InterruptionType.began.rawValue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.link != nil else { return }
            self.fail("iOS interrumpió el audio. Vuelve a sincronizar.")
        }
    }

    @objc private func routeChanged(_ event: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.link != nil, !self.usingSpeaker else { return }
            self.fail("Cambió la salida de audio. Selecciona el altavoz y vuelve a sincronizar.")
        }
    }

    @objc private func backgrounded(_ event: Notification) {
        guard link != nil else { return }
        fail("La app dejó de estar en primer plano. Ábrela en ambos iPhone y vuelve a sincronizar.")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        fail("No se pudo decodificar el audio. \(error?.localizedDescription ?? "Revisa el archivo de la canción.")")
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if !flag { fail("La reproducción se interrumpió antes de terminar.") }
    }

    private func show(_ stage: Stage, _ message: String) {
        self.message = message
        self.stage = stage
    }

    private func showVerified() {
        show(.verified, titles.isEmpty
             ? "Pulsos confirmados. Añade archivos MP3 o WAV a songs y reinstala la misma app en ambos iPhone."
             : role == .host ? "Pulsos confirmados. Ya puedes reproducir la lista."
                             : "Pulsos confirmados. El anfitrión iniciará la reproducción.")
    }

    private func fail(_ message: String, notify: Bool = true) {
        let transport = link
        transport?.onError = nil
        if notify { transport?.send(Packet(.fault)) }
        reset()
        show(.failed, message)
    }

    private func reset() {
        link?.close()
        link = nil
        timer?.invalidate()
        timer = nil
        for cue in [queued, current].compactMap({ $0 }) + retiring {
            cue.player.delegate = nil
            cue.player.stop()
        }
        queued = nil
        current = nil
        retiring.removeAll()
        audioClock?.stop()
        audioClock = nil
        if audioActive {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            audioActive = false
        }
        UIApplication.shared.isIdleTimerDisabled = false
        role = nil
        connected = false
        handshake = false
        acousticOK = false
        clock = ClockSync()
        lastPeer = 0
        lastClockReady = 0
        nextPing = 0
        ping = nil
        sequence = 0
        pendingControl = nil
        controlSequence = 0
        remoteOutputVolume = nil
        matchedTargetVolume = nil
        appliedGain = 1
        isPaused = false
        currentTrackIndex = nil
        countdownSeconds = nil
        lastVolumeReport = 0
        lastGainReport = 0
        reportedOutputVolume = -1
    }

    private func didConnect() {
        guard let library = library else { return }
        connected = true
        timeout = Monotonic.now + Monotonic.ns(20)
        show(.measuring, "Conectados por Bluetooth. Midiendo la diferencia entre los relojes…")
        if role == .guest { link?.send(Packet(.hello, library.fingerprint.0, library.fingerprint.1)) }
    }

    private func receive(_ packet: Packet) {
        let now = Monotonic.now
        switch packet.kind {
        case .stop:
            reset()
            show(.idle, "El otro iPhone cerró la sesión.")
            return
        case .fault:
            fail("El otro iPhone perdió la sincronización o detectó un error.", notify: false)
            return
        case .hello:
            guard connected, !handshake, let library = library else { return }
            guard packet.a == library.fingerprint.0, packet.b == library.fingerprint.1 else {
                fail("Las listas no coinciden. Instala la misma versión con los mismos archivos de audio en ambos iPhone.")
                return
            }
            handshake = true
            lastPeer = now
            if role == .host { link?.send(Packet(.hello, library.fingerprint.0, library.fingerprint.1)) }
            return
        default: break
        }
        guard handshake else { return }
        switch (role, packet.kind) {
        case (.host?, .ping):
            lastPeer = now
            link?.send(Packet(.pong, packet.a, UInt64(Monotonic.now)))
        case (.host?, .volume):
            let volume = Float(bitPattern: UInt32(truncatingIfNeeded: packet.a))
            guard volume.isFinite, (0...1).contains(volume) else { return }
            remoteOutputVolume = volume
            updateMatchedGain(sendToGuest: true)
        case (.guest?, .pong):
            guard let sent = ping, packet.a == UInt64(sent),
                  let remote = Int64(exactly: packet.b) else { return }
            ping = nil
            lastPeer = now
            clock.record(sent: sent, remote: remote, received: now)
        case (.host?, .clockReady):
            lastClockReady = now
            if stage == .measuring {
                show(.linked, "Relojes alineados. Coloca los iPhone a igual distancia de ti y lanza la prueba.")
            }
        case (.guest?, .prepare), (.guest?, .select), (.guest?, .playlist):
            prepareGuest(packet)
        case (.host?, .ready):
            armHost(packet)
        case (.guest?, .arm):
            armGuest(packet)
        case (.host?, .armed):
            if let cue = queued, cue.token == packet.a, !cue.armed, let start = cue.start {
                guard now < cue.deadline, schedule(cue, at: start) else {
                    fail("No se pudo programar el audio del anfitrión a tiempo.")
                    return
                }
                cue.armed = true
            }
        case (.guest?, .pause):
            scheduleControl(packet, kind: .pause)
        case (.guest?, .resume):
            scheduleControl(packet, kind: .resume)
        case (.host?, .controlReady):
            guard var action = pendingControl,
                  packet.a == action.token, packet.b == UInt64(action.kind.rawValue) else { return }
            action.acknowledged = true
            pendingControl = action
        case (.guest?, .gain):
            let targetVolume = Float(bitPattern: UInt32(truncatingIfNeeded: packet.a))
            guard targetVolume.isFinite, (0...1).contains(targetVolume) else { return }
            matchedTargetVolume = targetVolume
            applyGain(gain(for: targetVolume, outputVolume: audio.outputVolume))
        case (.guest?, .verified):
            guard stage == .listening || (stage == .testing && current?.index == -1) else { return }
            acousticOK = true
            if stage == .listening { showVerified() }
        default: break
        }
    }

    private func makeCue(token: UInt64, index: Int, deadline: Int64) throws -> Cue? {
        let player: AVAudioPlayer
        if index == -1 {
            player = try AVAudioPlayer(data: testAudio)
        } else {
            guard let library = library, library.songs.indices.contains(index) else { return nil }
            player = try AVAudioPlayer(contentsOf: library.songs[index])
        }
        guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else { return nil }
        player.volume = appliedGain
        player.delegate = self
        return Cue(token: token, index: index, player: player, deadline: deadline)
    }

    private func begin(index: Int, earliest: Int64, manualSelection: Bool = false,
                       countdownStart: Bool = false) {
        let now = Monotonic.now
        guard now - lastClockReady < Monotonic.ns(1.6) else {
            fail("La medición del reloj ya no es estable. Acerca los iPhone y vuelve a intentarlo.")
            return
        }
        sequence += 1
        do {
            let start = max(earliest, now + Monotonic.ns(1.8))
            guard let cue = try makeCue(token: sequence, index: index,
                                        deadline: start - Monotonic.ns(0.55)) else {
                fail("No se pudo preparar el audio seleccionado.")
                return
            }
            cue.replacesCurrent = manualSelection
            cue.countdownStart = countdownStart
            queued = cue
            target = start
            if countdownStart { countdownSeconds = 30 }
            statusForQueue(index, countdownStart: countdownStart)
            let kind: Packet.Kind = manualSelection ? .select : countdownStart ? .playlist : .prepare
            link?.send(Packet(kind, cue.token, UInt64(index + 1)))
        } catch {
            fail("No se pudo abrir el audio: \(error.localizedDescription)")
        }
    }

    private func prepareGuest(_ packet: Packet) {
        guard queued == nil, packet.a == sequence + 1,
              let value = Int(exactly: packet.b), value <= titles.count else {
            fail("Se recibió una pista fuera de orden.")
            return
        }
        let index = value - 1
        let expected: Bool
        switch packet.kind {
        case .playlist:
            expected = index == 0 && acousticOK && stage == .verified
        case .select:
            expected = index >= 0 && acousticOK &&
                (stage == .verified || stage == .playing)
        default:
            expected = index == -1
                ? [.linked, .listening, .verified].contains(stage)
                : acousticOK && index == (current.map { $0.index + 1 } ?? 0)
        }
        guard expected else {
            fail("Los iPhone no están en el mismo punto de la lista.")
            return
        }
        do {
            guard clock.offset(at: Monotonic.now) != nil,
                  let cue = try makeCue(token: packet.a, index: index,
                                        deadline: Monotonic.now + Monotonic.ns(3)) else {
                fail("El invitado no pudo preparar el audio con un reloj estable.")
                return
            }
            sequence = packet.a
            queued = cue
            cue.replacesCurrent = packet.kind == .select
            cue.countdownStart = packet.kind == .playlist
            if cue.countdownStart { countdownSeconds = 30 }
            if index == -1 { acousticOK = false }
            statusForQueue(index, countdownStart: cue.countdownStart)
            link?.send(Packet(.ready, cue.token))
        } catch {
            fail("No se pudo abrir el audio: \(error.localizedDescription)")
        }
    }

    private func statusForQueue(_ index: Int, countdownStart: Bool = false) {
        if index == -1 {
            show(.testing, "Escucha tres pulsos. Si cada uno se oye como un solo golpe, están alineados.")
        } else if countdownStart {
            show(.playing, "La lista comienza en 30 segundos. Mantén ambos iPhone cerca y la app abierta.")
        } else if current == nil {
            show(.playing, "Programando \(titles[index]) en ambos iPhone…")
        }
    }

    private func armHost(_ packet: Packet) {
        guard let cue = queued, cue.token == packet.a, cue.start == nil else { return }
        guard Monotonic.now < cue.deadline else {
            fail("El invitado no preparó la pista a tiempo.")
            return
        }
        cue.start = target
        let guestTarget = target + Monotonic.ns(Double(correction) / 1_000)
        link?.send(Packet(.arm, cue.token, UInt64(guestTarget)))
    }

    private func armGuest(_ packet: Packet) {
        guard let cue = queued, cue.token == packet.a, !cue.armed,
              let hostTime = Int64(exactly: packet.b),
              let offset = clock.offset(at: Monotonic.now) else {
            fail("El invitado no pudo calcular el próximo inicio.")
            return
        }
        let (start, overflow) = hostTime.subtractingReportingOverflow(offset)
        let now = Monotonic.now
        guard !overflow, start >= now + Monotonic.ns(0.35), start <= now + Monotonic.ns(35),
              schedule(cue, at: start) else {
            fail("El invitado no pudo programar la pista a tiempo.")
            return
        }
        target = start
        cue.armed = true
        link?.send(Packet(.armed, cue.token))
    }

    private func schedule(_ cue: Cue, at start: Int64) -> Bool {
        guard let audioClock = audioClock else { return false }
        let before = Monotonic.now
        let deviceTime = audioClock.deviceCurrentTime
        let after = Monotonic.now
        let delay = Monotonic.seconds(start - (before + (after - before) / 2))
        guard delay >= 0.3, deviceTime > 0, cue.player.play(atTime: deviceTime + delay) else { return false }
        cue.start = start
        return true
    }

    private func scheduleControl(_ packet: Packet, kind: PendingControl.Kind) {
        guard pendingControl == nil, current.map({ $0.index >= 0 }) == true,
              queued == nil, packet.a > 0,
              let hostTime = Int64(exactly: packet.b),
              let offset = clock.offset(at: Monotonic.now) else {
            fail("No se pudo preparar el control sincronizado de reproducción.")
            return
        }
        let (time, overflow) = hostTime.subtractingReportingOverflow(offset)
        let now = Monotonic.now
        guard !overflow, time >= now + Monotonic.ns(0.35),
              time <= now + Monotonic.ns(3) else {
            fail("El control de reproducción llegó demasiado tarde.")
            return
        }
        if kind == .resume, let cue = current {
            cue.mediaOffset = cue.player.currentTime
            cue.player.currentTime = cue.mediaOffset
            guard schedule(cue, at: time) else {
                fail("No se pudo programar la reanudación sincronizada.")
                return
            }
        }
        pendingControl = PendingControl(token: packet.a, kind: kind, time: time,
                                        acknowledged: true)
        link?.send(Packet(.controlReady, packet.a, UInt64(kind.rawValue)))
    }

    private func applyGain(_ gain: Float) {
        let adjustedGain = max(0, min(1, gain))
        guard abs(adjustedGain - appliedGain) > 0.001 else { return }
        appliedGain = adjustedGain
        for cue in [queued, current].compactMap({ $0 }) + retiring {
            cue.player.volume = appliedGain
        }
    }

    private func updateMatchedGain(sendToGuest: Bool) {
        guard role == .host else { return }
        let localVolume = audio.outputVolume
        let targetVolume = min(localVolume, remoteOutputVolume ?? localVolume)
        matchedTargetVolume = targetVolume
        applyGain(gain(for: targetVolume, outputVolume: localVolume))
        let now = Monotonic.now
        if sendToGuest || now >= lastGainReport {
            link?.send(Packet(.gain, UInt64(targetVolume.bitPattern)))
            lastGainReport = now + Monotonic.ns(2)
        }
    }

    private func gain(for target: Float, outputVolume: Float) -> Float {
        if outputVolume > 0.001 { return max(0, min(1, target / outputVolume)) }
        return target <= 0.001 ? 0 : 1
    }

    private func tick() {
        let now = Monotonic.now
        if (stage == .connecting || stage == .measuring) && now >= timeout {
            fail("No se encontró un enlace con un reloj estable. Activa Bluetooth, acerca los iPhone y reintenta.")
            return
        }
        guard handshake else { return }
        guard now - lastPeer < Monotonic.ns(2.5) else {
            fail("El otro iPhone dejó de responder. Se ha detenido el audio.")
            return
        }
        if role == .guest {
            if now >= nextPing && (ping == nil || now - (ping ?? now) > Monotonic.ns(0.7)) {
                ping = now
                nextPing = now + Monotonic.ns(0.2)
                link?.send(Packet(.ping, UInt64(now)))
            }
            if now - lastClockReady >= Monotonic.ns(0.6), clock.offset(at: now) != nil, link != nil {
                lastClockReady = now
                link?.send(Packet(.clockReady))
                if stage == .measuring {
                    show(.linked, "Relojes alineados. Espera a que el anfitrión lance la prueba.")
                }
            }
            let volume = audio.outputVolume
            let volumeChanged = abs(volume - reportedOutputVolume) > 0.01
            if volumeChanged, let targetVolume = matchedTargetVolume {
                applyGain(gain(for: targetVolume, outputVolume: volume))
            }
            if now - lastVolumeReport >= Monotonic.ns(1) || volumeChanged {
                link?.send(Packet(.volume, UInt64(volume.bitPattern)))
                reportedOutputVolume = volume
                lastVolumeReport = now
            }
        } else {
            let volume = audio.outputVolume
            let volumeChanged = abs(volume - reportedOutputVolume) > 0.01
            if volumeChanged { reportedOutputVolume = volume }
            updateMatchedGain(sendToGuest: volumeChanged || now >= lastGainReport)
        }

        if let action = pendingControl {
            if !action.acknowledged && now >= action.time - Monotonic.ns(0.2) {
                fail("El otro iPhone no confirmó el control de reproducción.")
                return
            }
            if action.acknowledged && now >= action.time {
                if action.kind == .pause, let cue = current {
                    cue.player.pause()
                    cue.mediaOffset = cue.player.currentTime
                    cue.start = nil
                    isPaused = true
                    show(.playing, "Pausada: \(titles[cue.index]). Pulsa Reanudar para continuar.")
                } else if action.kind == .resume, let cue = current {
                    isPaused = false
                    show(.playing, "Sonando: \(titles[cue.index])")
                }
                pendingControl = nil
            }
        }

        if let cue = queued {
            if !cue.armed && now >= cue.deadline {
                fail("No se confirmó el siguiente inicio a tiempo. Se ha detenido el audio.")
                return
            }
            if cue.armed, let start = cue.start, now >= start {
                if let previous = current {
                    if cue.replacesCurrent {
                        previous.player.delegate = nil
                        previous.player.stop()
                    } else {
                        retiring.append(previous)
                    }
                }
                current = cue
                queued = nil
                isPaused = false
                countdownSeconds = nil
                currentTrackIndex = cue.index >= 0 ? cue.index : nil
                if cue.index >= 0 { show(.playing, "Sonando: \(titles[cue.index])") }
            }
        }
        if let cue = queued, cue.countdownStart, let start = cue.start {
            let seconds = max(0, Int(ceil(Monotonic.seconds(start - now))))
            if countdownSeconds != seconds { countdownSeconds = seconds }
        }
        retiring.removeAll { now >= ($0.end ?? now) + Monotonic.ns(0.3) }
        guard let cue = current, let end = cue.end, queued == nil else { return }
        guard !isPaused, pendingControl == nil else { return }
        let completion = end + (role == .host ? Monotonic.ns(0.25) : 0)
        if cue.index == -1 {
            if now >= completion {
                current = nil
                retiring.append(cue)
                if acousticOK { showVerified() }
                else {
                    show(.listening, role == .host
                         ? "Confirma si oíste tres golpes simples. Si sonaron dobles, ajusta el invitado y repite."
                         : "Prueba terminada. Espera la confirmación del anfitrión.")
                }
            }
        } else if cue.index + 1 < titles.count {
            if role == .host, end - now <= Monotonic.ns(5),
               let start = cue.start, now - start >= Monotonic.ns(0.25) {
                begin(index: cue.index + 1, earliest: end)
            } else if role == .guest, now > end + Monotonic.ns(1) {
                fail("No llegó la siguiente pista. Se ha detenido la lista.")
            }
        } else if now >= completion {
            current = nil
            retiring.append(cue)
            currentTrackIndex = nil
            showVerified()
        }
    }
}
