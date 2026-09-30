import Foundation
import IOKit
import IOKit.hid
import Cocoa
import Darwin

// Apple Silicon MacBooks carry an undocumented MEMS accelerometer on a vendor HID
// page. Nothing about it is in the SDK, so every constant here was read off this
// machine's ioreg output first, and every failure path degrades to "the feature is
// unavailable" rather than to a crash: a rebuilt macOS could move or remove it.
enum Motion {
    static let usagePage = 0xFF00   // vendor page carrying the motion sensors
    static let accelerometer = 3    // usage 3 and usage 9 sit on the same vendor page
    static let gyroscope = 9        // never read until now; gravity moves the accelerometer, not this
    static let reportBytes = 22     // int32 little-endian x, y, z at offsets 6/10/14
    static let scale = 65536.0      // raw units per g
    // The sensor is powered down until someone asks for it. Opening the HID device
    // is not enough: without this the callback simply never fires.
    static let driver = "AppleSPUHIDDriver"
    static let intervalMicroseconds = 1000   // 1 kHz, plenty of resolution for an impact
}

// Waking is a registry property write on the driver, not a HID feature report.
@discardableResult
func wakeMotionSensors() -> Int {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(Motion.driver), &iterator) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iterator) }
    var woken = 0
    var service = IOIteratorNext(iterator)
    while service != 0 {
        IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, NSNumber(value: 1))
        IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, NSNumber(value: 1))
        IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, NSNumber(value: Motion.intervalMicroseconds))
        IOObjectRelease(service)
        woken += 1
        service = IOIteratorNext(iterator)
    }
    return woken
}

// MARK: - detection

typealias Vector = (x: Double, y: Double, z: Double)

// 0.7: keyboard activity is a separate veto. Motion thresholds can therefore
// admit light taps without pretending that acceleration alone identifies typing.
// Tuned on the bundled recording; live recall still needs user validation.
struct TapSettings {
    var detect = 0.0035
    var release = 0.040
    var minPeak = 0.0055
    var maxPeak = 0.20
    var maxWidth = 0.30
    var minSharp = 0.5e-6
    var maxRestSpin = 0.50
    // A coarse movement gate, not a surrogate keyboard detector. The first tap's
    // background is reused throughout a gesture so it cannot veto its successor.
    var maxRestDev = 0.0060
    var taps = 2
    var minGap = 0.16
    var maxGap = 0.65
    var strengthRatio = 6.0
    var quietBefore = 0.25
    var confirm = 0.25
    var cooldown = 1.2
}

struct TapEvent {
    var at = 0.0
    var peak = 0.0
    var width = 0.0
    var sharpness = 0.0
    var restSpin = 0.0
    var restDeviation = 0.0
}

// nil means it looks like a tap. Anything else is the reason it does not, in words
// the user can act on: a recogniser that declines silently cannot be learned.
// What the impulse actually measured. Printed with every verdict, pass or fail:
// guessing which gate rejected a tap costs a build, a permission reset and a round
// trip through the person holding the laptop.
func tapSummary(_ event: TapEvent) -> String {
    String(format: "峰%.3f 宽%.0fms 锐%.1e 背景%.4f/%.2f",
           event.peak, event.width * 1000, event.sharpness, event.restDeviation, event.restSpin)
}

func tapRejection(_ event: TapEvent, _ settings: TapSettings) -> String? {
    if event.peak < settings.minPeak { return String(format: "太轻 %.3f g", event.peak) }
    if event.peak > settings.maxPeak { return String(format: "太重 %.2f g，像是放下机器", event.peak) }
    if event.width > settings.maxWidth { return String(format: "太闷 %.0f ms，像敲桌面", event.width * 1000) }
    if event.sharpness < settings.minSharp { return String(format: "不够脆 %.1e", event.sharpness) }
    if event.restSpin > settings.maxRestSpin { return String(format: "机器在动（陀螺 %.2f）", event.restSpin) }
    if event.restDeviation > settings.maxRestDev { return String(format: "机器在动（振动 %.4f）", event.restDeviation) }
    return nil
}

