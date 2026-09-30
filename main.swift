import Cocoa
import SwiftUI
import ApplicationServices
import ScreenCaptureKit
import Vision
import Carbon

// Capture stays local; inference uses an app-owned loopback service only.
struct TextItem {
    let text: String
    let rect: CGRect?
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func elementRect(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

func ownText(_ element: AXUIElement) -> String {
    var chunks: [String] = []
    for name in [kAXSelectedTextAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let string = attribute(element, name) as? String {
            let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !chunks.contains(clean) { chunks.append(clean) }
        }
    }
    return chunks.joined(separator: "\n")
}

func collect(_ root: AXUIElement, limit: Int, visibleIn window: CGRect?) -> [TextItem] {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var cursor = 0
    var output: [TextItem] = []
    var seen = Set<String>()
    while cursor < queue.count && cursor < limit {
        let (node, depth) = queue[cursor]
        cursor += 1
        let rect = elementRect(node)
        if let r = rect, let window, !r.intersects(window) { continue }
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        if ![kAXButtonRole, kAXMenuButtonRole, kAXToolbarRole, kAXScrollBarRole].contains(role) {
            let value = ownText(node)
            if !value.isEmpty && value.count < 16000 && seen.insert(value).inserted {
                output.append(TextItem(text: value, rect: rect))
            }
        }
        if depth < 14, let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(max(0, limit - queue.count)).map { ($0, depth + 1) })
        }
    }
    return output.sorted { ($0.rect?.minY ?? 0, $0.rect?.minX ?? 0) < ($1.rect?.minY ?? 0, $1.rect?.minX ?? 0) }
}

struct AXCapture {
    var target = ""
    var context = ""
    var rect: CGRect?
    var windowRect: CGRect?
    var app = ""
    var pid: pid_t = 0
    var items: [TextItem] = []
}

func inspectAt(_ point: CGPoint) -> AXCapture {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.4)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return AXCapture() }
    var result = AXCapture()
    AXUIElementGetPid(hit, &result.pid)
    result.app = NSRunningApplication(processIdentifier: result.pid)?.localizedName ?? "当前应用"
    result.rect = elementRect(hit)
    result.target = ownText(hit)
    var windowElement: AXUIElement?
    if let value = attribute(hit, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
        windowElement = unsafeBitCast(value, to: AXUIElement.self)
        result.windowRect = elementRect(windowElement!)
    }
    // Walk only a few local containers: this is a candidate, never a verified thread.
    var current = hit
    var nearby = ""
    for _ in 0..<7 {
        let role = attribute(current, kAXRoleAttribute) as? String ?? ""
        if role == kAXWindowRole || role == kAXApplicationRole { break }
        let items = collect(current, limit: 90, visibleIn: result.windowRect)
        let text = items.map(\.text).joined(separator: "\n\n")
        if result.target.isEmpty && !text.isEmpty && text.count < 2500 { result.target = text }
        if text.count > nearby.count && text.count <= 12000 { nearby = text; result.items = items }
        if text.count > 12000 { break }
        guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        current = unsafeBitCast(parent, to: AXUIElement.self)
    }
    if nearby.isEmpty, let windowElement {
        result.items = collect(windowElement, limit: 180, visibleIn: result.windowRect)
        nearby = result.items.map(\.text).joined(separator: "\n\n")
    }
    result.context = String(nearby.prefix(14000))
    return result
}

func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(dx, dy)
}

func nearestOCR(_ items: [TextItem], point: CGPoint) -> String {
    guard let nearest = items.min(by: { distance(point, $0.rect!) < distance(point, $1.rect!) }),
          let rect = nearest.rect, distance(point, rect) < 180 else { return "" }
    // Group nearby aligned lines; users can correct the candidate in the editor.
    var chosen = [nearest]
    var extent = rect
    for _ in 0..<5 {
        let extra = items.filter { item in
            guard let r = item.rect else { return false }
            return !chosen.contains(where: { $0.rect == item.rect && $0.text == item.text }) &&
                abs(r.minX - rect.minX) < 45 && r.minY < extent.maxY + 16 && r.maxY > extent.minY - 16
        }
        if extra.isEmpty { break }
        for item in extra { extent = extent.union(item.rect!); chosen.append(item) }
    }
    return chosen.sorted { $0.rect!.minY < $1.rect!.minY }.map(\.text).joined(separator: "\n")
}

