import Foundation

func runTapDetectorTests() throws {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
    // Synthetic waveforms test temporal behaviour, not measured recognition rates.
    // All paths feed exactly the same raw-sample engine used by the HID service.
    func replay(_ impacts: [(Double, Double)], keys: [Double] = [], clicks: [Double] = [],
                settings: TapSettings = TapSettings(), hz: Double = 800, end: Double = 4,
                gap: ClosedRange<Double>? = nil, moving: Bool = false,
                withGyro: Bool = true) -> TapDetector {
        var d = TapDetector(); d.settings = settings
        var keyIndex = 0, clickIndex = 0
        for i in 0...Int(end * hz) {
            let time = Double(i) / hz
            if let gap, gap.contains(time) { continue }
            while keyIndex < keys.count && keys[keyIndex] <= time {
                d.input(at: keys[keyIndex], keyboard: true); keyIndex += 1
            }
            while clickIndex < clicks.count && clicks[clickIndex] <= time {
                d.input(at: clicks[clickIndex], keyboard: false); clickIndex += 1
            }
            var z = -0.98 + 0.0003 * sin(time * 177)
            for (onset, strength) in impacts {
                let age = time - onset
                if age >= 0 && age < 0.080 {
                    z += strength * sin(age * 2 * .pi * 48) * exp(-age / 0.024)
                }
            }
            if withGyro { d.gyro((0, 0, moving ? 3 : 0.3), at: time) }
            d.accelerometer((0.007, 0.007, z), at: time)
            d.advance(to: time)
        }
        return d
    }
    let pair: [(Double, Double)] = [(1, 0.035), (1.3, 0.035)]
    check(replay(pair).fires.count == 1, "normal two taps must fire once")
    check(replay([(1, 0.018), (1.32, 0.070)]).fires.count == 1, "unequal light/heavy taps still form a gesture")
    for hz in [400.0, 800.0, 1000.0] {
        check(replay(pair, hz: hz).fires.count == 1, "sample rate \(hz) must preserve a real-time pair")
    }
    check(replay([(1, 0.035)]).fires.isEmpty, "single tap is not a pair")
    check(replay([(1, 0.035), (1.09, 0.035)]).fires.isEmpty, "ringing is not a second tap")
    check(replay([(1, 0.035), (1.9, 0.035)]).fires.isEmpty, "separate taps are not a pair")
    check(replay(pair + [(1.49, 0.035)]).fires.isEmpty, "third impact cancels at onset, before its tail ends")
    check(replay(pair + [(1.42, 0.008)]).fires.count == 1, "small mechanical ringing after second tap must not cancel it")
    check(replay((0..<15).map { (1 + Double($0) * 0.18, 0.035) }, end: 5).fires.isEmpty,
          "continuous knocking must not fire in the middle or at its end")
    check(replay(pair, keys: [1.01, 1.31]).fires.isEmpty, "two isolated keystrokes must never count as two taps")
    check(replay(pair, keys: [1.52]).fires.isEmpty, "key arriving during confirmation must cancel")
    check(replay(pair, clicks: [1.01, 1.31]).fires.isEmpty, "trackpad clicks must veto a gesture")
    check(replay(pair, keys: [0.6]).fires.count == 1, "typing finished 400ms before tap must not block it")
    check(replay(pair, keys: [0.85]).fires.isEmpty, "recent typing must veto the first tap")
    check(replay(pair, withGyro: false).fires.isEmpty, "missing gyro must fail closed")
    check(replay(pair, moving: true).fires.isEmpty, "moving laptop must not trigger")
    check(replay(pair, gap: 1.36...1.60).fires.isEmpty, "sensor stall during confirmation must discard gesture")
    check(replay(pair, end: 1.39).fires.isEmpty, "EOF must not magically confirm pending pair")
    var triple = TapSettings(); triple.taps = 3
    check(replay(pair, settings: triple).fires.isEmpty, "triple mode must not accept a pair")
    check(replay(pair + [(1.6, 0.035)], settings: triple).fires.count == 1, "three taps must work in triple mode")
    check(replay(pair + [(2.9, 0.035), (3.2, 0.035)], end: 4).fires.count == 2, "cooldown permits a later pair")
    // Vary cadence and amplitude; keyboard suppression must not depend on how
    // strongly or rhythmically someone types, including pauses between two keys.
    for i in 0..<40 {
        let interval = 0.18 + Double(i % 8) * 0.055
        let strength = 0.015 + Double(i % 9) * 0.012
        let strokes: [(Double, Double)] = [(1, strength), (1 + interval, strength)]
        check(replay(strokes, keys: [1.012, 1 + interval + 0.012]).fires.isEmpty,
              "keyboard veto with cadence/amplitude case \(i)")
    }
    for hz in [400.0, 800.0, 1000.0] {
        check(replay([(1, 0.010), (1.3, 0.010)], hz: hz).fires.count == 1, "light taps at \(hz) Hz")
    }
    var noiseSettings = TapSettings(); noiseSettings.minPeak = 0.009
    check(replay([(0.8, 0.008)] + pair, settings: noiseSettings).fires.count == 1, "small preceding vibration must not poison quiet window")
    check(replay([(1, 0.035), (1.18, 0.008), (1.4, 0.035)], settings: noiseSettings).fires.count == 1, "small inter-tap vibration must not erase the first tap")
    check(replay([(1, 0.010), (1.3, 0.010)], keys: [1.01, 1.31]).fires.isEmpty, "light keystrokes remain suppressed")
    if !failures.isEmpty {
        throw NSError(domain: "TapTests", code: failures.count,
                      userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
    }
    print("PASS: raw-sample tap engine, keyboard/click veto, ringing, third-onset cancellation, sensor gaps, sample rates, triple mode, cooldown")
}

// These windows are the 16 intended pairs visible in the existing tap recording.
// Assertions stay separate from synthetic keyboard-veto tests: this recording
// cannot demonstrate keyboard suppression because it has no input-event channel.
func validateTapRecording(_ directory: String) throws {
    let pairs = [1.191, 3.285, 5.244, 7.590, 9.538, 11.455, 13.638, 15.308,
                 16.966, 18.543, 20.721, 22.441, 24.443, 25.967, 28.415, 30.352]
    let result = try replayTapCSV(directory + "/tap.csv")
    guard result.fires.count == pairs.count,
          zip(result.fires, pairs).allSatisfy({ fired, second in fired > second && fired < second + 0.75 }) else {
        throw NSError(domain: "TapReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recorded pairs were missed, duplicated, or fired too late"])
    }
    for name in ["still", "handling"] {
        guard try replayTapCSV(directory + "/" + name + ".csv").fires.isEmpty else {
            throw NSError(domain: "TapReplay", code: 2, userInfo: [NSLocalizedDescriptionKey: name + " unexpectedly triggered"])
        }
    }
    print("PASS: 16 recorded tap pairs each matched once, with no still/handling triggers")
}