// All HID reports and recognition run on this serial queue, using hardware
// timestamps. A busy SwiftUI main thread cannot stretch the tap intervals.
final class TapSensorService: @unchecked Sendable {
    struct Snapshot: Sendable {
        var note: String
        var peak: Double
        var fired: Bool
        var ready: Bool
    }
    private let queue = DispatchQueue(label: "ReplyLens.motion", qos: .userInteractive)
    private var detector = TapDetector()
    private var devices: [IOHIDDevice] = []
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var lastPublish = 0.0
    private var lastInputPoll = -Double.infinity
    private var previousFire = -Double.infinity
    private var lastAccel = -Double.infinity
    private var lastGyro = -Double.infinity
    private var started = 0.0
    private var tickScale = 1.0e-9
    private let publish: @Sendable (Snapshot) -> Void
    init(settings: TapSettings, publish: @escaping @Sendable (Snapshot) -> Void) {
        detector.settings = settings; self.publish = publish
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        tickScale = Double(info.numer) / Double(info.denom) / 1e9
    }
    private func now() -> Double { Double(mach_absolute_time()) * tickScale }
    final class ReportContext {
        weak var service: TapSensorService?
        let gyro: Bool
        init(_ service: TapSensorService, gyro: Bool) { self.service = service; self.gyro = gyro }
    }
    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            started = now()
            _ = wakeMotionSensors()
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatchingMultiple(manager, [
                [kIOHIDPrimaryUsagePageKey: Motion.usagePage, kIOHIDPrimaryUsageKey: Motion.accelerometer],
                [kIOHIDPrimaryUsagePageKey: Motion.usagePage, kIOHIDPrimaryUsageKey: Motion.gyroscope],
            ] as CFArray)
            let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
            var hasAccel = false, hasGyro = false
            for device in found {
                let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
                guard usage == Motion.accelerometer || usage == Motion.gyroscope else { continue }
                guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
                hasAccel = hasAccel || usage == Motion.accelerometer
                hasGyro = hasGyro || usage == Motion.gyroscope
                let capacity = max(128, IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 128)
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                let tag = Unmanaged.passRetained(ReportContext(self, gyro: usage == Motion.gyroscope))
                IOHIDDeviceSetDispatchQueue(device, queue)
                IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, capacity, { context, result, _, _, _, report, length, stamp in
                    guard result == kIOReturnSuccess, let context, length >= Motion.reportBytes else { return }
                    let tag = Unmanaged<ReportContext>.fromOpaque(context).takeUnretainedValue()
                    guard let service = tag.service, !service.stopped else { return }
                    func axis(_ offset: Int) -> Double {
                        var value: Int32 = 0
                        memcpy(&value, report.advanced(by: offset), 4)
                        return Double(Int32(littleEndian: value)) / Motion.scale
                    }
                    service.consume((axis(6), axis(10), axis(14)), gyro: tag.gyro,
                                    time: Double(stamp) * service.tickScale)
                }, tag.toOpaque())
                // The report buffer and callback context must outlive ALL callbacks.
                IOHIDDeviceSetCancelHandler(device) {
                    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                    buffer.deallocate(); tag.release()
                }
                devices.append(device); IOHIDDeviceActivate(device)
            }
            guard hasAccel && hasGyro else {
                publish(Snapshot(note: "拍击不可用：需要加速度计和陀螺仪均可读取", peak: 0, fired: false, ready: false))
                close(); return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    private func pollInput(_ time: Double) {
        guard time - lastInputPoll >= 0.008 else { return }
        lastInputPoll = time
        // Only event ages: no event tap, characters, keycodes, or input log.
        let keys: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let clicks: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        for type in keys + clicks {
            let age = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            let keyboard = keys.contains(type)
            if age.isFinite && age >= 0 && age < (keyboard ? 0.30 : 0.20) {
                detector.input(at: time - age, keyboard: keyboard)
            }
        }
    }
    private func consume(_ sample: Vector, gyro: Bool, time: Double) {
        let current = now()
        // Never act on delayed/batched reports after sleep or queue starvation.
        guard time <= current + 0.01, current - time < 0.08 else { detector.reset(); return }
        pollInput(current)
        if gyro { lastGyro = time; detector.gyro(sample, at: time) }
        else { lastAccel = time; detector.accelerometer(sample, at: time) }
    }
    private func tick() {
        guard !stopped else { return }
        let time = now()
        pollInput(time); detector.advance(to: time)
        let ready = time - lastAccel < 0.08 && time - lastGyro < 0.15
        let fire = detector.fires.last ?? -Double.infinity
        let fired = fire > previousFire
        if fired { previousFire = fire }
        guard fired || time - lastPublish > 0.10 else { return }
        lastPublish = time
        let note = ready ? detector.note : (time - started > 2 ? "未收到连续传感器数据，请关闭后重试" : "等待传感器数据…")
        publish(Snapshot(note: note, peak: detector.lastEvent?.peak ?? 0, fired: fired && ready, ready: ready))
    }
    func update(_ settings: TapSettings) {
        queue.async { [self] in detector.settings = settings; detector.reset() }
    }
    private func close() {
        stopped = true; timer?.cancel(); timer = nil
        for device in devices { IOHIDDeviceCancel(device) }
        devices.removeAll(); detector.reset()
    }
    func stop() { queue.async { [self] in close() } }
}