func recognize(_ image: CGImage, frame: CGRect) throws -> [TextItem] {
    let english = VNRecognizeTextRequest()
    let mixed = VNRecognizeTextRequest()
    english.recognitionLanguages = ["en-US"]
    mixed.recognitionLanguages = ["zh-Hans", "en-US"]
    // 0.003 asked Vision to find ~7px text on a 2x capture: many extra pyramid
    // levels, hundreds of megabytes, and nothing recovered on real chat UI.
    let minHeight = minimumTextHeight(for: image.height)
    for request in [english, mixed] {
        request.recognitionLevel = .accurate
        request.minimumTextHeight = minHeight
        request.usesLanguageCorrection = true
    }
    // One perform with both requests keeps two full pyramids alive at the same
    // time. Separate pools halve the peak footprint for the same output.
    try autoreleasepool { try VNImageRequestHandler(cgImage: image).perform([english]) }
    try autoreleasepool { try VNImageRequestHandler(cgImage: image).perform([mixed]) }
    func lines(_ request: VNRecognizeTextRequest) -> [TextItem] {
        (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let b = observation.boundingBox
            let rect = CGRect(x: frame.minX + b.minX * frame.width, y: frame.minY + (1 - b.maxY) * frame.height, width: b.width * frame.width, height: b.height * frame.height)
            return TextItem(text: text, rect: rect)
        }
    }
    // Chinese-first recognition can corrupt Latin words. Retain the English pass for
    // Latin lines, replacing overlapping fragments only where Chinese was detected.
    var merged = lines(english)
    for line in lines(mixed) where line.text.range(of: "[\\p{Han}]{2}", options: .regularExpression) != nil {
        merged.removeAll { item in
            let overlap = line.rect!.intersection(item.rect!)
            return !overlap.isNull && area(overlap) / max(1, min(area(line.rect!), area(item.rect!))) > 0.45
        }
        merged.append(line)
    }
    return merged.sorted { $0.rect!.minY < $1.rect!.minY }
}

// Measured, not guessed. Every capture reports where its milliseconds went.
struct Timeline {
    private let began = CFAbsoluteTimeGetCurrent()
    private var last = CFAbsoluteTimeGetCurrent()
    private var spans: [(String, Double)] = []
    mutating func mark(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        spans.append((name, (now - last) * 1000)); last = now
    }
    func summary() -> String {
        let total = (CFAbsoluteTimeGetCurrent() - began) * 1000
        let parts = spans.map { String(format: "%@ %.0f", $0.0, $0.1) }.joined(separator: " · ")
        return String(format: "抓取合计 %.0f ms → ", total) + parts
    }
}

@MainActor
final class CaptureModel: ObservableObject {
    @Published var tab = 0
    @Published var target = ""
    @Published var messages: [MessageCandidate] = []
    @Published var targetIDs = Set<UUID>()
    @Published var previewFrame = CGRect.zero
    // The region that decided which candidates count. Kept separate from the
    // preview so the preview can show the whole window and still make it visible
    // where the heuristic looked.
    @Published var focusFrame = CGRect.zero
    @Published var timing = ""
    // A heuristic on the first line, so it stays editable rather than authoritative.
    @Published var sender = ""
    @Published var status = "把鼠标移到一条消息上，按 ⌃⌥Space。"
    @Published var source = "尚未抓取"
    @Published var appName = ""
    @Published var busy = false
    @Published var screenshot: NSImage?
    @Published var isDemo = false
    @Published var captureImage = true
    @Published var axGranted = AXIsProcessTrusted()
    @Published var screenGranted = CGPreflightScreenCaptureAccess()
    var anchorPoint = CGPoint.zero
    var showWindow: (() -> Void)?
    var hideWindow: (() -> Void)?
    var beginCapture: (() -> Void)?
    var willCapture: (() -> Void)?
    var didCapture: (() -> Void)?

