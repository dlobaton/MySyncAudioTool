let ms: Int64 = 1_000_000
let base = 10_000 * ms
let remoteOffset = 25 * ms
var clock = ClockSync()

for i in 0..<5 {
    let sent = base + Int64(i) * 200 * ms
    clock.record(sent: sent, remote: sent + 5 * ms + remoteOffset, received: sent + 10 * ms)
}
precondition(clock.offset(at: base + 900 * ms) == nil, "Not enough samples")

let sent = base + 1_000 * ms
clock.record(sent: sent, remote: sent + 5 * ms + remoteOffset, received: sent + 10 * ms)
clock.record(sent: sent + 100 * ms, remote: sent + 2_000 * ms, received: sent + 170 * ms)
precondition(clock.offset(at: sent + 180 * ms) == remoteOffset, "Prefer low-latency samples")
precondition(clock.offset(at: sent + 1_200 * ms) == nil, "Do not use a stale estimate")

var unstable = ClockSync()
for i in 0..<6 {
    let sent = base + Int64(i) * 200 * ms
    let jitter = i.isMultiple(of: 2) ? 20 * ms : 0
    let halfTrip = (5 + Int64(i)) * ms
    unstable.record(sent: sent, remote: sent + halfTrip + remoteOffset + jitter,
                    received: sent + 2 * halfTrip)
}
precondition(unstable.offset(at: base + 1_050 * ms) == nil, "Reject an unstable estimate")
