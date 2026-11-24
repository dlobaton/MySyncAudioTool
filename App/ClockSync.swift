import Dispatch

enum Monotonic {
    static var now: Int64 { Int64(DispatchTime.now().uptimeNanoseconds) }
    static func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1_000_000_000).rounded()) }
    static func seconds(_ nanoseconds: Int64) -> Double { Double(nanoseconds) / 1_000_000_000 }
}

struct ClockSync {
    private struct Sample {
        let received: Int64
        let roundTrip: Int64
        let offset: Int64
    }
    private var samples: [Sample] = []

    mutating func record(sent: Int64, remote: Int64, received: Int64) {
        let roundTrip = received - sent
        guard roundTrip > 0, roundTrip <= Monotonic.ns(0.075), remote > 0 else { return }
        // Host clock minus guest clock, using the midpoint of the round trip.
        samples.append(Sample(received: received, roundTrip: roundTrip,
                              offset: remote - (sent + roundTrip / 2)))
        samples.removeAll { received - $0.received > Monotonic.ns(5) }
    }

    func offset(at now: Int64) -> Int64? {
        let recent = samples.filter { now - $0.received <= Monotonic.ns(4) }
        guard recent.count >= 6, let newest = recent.last,
              now - newest.received <= Monotonic.ns(1) else { return nil }
        let offsets = recent.sorted { $0.roundTrip < $1.roundTrip }.prefix(4).map(\.offset).sorted()
        guard offsets[3].subtractingReportingOverflow(offsets[0]).overflow == false,
              offsets[3] - offsets[0] <= Monotonic.ns(0.010) else { return nil }
        return offsets[1] + (offsets[2] - offsets[1]) / 2
    }
}