    // Stored, not computed. SwiftUI reads context through onChange on every body
    // pass; joining every selected message there was real work inside the layout loop.
    @Published private(set) var context = ""
    @Published private(set) var selectedCount = 0
    private func refreshDerived() {
        context = checkedContext(messages, excluding: targetIDs)
        selectedCount = messages.filter { $0.included && !targetIDs.contains($0.id) }.count
    }
    func clearContextSelection() {
        for i in messages.indices where !targetIDs.contains(messages[i].id) { messages[i].included = false }
        refreshDerived()
    }
    func selectTarget(_ message: MessageCandidate) {
        targetIDs = [message.id]
        target = message.text
        sender = senderName(in: message.text) ?? ""
        if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i].included = false }
        refreshDerived()
    }
    func appendToTarget(_ message: MessageCandidate) {
        if targetIDs.contains(message.id) { return }
        targetIDs.insert(message.id)
        target += (target.isEmpty ? "" : "\n\n") + message.text
        if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i].included = false }
        refreshDerived()
    }
    func setIncluded(_ id: UUID, _ value: Bool) {
        if let i = messages.firstIndex(where: { $0.id == id }), !targetIDs.contains(id) { messages[i].included = value }
        refreshDerived()
    }
    func useCandidates(_ candidates: [MessageCandidate], point: CGPoint, in frame: CGRect) {
        messages = candidates
        targetIDs = []
        if let selected = chooseTarget(candidates, point: point) {
            selectTarget(selected)
            let documentIDs = documentTargetIDs(candidates, target: selected)
            if documentIDs.count > 1 {
                targetIDs = documentIDs
                target = candidates.filter { documentIDs.contains($0.id) }
                    .sorted { $0.rect.minY < $1.rect.minY }.map(\.text).joined(separator: "\n\n")
                sender = ""
                for i in messages.indices { messages[i].included = false }
            } else {
                let nearby = automaticContextIDs(candidates, target: selected, in: frame)
                for i in messages.indices { messages[i].included = nearby.contains(messages[i].id) }
            }
        }
        refreshDerived()
    }
    func loadDemo() async {
        beginCapture?(); willCapture?(); isDemo = true
        busy = true
        defer { busy = false; if !target.isEmpty { tab = 1; didCapture?() }; showWindow?() }
        let image = fixtureImage()
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 720)
        do {
            let candidates = try await Task.detached {
                candidateMessages(try recognize(image, frame: frame), image: image, frame: frame)
            }.value
            previewFrame = frame
            focusFrame = .zero
            screenshot = NSImage(cgImage: image, size: frame.size)
            useCandidates(candidates, point: CGPoint(x: 170, y: 120), in: frame)
            appName = "内置示例（虚构消息）"
            source = "本地 OCR + 气泡识别"
            status = "示例：已选中目标及附近候选上下文，自动翻译并起草。可取消无关上下文。"
        } catch { status = "示例识别失败：\(error.localizedDescription)" }
    }

    func refreshPermissions() {
        axGranted = AXIsProcessTrusted()
        screenGranted = CGPreflightScreenCaptureAccess()
    }
    func requestAX() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func delayCapture() {
        hideWindow?()
        status = "请在 3 秒内把鼠标移到目标消息上…"
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await capture()
        }
    }
    func clear() {
        isDemo = false
        willCapture?()
        target = ""; messages = []; targetIDs = []; screenshot = nil; appName = ""; source = "尚未抓取"; focusFrame = .zero; sender = ""
        refreshDerived()
        status = "本次内容已清除。"
    }
    func capture() async {
        guard !busy else { return }
        anchorPoint = CGEvent(source: nil)?.location ?? .zero
        beginCapture?(); willCapture?(); isDemo = false; tab = 0
        busy = true
        defer { busy = false; if !target.isEmpty { tab = 1; didCapture?() }; showWindow?() }
        refreshPermissions()
        // Let the window server retire the old overlay before hit-testing its area.
        try? await Task.sleep(nanoseconds: 60_000_000)
        var clock = Timeline()
        let point = anchorPoint
        screenshot = nil; target = ""; messages = []; targetIDs = []; appName = ""; focusFrame = .zero; timing = ""; sender = ""
        refreshDerived()
        status = "正在本机读取…"
        var ax = AXCapture()
        if axGranted {
            ax = await Task.detached { inspectAt(point) }.value
            clock.mark("辅助功能遍历")
            if ax.pid == getpid() {
                status = "鼠标指向了助手自己。请移到聊天消息，再按快捷键。"
                return
            }
            target = ax.target; appName = ax.app
            if let frame = ax.windowRect {
                let candidates = candidateMessages(ax.items, image: nil, frame: frame)
                useCandidates(candidates, point: point, in: frame)
            }
        }
        source = target.isEmpty ? "尚未取得目标文字" : "辅助功能读取 · 目标为候选内容"
        if captureImage && screenGranted {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windowsAtPoint = content.windows.filter { window in
                    window.windowLayer == 0 && window.frame.contains(point) && window.owningApplication?.processID != getpid() && window.frame.width > 120 && window.frame.height > 80
                }
                clock.mark("枚举窗口")
                let orderedInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let orderedIDs = orderedInfo.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
                let frontToBack = windowsAtPoint.sorted { (orderedIDs.firstIndex(of: $0.windowID) ?? Int.max) < (orderedIDs.firstIndex(of: $1.windowID) ?? Int.max) }
                let sameApp = frontToBack.filter { $0.owningApplication?.processID == ax.pid }
                let window = sameApp.first ?? frontToBack.first
                guard let window else {
                    status = "没有找到鼠标下的可抓取窗口。已有文字仍可检查。"
                    return
                }
                if appName.isEmpty { appName = window.owningApplication?.applicationName ?? "当前窗口" }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let scale = captureScale(for: window.frame)
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                clock.mark("截图")
                // Everything after this point is local computation that does not need the
                // other app in front. Showing the window here instead of in the defer is
                // the difference between "no reaction" and "it heard me".
                status = "正在本机识别文字…"
                showWindow?()
                let frame = window.frame
                let items: [TextItem] = try await Task.detached { try recognize(captured, frame: frame) }.value
                clock.mark("OCR 两遍")
                let candidates = await Task.detached { candidateMessages(items, image: captured, frame: frame) }.value
                clock.mark("气泡分组")
                let chosen = chooseTarget(candidates, point: point)
                // The focus region still bounds which candidates count, including the
                // whole detected target however wide or multi-paragraph it is. The
                // preview now shows the entire window so the message is placed in
                // context and a stray box in a sidebar is obvious at a glance.
                var region = CGRect(x: point.x - 500, y: point.y - 380, width: 1000, height: 760).intersection(frame)
                if let chosen {
                    let completeIDs = documentTargetIDs(candidates, target: chosen)
                    for item in candidates where completeIDs.contains(item.id) {
                        region = region.union(item.rect.insetBy(dx: -35, dy: -50)).intersection(frame)
                    }
                }
                focusFrame = region
                previewFrame = frame
                screenshot = NSImage(cgImage: captured, size: frame.size)
                if !candidates.isEmpty {
                    let relevant = candidates.filter { $0.rect.intersects(region) }
                    useCandidates(relevant, point: point, in: frame)
                    source = "本地 OCR · \(chosen?.method ?? "候选消息") · \(relevant.count) 个候选"
                }
            } catch {
                status = "截图未成功：\(error.localizedDescription)。可以检查已有文字；刚授权后请退出并重新打开。"
                return
            }
        }
        timing = clock.summary()
        if target.isEmpty && messages.isEmpty {
            status = axGranted || screenGranted ? "未读到内容。请指向消息正文重试，或开启截图识别。" : "请先开启辅助功能或屏幕录制权限，再抓取。"
        } else {
            status = "已选中目标和附近上下文，自动翻译并起草。无关内容可取消勾选，漏段可并入目标。"
        }
    }
}

