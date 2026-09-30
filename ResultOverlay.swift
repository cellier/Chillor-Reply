import Cocoa
import SwiftUI

// Capture coordinates use Quartz's top-left origin; AppKit uses bottom-left.
enum OverlayPlacement {
    static func point(_ point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }
    static func frame(pointer: CGPoint, target: CGRect, visible: CGRect, size: CGSize) -> CGRect {
        let safe = visible.insetBy(dx: 12, dy: 12)
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        let anchor = target.isEmpty || target.isNull ? CGRect(origin: pointer, size: .zero) : target
        var x = anchor.maxX + 14
        if x + width > safe.maxX { x = anchor.minX - width - 14 }
        if x < safe.minX { x = pointer.x + 18 }
        let y = min(anchor.maxY, pointer.y + 80) - height
        return CGRect(x: min(max(x, safe.minX), safe.maxX - width),
                      y: min(max(y, safe.minY), safe.maxY - height), width: width, height: height)
    }
}

private final class ResultPanel: NSPanel {
    var dismissResult: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismissResult?() }
}

@MainActor final class ResultOverlay {
    private var panel: ResultPanel?
    var isVisible: Bool { panel?.isVisible == true }
    private var allowed = false
    private var eventMonitor: Any?
    private var globalEscape: Any?
    private var localEscape: Any?
    func begin() { dismiss(); allowed = true }
    func dismiss() {
        allowed = false
        panel?.orderOut(nil)
        for monitor in [eventMonitor, globalEscape, localEscape].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        eventMonitor = nil; globalEscape = nil; localEscape = nil
    }
    func show(capture: CaptureModel, reply: ReplyModel, runtime: LocalRuntime, expand: @escaping () -> Void) {
        guard allowed else { return }
        // Keep the position stable while OCR and generation publish more text.
        if panel?.isVisible == true { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let pointer = OverlayPlacement.point(capture.anchorPoint, primaryTop: top)
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return }
        let rects = capture.messages.filter { capture.targetIDs.contains($0.id) }.map(\.rect)
        let quartz = rects.reduce(CGRect.null) { $0.union($1) }
        let target = quartz.isNull ? CGRect.zero : CGRect(x: quartz.minX, y: top - quartz.maxY, width: quartz.width, height: quartz.height)
        let frame = OverlayPlacement.frame(pointer: pointer, target: target, visible: screen.visibleFrame, size: CGSize(width: 440, height: 400))
        let result = ResultPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        result.title = "Chillor Reply"
        result.isReleasedWhenClosed = false; result.isOpaque = false; result.backgroundColor = .clear
        result.level = .floating; result.hasShadow = true; result.hidesOnDeactivate = false
        result.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        result.appearance = NSAppearance(named: .darkAqua)
        result.isMovableByWindowBackground = true
        result.dismissResult = { [weak self] in self?.dismiss() }
        let material = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 22; material.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: FloatingResult(capture: capture, reply: reply, runtime: runtime,
            resize: { [weak self] height in self?.resize(height) }, close: { [weak self] in self?.dismiss() }, expand: { [weak self] in self?.dismiss(); expand() }))
        hosting.frame = material.bounds; hosting.autoresizingMask = [.width, .height]
        material.addSubview(hosting); result.contentView = material; panel = result
        result.orderFrontRegardless() // No activation or keyboard-focus transfer on capture.
        let presentedAt = ProcessInfo.processInfo.systemUptime
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak result] event in
            // Ignore the triggering click if the event arrives after presentation.
            guard event.timestamp > presentedAt else { return }
            Task { @MainActor in
                guard let self, let result, self.panel === result,
                      !result.frame.contains(NSEvent.mouseLocation) else { return }
                self.dismiss()
            }
        }
        globalEscape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.dismiss() } }
        }
        localEscape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(); return nil }; return event
        }
    }
    private func resize(_ height: CGFloat) {
        guard let panel, let screen = panel.screen else { return }
        var frame = panel.frame
        let safe = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let newHeight = min(height, safe.height)
        frame.origin.y = max(safe.minY, frame.maxY - newHeight)
        frame.size.height = newHeight
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

}

