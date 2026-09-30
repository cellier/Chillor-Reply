import Foundation

// Pure, timestamp-driven detector shared by live HID input and raw CSV replay.
// No timers, AppKit, keyboard text, or main-thread scheduling in this layer.
struct TapDetector {
    var settings = TapSettings()
    private(set) var note = "等待传感器稳定…"
    private(set) var fires: [Double] = []
    private(set) var lastEvent: TapEvent?
    private var rest: Vector?
    private var previousHP: Vector = (0, 0, 0)
    private var currentHP: Vector = (0, 0, 0)
    private var lastSample: Double?
    private var started = 0.0
    private var spin = 0.0
    private var gyroAt = -Double.infinity
    private var movingSince: Double?
    private var background: [(t: Double, deviation: Double, spin: Double)] = []
    private var impulse: TapEvent?
    private var lastAbove = 0.0
    private var cluster: [TapEvent] = []
    private var lastPhysical = -Double.infinity
    private var lastAccepted = -Double.infinity
    private var pendingUntil: Double?
    private var quietUntil = -Double.infinity
    private var lastFire = -Double.infinity
    private var inputUntil = -Double.infinity

    mutating func reset() { let s = settings; self = TapDetector(); settings = s }

    // Called with the time of an actual input event, never the key or its text.
    // Every key press/release (including modifiers) vetoes the whole gesture.
    mutating func input(at time: Double, keyboard: Bool) {
        let until = time + (keyboard ? 0.30 : 0.20)
        guard until > inputUntil + 0.005 else { return }
        inputUntil = until
        cluster.removeAll(); pendingUntil = nil
        note = keyboard ? "打字中，拍击暂不触发" : "点击中，拍击暂不触发"
    }

    mutating func gyro(_ sample: Vector, at time: Double) {
        spin = sqrt(sample.x * sample.x + sample.y * sample.y + sample.z * sample.z)
        gyroAt = time
        // A tap itself produces a short gyro spike. Only SUSTAINED rotation
        // may veto a gesture before its pre-impact background is evaluated.
        if spin > settings.maxRestSpin * 2 {
            if movingSince == nil { movingSince = time }
        } else { movingSince = nil }
        if let movingSince, time - movingSince > 0.15 {
            cluster.removeAll(); pendingUntil = nil
            quietUntil = max(quietUntil, time + 0.30)
            note = "机器在移动，等待放稳"
        }
    }

    mutating func advance(to time: Double) {
        let inputEnded = (note.hasPrefix("打字中") || note.hasPrefix("点击中")) && time >= inputUntil
        let settled = note == "等待传感器稳定…" && lastSample != nil && time - started >= 0.55
        if inputEnded || settled { note = "就绪，请连拍 \(settings.taps) 下" }
        if pendingUntil == nil, let last = cluster.last, time - last.at > settings.maxGap {
            cluster.removeAll(); note = "间隔超时，请连着拍"
        }
        guard let deadline = pendingUntil, time >= deadline else { return }
        // A new impact must cancel at ONSET, not after its entire tail ends.
        // Never fire on a timer alone if the sensors have stopped delivering.
        guard let sample = lastSample, time - sample < 0.08, time - gyroAt < 0.15,
              time >= inputUntil, time >= quietUntil else {
            pendingUntil = nil; cluster.removeAll(); return
        }
        // Wait for an in-flight impulse to be classified; low-level noise is not a third tap.
        guard impulse == nil else { return }
        pendingUntil = nil; cluster.removeAll()
        if time - lastFire >= settings.cooldown {
            lastFire = time; fires.append(time)
            if fires.count > 256 { fires.removeFirst() }
            note = "已识别拍击"
        }
    }