func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

struct CandidateRow: View, Equatable {
    // Every row used to observe the whole capture model, so one status string
    // change re-rendered and re-measured all of them.
    static func == (a: CandidateRow, b: CandidateRow) -> Bool {
        a.message == b.message && a.index == b.index && a.isTarget == b.isTarget
    }
    let message: MessageCandidate
    let index: Int
    let isTarget: Bool
    let onInclude: (Bool) -> Void
    let onSelect: () -> Void
    let onAppend: () -> Void
    var tint: Color { isTarget ? .blue : message.included ? .orange : .gray }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isTarget ? "\(index + 1) · 目标消息" : "\(index + 1) · 加入上下文", isOn: Binding(get: { message.included }, set: { onInclude($0) }))
                    .toggleStyle(.checkbox).disabled(isTarget)
                Spacer()
                Text(message.method).font(.caption2).foregroundStyle(.secondary)
            }
            // Bounded height. Unbounded self-sizing text inside a resizable split
            // pane is what drove the repeated measurement passes.
            Text(previewText(message.text)).font(.system(size: 13)).textSelection(.enabled)
                .lineLimit(10).fixedSize(horizontal: false, vertical: true)
            if !isTarget {
                HStack {
                    Button("设为目标") { onSelect() }
                    Button("并入目标") { onAppend() }
                }.font(.caption)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(isTarget || message.included ? 0.07 : 0.025))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.25)))
    }
}