@MainActor
final class TapTrigger: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var status = "未检测运动传感器"
    private let preferences: UserDefaults
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            preferences.set(enabled, forKey: "ChillorReply.tap.enabled")
            if enabled && available { start() } else if !enabled { stop() }
        }
    }
    @Published var sensitivity: Int { didSet { preferences.set(sensitivity, forKey: "ChillorReply.tap.sensitivity"); updateSettings() } }
    @Published var taps: Int { didSet { preferences.set(taps, forKey: "ChillorReply.tap.count"); updateSettings() } }
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = (preferences.object(forKey: "ChillorReply.tap.enabled") as? Bool) ?? true
        let savedSensitivity = (preferences.object(forKey: "ChillorReply.tap.sensitivity") as? Int) ?? 2
        sensitivity = (0...3).contains(savedSensitivity) ? savedSensitivity : 2
        let savedCount = (preferences.object(forKey: "ChillorReply.tap.count") as? Int) ?? 2
        taps = [2, 3].contains(savedCount) ? savedCount : 2
        updateSettings()
    }
    // Restore only after the app has attached its capture callback.
    func activate() { probeAvailability(); if enabled && available { start() } }

    @Published var testOnly = false {
        didSet { if enabled && testOnly != oldValue { start() } }
    }
    @Published private(set) var testCount = 0
    @Published private(set) var lastImpulse = 0.0
    @Published private(set) var handling = false
    @Published private(set) var gestureNote = ""
    var currentThreshold: Double { settings.minPeak }
    var onDoubleTap: (() -> Void)?
    private var service: TapSensorService?
    private var generation = UUID()
    private var settings = TapSettings()
    private func updateSettings() {
        let index = max(0, min(3, sensitivity))
        settings.minPeak = [0.016, 0.010, 0.0055, 0.0045][index]
        settings.detect = settings.minPeak * 0.60
        settings.minSharp = [5e-6, 2e-6, 0.5e-6, 0.3e-6][index]
        settings.taps = max(2, min(3, taps))
        service?.update(settings)
    }
    func probeAvailability() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: Motion.usagePage] as CFDictionary)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let usages = devices.compactMap { IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsageKey as CFString) as? Int }
        available = usages.contains(Motion.accelerometer) && usages.contains(Motion.gyroscope)
        status = available ? "运动传感器可用" : "这台机器缺少可用的运动传感器"
    }
    @discardableResult func start() -> Bool {
        stop(); updateSettings()
        let id = UUID(); generation = id
        let service = TapSensorService(settings: settings) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id, self.enabled else { return }
                if self.status != snapshot.note { self.status = snapshot.note }
                if self.gestureNote != snapshot.note { self.gestureNote = snapshot.note }
                if self.lastImpulse != snapshot.peak { self.lastImpulse = snapshot.peak }
                let moving = snapshot.note.contains("移动") || snapshot.note.contains("打字")
                if self.handling != moving { self.handling = moving }
                if snapshot.fired {
                    self.testCount += 1
                    if !self.testOnly { self.onDoubleTap?() }
                }
            }
        }
        self.service = service; service.start(); return true
    }
    func resetTestCount() { testCount = 0 }
    func stop() {
        generation = UUID(); service?.stop(); service = nil
        gestureNote = ""; handling = false; status = "拍击检测已关闭"
    }
}

// MARK: - measurement