@MainActor
func runTapPreferenceTests() {
    let suite = "ChillorReply.tap.test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = TapTrigger(preferences: defaults)
    precondition(first.enabled && first.sensitivity == 2 && first.taps == 2)
    // No hardware is started by construction: unit tests only exercise preferences.
    first.enabled = false; first.sensitivity = 0; first.taps = 3
    let reopened = TapTrigger(preferences: defaults)
    precondition(!reopened.enabled && reopened.sensitivity == 0 && reopened.taps == 3)
    reopened.enabled = true; reopened.stop()
    let afterQuit = TapTrigger(preferences: defaults)
    precondition(afterQuit.enabled, "Stopping the sensor at quit must not turn off the saved preference")
    afterQuit.testOnly = true
    precondition(!TapTrigger(preferences: defaults).testOnly, "Diagnostic mode must not silently disable capture next launch")
    defaults.set(999, forKey: "ChillorReply.tap.sensitivity")
    defaults.set(1, forKey: "ChillorReply.tap.count")
    let invalid = TapTrigger(preferences: defaults)
    precondition(invalid.sensitivity == 2 && invalid.taps == 2)
    defaults.removePersistentDomain(forName: suite)
    precondition(TapTrigger(preferences: defaults).enabled, "Clean preferences restore the default-on behavior")
    print("PASS: tap defaults on, saved off/on/sensitivity/count, quit preservation, safe diagnostic restart and clean-install defaults")
}