struct MainView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var tap: TapTrigger
    @State private var previewZoom: CGFloat = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ReplyLens 0.7 · 消息选择").font(.system(size: 23, weight: .semibold))
                    Text("指向消息 → ⌃⌥Space → 自动翻译与起草").foregroundStyle(.secondary)
                }
                Spacer()
                Text("仅本机 · 不上传").font(.caption.weight(.medium)).padding(8).background(.green.opacity(0.10)).clipShape(Capsule())
            }
            HStack {
                Button(model.axGranted ? "✓ 辅助功能已开启" : "开启辅助功能") { model.requestAX() }
                Button(model.screenGranted ? "✓ 屏幕录制已开启" : "开启屏幕录制") { model.requestScreen() }
                Button("刷新权限") { model.refreshPermissions() }
                Spacer()
                Toggle("补充截图与本地 OCR", isOn: $model.captureImage).toggleStyle(.checkbox)
            }.font(.callout)
            if tap.available {
                HStack {
                    Toggle("拍机身触发", isOn: $tap.enabled).toggleStyle(.checkbox)
                    Picker("", selection: $tap.taps) {
                        Text("拍两下").tag(2); Text("拍三下").tag(3)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 130).disabled(!tap.enabled)
                    Picker("", selection: $tap.sensitivity) {
                        Text("保守").tag(0); Text("标准").tag(1); Text("灵敏").tag(2); Text("极灵敏").tag(3)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240).disabled(!tap.enabled)
                    Spacer()
                }.font(.callout)
                HStack {
                    Toggle("只测试拍击，不抓取消息", isOn: $tap.testOnly).toggleStyle(.checkbox)
                    Text("识别 \(tap.testCount) 次").font(.caption.monospacedDigit())
                    Button("清零") { tap.resetTestCount() }.font(.caption)
                    Spacer()
                }
                Text("手指连拍掌托或侧边，打字结束后稍停再拍。检测只读取按键活动时间，不读取输入内容。")
                    .font(.caption).foregroundStyle(.secondary)
                // A heuristic the user has to tune is a heuristic they need to see.
                HStack {
                    if tap.enabled {
                        // A gesture recogniser that silently declines is impossible to
                        // learn. It says which rule it failed, and on what numbers.
                        Text(tap.gestureNote.isEmpty
                             ? String(format: "连着拍 %d 下 · 打字后等待 0.3 秒 · 门槛 %.3f g", tap.taps, tap.currentThreshold)
                             : tap.gestureNote)
                            .font(.caption.monospacedDigit())
                            // Explicit Color on every branch: a ternary mixing Color
                            // with the .secondary hierarchical style has no common type.
                            .foregroundStyle(tap.gestureNote.hasPrefix("已识别") ? Color.green
                                             : tap.handling ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("默认关闭：误触发会白跑一次完整生成").font(.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer()
                }
            }
            HStack {
                Button("隐藏窗口，3 秒后抓取") { model.delayCapture() }.buttonStyle(.borderedProminent).disabled(model.busy)
                Button("查看示例") { Task { await model.loadDemo() } }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("清除内容") { model.clear() }.disabled(model.busy)
            }
            Text(model.status).font(.callout).foregroundStyle(model.target.isEmpty ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
            if !model.appName.isEmpty { Text("\(model.appName)  ·  \(model.source)").font(.caption).foregroundStyle(.secondary) }
            if !model.timing.isEmpty { Text(model.timing).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("目标消息 · 可直接修正").font(.headline)
                        Spacer()
                        Text("蓝框").font(.caption).foregroundStyle(.blue)
                    }
                    TextEditor(text: $model.target).font(.system(size: 14)).padding(8).background(Color.blue.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.25))).frame(minHeight: 140, maxHeight: 200)
                    HStack(spacing: 8) {
                        Text("发件人").font(.caption).foregroundStyle(.secondary)
                        TextField("自动识别，可修正", text: $model.sender).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                        Text(model.sender.isEmpty ? "留空则回复不带称呼" : "回复会用这个名字称呼对方").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack {
                        Text("上下文 · 已选 \(model.selectedCount) 条").font(.headline)
                        Spacer()
                        Button("取消勾选") { model.clearContextSelection() }.font(.caption)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.messages.isEmpty {
                                Text("抓取后逐条显示候选消息。\n自动选择附近消息；相邻不代表属于同一个 thread，可取消无关内容。").foregroundStyle(.secondary).padding(12)
                            }
                            ForEach(Array(model.messages.prefix(60).enumerated()), id: \.element.id) { index, message in
                                CandidateRow(message: message, index: index, isTarget: model.targetIDs.contains(message.id),
                                             onInclude: { model.setIncluded(message.id, $0) },
                                             onSelect: { model.selectTarget(message) },
                                             onAppend: { model.appendToTarget(message) }).equatable()
                            }
                            if model.messages.count > 60 {
                                Text("另有 \(model.messages.count - 60) 条候选未显示。缩小抓取范围可减少噪声。").font(.caption).foregroundStyle(.secondary).padding(8)
                            }
                        }
                    }
                    Button("复制目标与上下文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("目标消息：\n\(model.target)\n\n已勾选的上下文：\n\(model.context.isEmpty ? "（未选择额外上下文）" : model.context)", forType: .string)
                    }.disabled(model.target.isEmpty && model.context.isEmpty)
                }.frame(minWidth: 370).padding(.trailing, 10)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("截图对照 · 整个窗口").font(.headline)
                        Spacer()
                        Picker("", selection: $previewZoom) {
                            Text("适应").tag(CGFloat(1))
                            Text("1.5×").tag(CGFloat(1.5))
                            Text("2×").tag(CGFloat(2))
                            Text("3×").tag(CGFloat(3))
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                    }
                    Text("蓝框目标 · 橙框上下文 · 虚线是候选筛选范围").font(.caption).foregroundStyle(.secondary)
                    if let screenshot = model.screenshot {
                        ScrollView([.horizontal, .vertical]) {
                            let width: CGFloat = 520 * previewZoom
                            let ratio = width / max(1, model.previewFrame.width)
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: screenshot).resizable().frame(width: width, height: model.previewFrame.height * ratio)
                                let focus = model.focusFrame.intersection(model.previewFrame)
                                if !focus.isNull && focus.width > 1 && focus.height > 1 {
                                    Rectangle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(.secondary)
                                        .frame(width: focus.width * ratio, height: focus.height * ratio)
                                        .offset(x: (focus.minX - model.previewFrame.minX) * ratio, y: (focus.minY - model.previewFrame.minY) * ratio)
                                        .allowsHitTesting(false)
                                }
                                ForEach(Array(model.messages.prefix(60).enumerated()), id: \.element.id) { index, message in
                                    let active = model.targetIDs.contains(message.id)
                                    let rect = message.rect.intersection(model.previewFrame)
                                    if (active || message.included) && !rect.isNull {
                                        Rectangle().fill((active ? Color.blue : Color.orange).opacity(0.07))
                                            .overlay(Rectangle().stroke(active ? Color.blue : Color.orange, lineWidth: 2))
                                            .overlay(alignment: .topLeading) { Text("\(index + 1)").font(.caption2.bold()).padding(3).background(active ? Color.blue : Color.orange).foregroundStyle(.white) }
                                            .frame(width: rect.width * ratio, height: rect.height * ratio)
                                            .offset(x: (rect.minX - model.previewFrame.minX) * ratio, y: (rect.minY - model.previewFrame.minY) * ratio)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "text.viewfinder").font(.system(size: 42)).foregroundStyle(.secondary)
                            Text("抓取后在这里显示整个窗口，对照原消息\n截图只保留在内存，清除或退出即释放").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 300).padding(.leading, 10)
            }
            Text("本地读取 · 不保存聊天历史。气泡与段落分组仍需核对；附近上下文自动选入，可手动调整；不代表已验证 thread。抓取后自动翻译并起草。").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 880, minHeight: 650)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CaptureModel()
    let reply = ReplyModel()
    let memory = MemoryStore()
    let runtime = LocalRuntime()
    let tap = TapTrigger()
    let overlay = ResultOverlay()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var hotkey: EventHotKeyRef?
    var replyHotkey: EventHotKeyRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        reply.memory = memory
        NSApp.setActivationPolicy(.regular)
        let appMenu = NSMenu()
        let root = NSMenuItem()
        appMenu.addItem(root)
        let submenu = NSMenu()
        submenu.addItem(withTitle: L("关于 Chillor Reply"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        submenu.addItem(withTitle: L("设置…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        submenu.addItem(withTitle: L("新回复"), action: #selector(newReply), keyEquivalent: "n").target = self
        submenu.addItem(.separator())
        submenu.addItem(withTitle: L("退出 Chillor Reply"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = submenu
        let editRoot = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: L("编辑"))
        edit.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editRoot.submenu = edit; appMenu.addItem(editRoot); NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Chillor Reply"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.setFrameAutosaveName("ChillorReply.workspace")
        window.contentView = NSHostingView(rootView: ChillorWorkspace(capture: model, reply: reply, runtime: runtime, tap: tap, memory: memory))
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: Notification.Name("ChillorReply.readInput"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reply.delayedRead?() } }
        model.showWindow = { [weak self] in self?.showResult() }
        model.hideWindow = { [weak self] in self?.overlay.dismiss(); self?.window.orderOut(nil); NSApp.hide(nil) }
        model.beginCapture = { [weak self] in self?.overlay.begin(); self?.window.orderOut(nil) }
        model.willCapture = { [weak self] in
            guard let self else { return }; let privacy = self.reply.privateReply
            self.reply.clear(); self.reply.privateReply = privacy
        }
        model.didCapture = { [weak self] in
            guard let self else { return }
            self.reply.updateSource(original: self.model.target, context: self.model.context, sender: self.model.sender, immediate: true, app: self.model.appName, memoryEligible: !self.model.isDemo)
        }
        reply.delayedRead = { [weak self] in
            guard let self else { return }
            self.window.orderOut(nil); NSApp.hide(nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                self.readInputResult()
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Chillor Reply")
        let menu = NSMenu()
        menu.addItem(withTitle: L("打开 Chillor Reply"), action: #selector(show), keyEquivalent: "") .target = self
        menu.addItem(withTitle: L("3 秒后抓取"), action: #selector(delayed), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return noErr }
            let action = id.id
            Task { @MainActor in
                if let delegate = NSApp.delegate as? AppDelegate {
                    if action == 2 { delegate.readInputResult() }
                    else { await delegate.model.capture() }
                }
            }
            return noErr
        }, 1, &event, nil, nil)
        let code = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x524C454E, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        let replyCode = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x524C454E, id: 2), GetApplicationEventTarget(), 0, &replyHotkey)
        if replyCode != noErr { reply.status = "输入框快捷键注册失败，请直接在这里起草。" }
        tap.onDoubleTap = { [weak self] in
            // A new tap may interrupt generation, just like the capture shortcut.
            // CaptureModel alone prevents overlapping AX/OCR captures.
            guard let self else { return }
            Task { @MainActor in await self.model.capture() }
        }
        tap.activate()
        if CommandLine.arguments.contains("--tap-test-mode") {
            tap.testOnly = true
            if tap.available { tap.enabled = true }
        }
        Task { await runtime.start(); reply.setModelReady(runtime.ready); runtime.autoDownloadIfNeeded(); await runtime.warm() }
        if code != noErr { model.status = "快捷键注册失败，请使用“3 秒后抓取”按钮。" }
        show()
        if CommandLine.arguments.contains("--demo") { Task { await model.loadDemo(); self.show() } }
        if CommandLine.arguments.contains("--overlay-demo") { Task { model.anchorPoint = CGEvent(source: nil)?.location ?? .zero; await model.loadDemo(); self.showResult() } }
    }
    @objc func openSettings() { show(); NotificationCenter.default.post(name: .chillorSettings, object: nil) }
    @objc func newReply() { show(); NotificationCenter.default.post(name: .chillorNew, object: nil) }
    func showResult() { overlay.show(capture: model, reply: reply, runtime: runtime, expand: { [weak self] in self?.show() }) }
    func readInputResult() {
        model.clear(); overlay.begin(); window.orderOut(nil)
        model.anchorPoint = CGEvent(source: nil)?.location ?? .zero
        reply.readInput(); model.tab = 1; showResult()
    }
    @objc func show() { overlay.dismiss(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); model.refreshPermissions() }
    @objc func delayed() { model.delayCapture() }
    func applicationWillTerminate(_ notification: Notification) { reply.checkpoint(); memory.flush(); runtime.stop(); tap.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

func selfTest() throws {
    func check(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    let image = NSImage(size: NSSize(width: 1000, height: 600))
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1000, height: 600)).fill()
    let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
    ("Frieda: Could we add another voice?" as NSString).draw(at: CGPoint(x: 60, y: 470), withAttributes: style)
    ("We will consider it, without making a commitment." as NSString).draw(at: CGPoint(x: 60, y: 300), withAttributes: style)
    ("我们会考虑，但不承诺一定支持。" as NSString).draw(at: CGPoint(x: 60, y: 140), withAttributes: style)
    image.unlockFocus()
    var rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { fatalError("No test image") }
    let frame = CGRect(x: -300, y: 150, width: 1000, height: 600)
    let items = try recognize(cg, frame: frame)
    let all = items.map(\.text).joined(separator: "\n")
    check(all.contains("another voice"), "English OCR missing: \(all)")
    check(all.contains("我们会考虑"), "Chinese OCR missing: \(all)")
    let selected = nearestOCR(items, point: CGPoint(x: -180, y: 430))
    check(selected.contains("without making a commitment"), "Pointer coordinate mapping failed: \(selected); \(items.map { "\($0.text) \(String(describing: $0.rect))" })")
    check(!selected.contains("Frieda"), "Unrelated message included")
    check(nearestOCR(items, point: CGPoint(x: 2000, y: 2000)).isEmpty, "Far pointer should not select")
    print("PASS: local English/Chinese OCR, nonzero/negative screen coordinates, pointed message isolation, distant pointer rejection")
}

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--memory-test") {
        Task { @MainActor in do { try await runMemoryTests(); exit(0) } catch { fputs("Memory test failed: \(error)\n", stderr); exit(1) } }; NSApplication.shared.run(); exit(0)
    }
    if CommandLine.arguments.contains("--localization-test") { runLocalizationTests(); exit(0) }
    if let i = CommandLine.arguments.firstIndex(of: "--document-regression-image"), CommandLine.arguments.count > i + 1 {
        do { try documentRegressionImage(CommandLine.arguments[i + 1]); exit(0) } catch { fputs("Document regression failed: \(error)\n", stderr); exit(1) }
    }
    if CommandLine.arguments.contains("--self-test") {
        do { try selfTest(); try runDetectionTests(); runReplyTests(); runOverlayTests(); exit(0) } catch { fputs("Self test failed: \(error)\n", stderr); exit(1) }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--regression-image"), CommandLine.arguments.count > i + 1 {
        do { try regressionImage(CommandLine.arguments[i + 1]); exit(0) } catch { fputs("Regression failed: \(error)\n", stderr); exit(1) }
    }
    let app = NSApplication.shared
    if let i = CommandLine.arguments.firstIndex(of: "--tap-replay"), CommandLine.arguments.count > i + 1 {
        do {
            try runTapDetectorTests()
            let directory = CommandLine.arguments[i + 1]
            if CommandLine.arguments.contains("--check-reference") { try validateTapRecording(directory) }
            for name in ["still", "tap", "typing", "handling", "desk"] {
                let result = try replayTapCSV(directory + "/" + name + ".csv")
                print("\(name): \(result.fires.count) triggers / \(String(format: "%.1f", result.seconds)) seconds; sensor-only recording, no keyboard labels")
            }
            exit(0)
        } catch { fputs("Tap replay failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    if CommandLine.arguments.contains("--tap-health") {
        Task { @MainActor in
            var received = false
            let service = TapSensorService(settings: TapSettings()) { snapshot in
                Task { @MainActor in if snapshot.ready { received = true } }
            }
            service.start()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            service.stop()
            try? await Task.sleep(nanoseconds: 100_000_000)
            print(received ? "PASS: timestamped accelerometer and gyro reports arrive on background queue" : "FAIL: live timestamped motion reports unavailable")
            exit(received ? 0 : 1)
        }
        app.run(); exit(0)
    }
    if CommandLine.arguments.contains("--model-test") || CommandLine.arguments.contains("--automation-test") || CommandLine.arguments.contains("--translation-bench") || CommandLine.arguments.contains("--profile") || CommandLine.arguments.contains("--tap-probe") {
        Task {
            do {
                if CommandLine.arguments.contains("--automation-test") { try await runAutomationTests() }
                else if CommandLine.arguments.contains("--translation-bench") { try await runTranslationBench() }
                else if CommandLine.arguments.contains("--profile") { try await runProfile() }
                else if let index = CommandLine.arguments.firstIndex(of: "--tap-probe") {
                    // --tap-probe [目录]：不给就写 /tmp，省得撞上 Documents 的授权弹窗。
                    let next = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
                    try await runTapProbe(outputDirectory: next?.hasPrefix("--") == false ? next : nil)
                }
                else { try await runModelTests() }
                exit(0)
            }
            catch { fputs("Model test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        app.run()
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