private struct FloatingResult: View {
    @ObservedObject var capture: CaptureModel
    @ObservedObject var reply: ReplyModel
    @ObservedObject var runtime: LocalRuntime
    var resize: (CGFloat) -> Void
    var close: () -> Void
    var expand: () -> Void
    @State private var selection = 0
    @State private var originalVisible = false
    @State private var usedMemoryVisible = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 23, height: 23)
                Text(capture.appName.isEmpty ? "Chillor Reply" : L(capture.appName)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help(L("展开工作区")).accessibilityLabel(L("展开工作区"))
                Button(action: close) { Image(systemName: "xmark") }.help(L("关闭浮层")).accessibilityLabel(L("关闭浮层"))
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(18)
            Picker(L("结果"), selection: $selection) { Text(L("翻译")).tag(0); Text(L("回复")).tag(1) }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 18).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selection == 0 {
                        if !reply.chineseReading.isEmpty {
                            Text(reply.chineseReading).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(localizedStatus(capture.busy ? capture.status : (!runtime.ready ? runtime.status : reply.status)))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !capture.target.isEmpty {
                            DisclosureGroup(L("目标原文"), isExpanded: $originalVisible) {
                                Text(capture.target).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                            }
                        }
                        if !capture.busy && capture.target.isEmpty {
                            Text(localizedStatus(capture.status)).font(.caption).foregroundStyle(.secondary)
                            Button(L("设置…"), action: { expand(); NotificationCenter.default.post(name: .chillorSettings, object: nil) }).modifier(LiquidAction())
                        }
                    } else {
                        editor(L("中文草稿"), text: $reply.draft, height: 90)
                        Divider()
                        editor(L("英文回复"), text: $reply.english, height: 120)
                        if !reply.backChinese.isEmpty {
                            Text(L("英文实际表达的意思")).font(.caption).foregroundStyle(.secondary)
                            Text(reply.backChinese).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                        }
                        HStack {
                            TextField(L("告诉我怎么改…"), text: $reply.instruction).textFieldStyle(.plain).onSubmit { revise() }
                            Button { revise() } label: { Image(systemName: "arrow.up") }.modifier(LiquidAction()).disabled(!runtime.ready || !reply.canSend).accessibilityLabel(L("应用修改要求"))
                        }.padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }.frame(maxHeight: .infinity)
            VStack(spacing: 12) {
                if capture.busy || reply.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(localizedStatus(capture.busy ? capture.status : reply.status)).lineLimit(2)
                        Spacer()
                        Button { reply.cancel(); reply.status = "已停止，可继续编辑。" } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain).disabled(capture.busy).accessibilityLabel(L("停止生成"))
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !reply.status.isEmpty && selection == 1 {
                    Text(localizedStatus(reply.status)).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Toggle(L("不记住这次"), isOn: Binding(get: { reply.privateReply }, set: { reply.setPrivateReply($0) })).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    if !reply.usedMemories.isEmpty {
                        Button { usedMemoryVisible = true } label: { Image(systemName: "brain.head.profile") }.buttonStyle(.plain).accessibilityLabel(L("这次参考了什么"))
                    }
                    if selection == 0 {
                        Button(L("复制译文")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reply.chineseReading, forType: .string) }.modifier(LiquidAction()).disabled(reply.chineseReading.isEmpty || capture.busy)
                    } else {
                        Button(L("确认并复制英文")) { reply.checked = true; reply.copyEnglish() }.modifier(LiquidAction(primary: true)).disabled(!reply.canCheck)
                    }
                }
            }.padding(18)
        }.preferredColorScheme(.dark).tint(.pink)
            .background(Color.black.opacity(0.34))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.16), lineWidth: 0.7))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .sheet(isPresented: $usedMemoryVisible) { UsedMemoryView(reply: reply) }
            .onChange(of: selection) { _, value in resize(value == 0 ? 400 : 560) }
            .onAppear { if capture.target.isEmpty && !reply.draft.isEmpty { selection = 1 } }
    }
    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(size: 15)).scrollContentBackground(.hidden).frame(height: height).accessibilityLabel(title)
        }
    }
    private func revise() { guard runtime.ready && reply.canSend else { return }; reply.send(original: capture.target, context: capture.context) }
}

func runOverlayTests() {
    precondition(OverlayPlacement.point(CGPoint(x: -120, y: 100), primaryTop: 900) == CGPoint(x: -120, y: 800))
    let screens = [CGRect(x: 0, y: 25, width: 1440, height: 850), CGRect(x: -1920, y: -200, width: 1920, height: 1080), CGRect(x: 0, y: 900, width: 1280, height: 800)]
    for screen in screens {
        for x in [screen.minX, screen.midX, screen.maxX - 1] {
            for y in [screen.minY, screen.midY, screen.maxY - 1] {
                let frame = OverlayPlacement.frame(pointer: CGPoint(x: x, y: y), target: .zero, visible: screen, size: CGSize(width: 440, height: 560))
                precondition(screen.insetBy(dx: 12, dy: 12).contains(frame), "Overlay outside screen")
            }
        }
    }
    print("PASS: overlay placement at screen edges, negative and vertically stacked displays")
}