// The probe is a recorder, not a detector. Six rounds of this feature were built by
// reasoning about what a tap ought to look like and then falsified on the machine,
// and each round cost a rebuild and a fresh permission grant. This records the raw
// axes of both sensors against labelled phases and writes them to disk, so every
// candidate rule after this one can be tried offline against real taps and real
// typing as many times as it takes.
@MainActor
final class MotionRecorder {
    struct Sample { var t: Double; var x: Double; var y: Double; var z: Double }

    // The C callback takes one opaque pointer and cannot capture, so each opened
    // device gets a tag saying which sensor it is.
    final class Tag: @unchecked Sendable {
        unowned let owner: MotionRecorder
        let gyro: Bool
        init(_ owner: MotionRecorder, gyro: Bool) { self.owner = owner; self.gyro = gyro }
    }

    private(set) var accel: [Sample] = []
    private(set) var gyro: [Sample] = []
    private(set) var wokenDrivers = 0
    private(set) var foundGyro = false
    private(set) var notes: [String] = []
    private var manager: IOHIDManager?
    private var opened: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>, tag: Tag)] = []

    fileprivate func store(_ sample: Sample, gyro isGyro: Bool) {
        if isGyro { gyro.append(sample) } else { accel.append(sample) }
    }

    // Returns nil on success, or the reason nothing can be recorded.
    func start() -> String? {
        wokenDrivers = wakeMotionSensors()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDPrimaryUsagePageKey: Motion.usagePage, kIOHIDPrimaryUsageKey: Motion.accelerometer],
            [kIOHIDPrimaryUsagePageKey: Motion.usagePage, kIOHIDPrimaryUsageKey: Motion.gyroscope],
        ] as CFArray)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            return "没有找到运动传感器（vendor page 0xFF00）"
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        for device in devices {
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
            guard usage == Motion.accelerometer || usage == Motion.gyroscope else { continue }
            let name = usage == Motion.gyroscope ? "陀螺仪" : "加速度计"
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                notes.append(String(format: "%@ 打不开（IOReturn 0x%08X）", name, UInt32(bitPattern: result)))
                continue
            }
            let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 0
            notes.append("\(name) 已打开 · 最大输入报文 \(size) 字节")
            if usage == Motion.gyroscope { foundGyro = true }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
            let tag = Tag(self, gyro: usage == Motion.gyroscope)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 128, { context, _, _, _, _, report, length in
                guard let context, length >= Motion.reportBytes else { return }
                let tag = Unmanaged<Tag>.fromOpaque(context).takeUnretainedValue()
                func axis(_ offset: Int) -> Double {
                    var value: Int32 = 0
                    memcpy(&value, report.advanced(by: offset), 4)
                    return Double(Int32(littleEndian: value)) / Motion.scale
                }
                let sample = Sample(t: CFAbsoluteTimeGetCurrent(), x: axis(6), y: axis(10), z: axis(14))
                MainActor.assumeIsolated { tag.owner.store(sample, gyro: tag.gyro) }
            }, Unmanaged.passUnretained(tag).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            opened.append((device, buffer, tag))
        }
        return opened.isEmpty ? "找到了传感器但一个都打不开" : nil
    }

    func stop() {
        for entry in opened {
            IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
            entry.buffer.deallocate()
        }
        opened.removeAll()
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
    }

    func slice(_ samples: [Sample], from: Double, to: Double) -> [Sample] {
        samples.filter { $0.t >= from && $0.t <= to }
    }
}

// Teager-Kaiser energy: x[n]^2 - x[n-1]*x[n+1]. Zero for a constant, near zero for
// anything slow, large only when a signal is both fast and big. Gravity and being
// carried are constant or slow, so this is the one statistic that cannot be fooled
// by holding the machine — which is exactly what every threshold so far was fooled by.
// Written as a plain loop with every type spelled out. The one-line map version of
// this is valid Swift that the type checker gives up on: closure inference over
// literal-typed arithmetic is exactly where it goes exponential.
func teagerEnergy(_ values: [Double]) -> [Double] {
    guard values.count > 2 else { return [] }
    var output: [Double] = []
    output.reserveCapacity(values.count - 2)
    for index in 1..<(values.count - 1) {
        let centre: Double = values[index]
        let previous: Double = values[index - 1]
        let next: Double = values[index + 1]
        output.append(centre * centre - previous * next)
    }
    return output
}

func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction)))]
}