    mutating func accelerometer(_ sample: Vector, at time: Double) {
        guard time.isFinite, sample.x.isFinite, sample.y.isFinite, sample.z.isFinite else { return }
        if let lastSample, time <= lastSample { return }
        if lastSample == nil || time - lastSample! > 0.08 {
            // Lost reports / sleep / a backed-up sensor queue cannot create a gesture.
            rest = sample; previousHP = (0, 0, 0); currentHP = (0, 0, 0)
            impulse = nil; cluster.removeAll(); pendingUntil = nil
            background.removeAll(); started = time; note = "等待传感器稳定…"
        }
        let dt = lastSample.map { min(0.02, time - $0) } ?? 0.0012
        lastSample = time
        var base = rest ?? sample
        // Time-based baseline: invariant to 400/800/1000 Hz delivery rates.
        let alpha = 1 - exp(-dt / 0.60)
        base.x += (sample.x - base.x) * alpha
        base.y += (sample.y - base.y) * alpha
        base.z += (sample.z - base.z) * alpha
        rest = base
        let hp: Vector = (sample.x - base.x, sample.y - base.y, sample.z - base.z)
        let deviation = sqrt(hp.x * hp.x + hp.y * hp.y + hp.z * hp.z)
        let rawSharp = abs(currentHP.x * currentHP.x - previousHP.x * hp.x)
            + abs(currentHP.y * currentHP.y - previousHP.y * hp.y)
            + abs(currentHP.z * currentHP.z - previousHP.z * hp.z)
        // Express energy at a 1 ms reference interval across sensor delivery rates.
        let sharp = rawSharp * pow(0.001 / max(dt, 0.0001), 2)
        previousHP = currentHP; currentHP = hp
        background.append((time, deviation, spin))
        if background.count > 1200 { background.removeFirst(400) }

        // Finish the previous impulse before considering a new crossing. The old
        // code could silently discard it if the next callback was above threshold.
        if let event = impulse, time - lastAbove > settings.release {
            impulse = nil
            var ended = event; ended.width = lastAbove - event.at
            accept(ended, endedAt: lastAbove)
        }
        // Finalize an expired gesture before a later, genuinely separate impact.
        advance(to: time)
        if deviation > settings.detect {
            if impulse == nil {
                let bg = background.filter { time - $0.t > 0.08 && time - $0.t < 0.55 }
                let ds = bg.map(\.deviation).sorted(), ss = bg.map(\.spin).sorted()
                impulse = TapEvent(at: time, peak: 0, width: 0, sharpness: 0,
                                   restSpin: ss.isEmpty ? spin : ss[ss.count / 2],
                                   restDeviation: ds.isEmpty ? deviation : ds[ds.count / 2])

            }
            impulse!.peak = max(impulse!.peak, deviation)
            impulse!.sharpness = max(impulse!.sharpness, sharp)
            lastAbove = time
            if pendingUntil != nil, time - lastAccepted >= settings.minGap,
               impulse!.peak >= settings.minPeak, impulse!.sharpness >= settings.minSharp {
                pendingUntil = nil; cluster.removeAll()
                quietUntil = max(quietUntil, time + settings.quietBefore)
                note = "后面还有动作，已取消"
            }
        }
    }

    private mutating func accept(_ event: TapEvent, endedAt: Double) {
        lastEvent = event
        let previousPhysical = lastPhysical
        guard event.at - started >= 0.55, endedAt - gyroAt < 0.15 else {
            cluster.removeAll(); note = "等待传感器稳定…"; return
        }
        guard event.at >= inputUntil, event.at >= quietUntil else {
            cluster.removeAll(); return
        }
        // Mechanical ringing within 160ms belongs to the preceding tap. It must
        // not become a third tap, poison the first tap's quiet window, or restart it.
        if event.at - lastAccepted < settings.minGap { return }
        if !cluster.isEmpty, event.at - cluster.last!.at > settings.maxGap {
            cluster.removeAll(); note = "两下间隔太久，请连着拍"
        }
        var candidate = event
        // The second impact's preceding half-second contains the FIRST impact.
        // Judge the resting background once, before the first tap, not twice.
        if let first = cluster.first { candidate.restDeviation = first.restDeviation }
        if let reason = tapRejection(candidate, settings) {
            // Subthreshold vibration must not erase a valid first tap or poison
            // the next gesture's quiet window. Movement still invalidates it.
            if candidate.peak > settings.maxPeak || candidate.width > settings.maxWidth ||
               candidate.restSpin > settings.maxRestSpin || candidate.restDeviation > settings.maxRestDev {
                cluster.removeAll(); pendingUntil = nil
                lastPhysical = event.at
            }
            if cluster.isEmpty { note = reason }
            return
        }
        lastPhysical = event.at
        if cluster.isEmpty && event.at - previousPhysical < settings.quietBefore {
            note = "开始前动作较多，稍停后再拍"; return
        }
        cluster.append(event); lastAccepted = event.at
        if cluster.count == settings.taps {
            let peaks = cluster.map(\.peak)
            guard peaks.max()! / max(1e-9, peaks.min()!) <= settings.strengthRatio else {
                cluster.removeAll(); note = "两下力度差距太大"; return
            }
            pendingUntil = endedAt + settings.confirm
            note = "收到拍击，正在排除后续动作…"
        } else { note = "收到第 \(cluster.count) 下" }
    }
}

struct TapReplayResult {
    var name: String
    var seconds: Double
    var fires: [Double]
}

// Recorded files contain sensor data only. Their typing phase has NO recorded
// keyboard events; never fabricate key events and call that a measured result.
func replayTapCSV(_ path: String, settings: TapSettings = TapSettings()) throws -> TapReplayResult {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var rows: [(time: Double, kind: String, sample: Vector)] = []
    for line in text.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: ",")
        guard fields.count == 5, let t = Double(fields[1]), let x = Double(fields[2]),
              let y = Double(fields[3]), let z = Double(fields[4]) else { continue }
        rows.append((t, String(fields[0]), (x, y, z)))
    }
    rows.sort { $0.time == $1.time ? $0.kind > $1.kind : $0.time < $1.time }
    var detector = TapDetector(); detector.settings = settings
    for row in rows {
        if row.kind == "g" { detector.gyro(row.sample, at: row.time) }
        else { detector.accelerometer(row.sample, at: row.time) }
    }
    return TapReplayResult(name: URL(fileURLWithPath: path).lastPathComponent,
                           seconds: rows.last?.time ?? 0, fires: detector.fires)
}
