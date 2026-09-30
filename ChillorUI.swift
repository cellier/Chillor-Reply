import SwiftUI
import Cocoa

enum Chillor {
    static let accent = Color(red: 0.65, green: 0.19, blue: 0.38)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let paper = Color(nsColor: .textBackgroundColor)
}

struct ChillorSettings: View {
    @ObservedObject var capture: CaptureModel
    @ObservedObject var runtime: LocalRuntime
    @ObservedObject var tap: TapTrigger
    @ObservedObject private var profiler = Profiler.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("设置")).font(.system(size: 21, weight: .medium))
                    Text(L("Chillor Reply · 设置")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("完成")) { dismiss() }.modifier(LiquidAction(primary: true)).keyboardShortcut(.defaultAction)
            }.padding(24)
            Form {
                Section(L("本地智能")) {
                    LabeledContent(L("模型"), value: "Qwen 3.8 · 27B")
                    LabeledContent(L("状态"), value: localizedStatus(runtime.status))
                    if runtime.downloading {
                        ProgressView(value: runtime.progress)
                        HStack {
                            Text(runtime.progressText).font(.caption.monospacedDigit())
                            Spacer(); Button(L("暂停下载")) { runtime.cancelDownload() }
                        }
                    } else if !runtime.ready {
                        Button(runtime.serviceUp ? L("下载 / 继续下载模型") : L("重新连接")) {
                            if runtime.serviceUp { runtime.startDownload() }
                            else { Task { await runtime.start(); runtime.autoDownloadIfNeeded() } }
                        }
                    }
                    Text(L("约 17.7 GB，仅首次下载需要联网。聊天内容在本机处理，没有云端回退。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("唤起方式")) {
                    LabeledContent(L("抓取鼠标指向的消息"), value: "⌃ ⌥ Space")
                    LabeledContent(L("读取原输入框草稿"), value: "⌃ ⌥ R")
                    Button(L("3 秒后读取输入框")) {
                        dismiss()
                        NotificationCenter.default.post(name: Notification.Name("ChillorReply.readInput"), object: nil)
                    }
                    Toggle(L("拍机身触发"), isOn: $tap.enabled).disabled(!tap.available)
                    if tap.enabled {
                        Picker(L("手势"), selection: $tap.taps) { Text(L("拍两下")).tag(2); Text(L("拍三下")).tag(3) }
                        Picker(L("灵敏度"), selection: $tap.sensitivity) {
                            Text(L("保守")).tag(0); Text(L("标准")).tag(1); Text(L("灵敏")).tag(2); Text(L("极灵敏")).tag(3)
                        }
                        Toggle(L("只测试，不抓取消息"), isOn: $tap.testOnly)
                        HStack {
                            Text(localizedStatus(tap.gestureNote.isEmpty ? tap.status : tap.gestureNote)).font(.caption)
                            Spacer()
                            Text(L("%@ 次", String(tap.testCount))).monospacedDigit()
                            Button(L("清零")) { tap.resetTestCount() }
                        }
                        Text(L("打字后停 0.3 秒，再连拍机身。只读取按键活动时间，不读取输入内容。"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !tap.available {
                        Text(localizedStatus(tap.status)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L("跨应用权限")) {
                    HStack {
                        Label(L("辅助功能"), systemImage: "hand.point.up.left")
                        Spacer(); Button(capture.axGranted ? L("已开启") : L("前往开启")) { capture.requestAX() }
                    }
                    HStack {
                        Label(L("屏幕录制"), systemImage: "viewfinder")
                        Spacer(); Button(capture.screenGranted ? L("已开启") : L("前往开启")) { capture.requestScreen() }
                    }
                    Toggle(L("使用截图补充文字识别"), isOn: $capture.captureImage)
                    Button(L("刷新权限状态")) { capture.refreshPermissions() }
                    Text(L("辅助功能用于读取与填回；屏幕录制用于本地识字。首次授予屏幕录制权限后，请退出并重新打开应用。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("关于 Chillor Reply")) {
                    LabeledContent(L("版本"), value: "0.10.6")

                    Text(L("开启记忆后，所选文字和回复加密保存在本机。可随时暂停、纠正或删除。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if !profiler.stages.isEmpty {
                        DisclosureGroup(L("本次处理耗时")) {
                            ForEach(profiler.stages) { Text(localizedStats($0)).font(.caption.monospacedDigit()).textSelection(.enabled) }
                        }
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 620, height: 720).background(Chillor.canvas).tint(Chillor.accent)
            .onAppear { capture.refreshPermissions() }
    }
}

struct ChillorInspector: View {
    @ObservedObject var capture: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("消息来源")).font(.system(size: 21, weight: .medium))
                    Text(L("确认目标消息，保留真正相关的上下文。")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("完成")) { dismiss() }.modifier(LiquidAction(primary: true)).keyboardShortcut(.defaultAction)
            }.padding(24)
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Eyebrow(number: "01", title: L("目标原文"))
                        TextEditor(text: $capture.target).font(.system(size: 14)).frame(height: 150)
                            .scrollContentBackground(.hidden).padding(10).background(Chillor.paper, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel(L("目标原文"))
                        HStack { Text(L("发件人")).font(.caption); TextField(L("未识别，可留空"), text: $capture.sender).textFieldStyle(.roundedBorder) }
                        HStack {
                            Eyebrow(number: "02", title: L("附近上下文 · %@ 条", String(capture.selectedCount)))
                            Spacer(); Button(L("取消选择")) { capture.clearContextSelection() }.font(.caption)
                        }
                        Text(L("相邻不代表同一话题。取消无关内容，或将漏掉的段落并入目标。"))
                            .font(.caption).foregroundStyle(.secondary)
                        if capture.messages.isEmpty { Text(L("抓取消息后，可在这里调整上下文。")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(capture.messages.prefix(60)) { message in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(previewText(message.text)).font(.system(size: 12)).lineLimit(8).textSelection(.enabled)
                                HStack {
                                    if capture.targetIDs.contains(message.id) {
                                        Label(L("目标消息"), systemImage: "checkmark.circle.fill").foregroundStyle(Chillor.accent)
                                    } else {
                                        Toggle(L("用于理解"), isOn: Binding(get: { message.included }, set: { capture.setIncluded(message.id, $0) })).toggleStyle(.checkbox)
                                        Spacer()
                                        Menu(L("更多")) {
                                            Button(L("设为目标消息")) { capture.selectTarget(message) }
                                            Button(L("并入目标原文")) { capture.appendToTarget(message) }
                                        }.fixedSize()
                                    }
                                }.font(.caption)
                            }.padding(14).background(Chillor.paper, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(20)
                }.frame(minWidth: 350)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("截图对照")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Picker(L("缩放"), selection: $zoom) {
                            Text(L("适应")).tag(CGFloat(1)); Text("2×").tag(CGFloat(2)); Text("3×").tag(CGFloat(3))
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                    }
                    if let image = capture.screenshot {
                        ScrollView([.horizontal, .vertical]) {
                            let width: CGFloat = 390 * zoom
                            let ratio = width / max(1, capture.previewFrame.width)
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: image).resizable().frame(width: width, height: capture.previewFrame.height * ratio)
                                let focus = capture.focusFrame.intersection(capture.previewFrame)
                                if !focus.isNull && !focus.isEmpty {
                                    Rectangle().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                        .frame(width: focus.width * ratio, height: focus.height * ratio)
                                        .offset(x: (focus.minX - capture.previewFrame.minX) * ratio, y: (focus.minY - capture.previewFrame.minY) * ratio)
                                }
                                ForEach(capture.messages.prefix(60)) { message in
                                    if capture.targetIDs.contains(message.id) || message.included {
                                        let r = message.rect.intersection(capture.previewFrame)
                                        if !r.isNull {
                                            RoundedRectangle(cornerRadius: 3).stroke(capture.targetIDs.contains(message.id) ? Color.blue : Color.orange, lineWidth: 2)
                                                .frame(width: r.width * ratio, height: r.height * ratio)
                                                .offset(x: (r.minX - capture.previewFrame.minX) * ratio, y: (r.minY - capture.previewFrame.minY) * ratio)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(L("暂无截图"), systemImage: "viewfinder", description: Text(L("抓取后可对照原窗口。")))
                    }
                    Text(L("蓝框为目标，橙框为上下文，虚线为筛选范围。截图不会上传或存档。"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(minWidth: 390)
            }
        }.frame(width: 930, height: 700).background(Chillor.canvas).tint(Chillor.accent)
    }
}

extension Notification.Name {
    static let chillorSettings = Notification.Name("ChillorReply.settings")
    static let chillorNew = Notification.Name("ChillorReply.new")
}

struct LiquidAction: ViewModifier {
    var primary = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if primary { content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(Chillor.accent) }
            else { content.buttonStyle(.glass).buttonBorderShape(.capsule).tint(nil as Color?) }
        } else {
            if primary { content.buttonStyle(.borderedProminent).tint(Chillor.accent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

private struct LiquidSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

private struct Eyebrow: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Chillor.accent)
            Text(title).font(.system(size: 12, weight: .semibold))
        }
    }
}

struct ChillorWorkspace: View {
    @ObservedObject var capture: CaptureModel
    @ObservedObject var reply: ReplyModel
    @ObservedObject var runtime: LocalRuntime
    @ObservedObject var tap: TapTrigger
    @ObservedObject var memory: MemoryStore
    @State private var memoryVisible = false
    @State private var usedMemoryVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var writing = false
    @State private var settings = false
    @State private var inspector = false
    @State private var originalVisible = false
    @State private var historyVisible = false
    @State private var newConfirmation = false
    @State private var copied = false
    @State private var copyTask: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field: Hashable { case draft, english, instruction }
    private var hasWork: Bool { writing || !capture.target.isEmpty || !reply.draft.isEmpty || capture.busy }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.28) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            if hasWork { workspace.transition(.opacity) }
            else { welcome.transition(.opacity) }
            footer
        }
        .background(Chillor.canvas)
        .tint(Chillor.accent)
        .animation(motion, value: hasWork)
        .animation(motion, value: reply.busy)
        .frame(minWidth: 880, minHeight: 680)
        .sheet(isPresented: $settings) { ChillorSettings(capture: capture, runtime: runtime, tap: tap) }
        .sheet(isPresented: $memoryVisible) { MemoryView(memory: memory) }
        .sheet(isPresented: $usedMemoryVisible) { UsedMemoryView(reply: reply) }
        .sheet(isPresented: $inspector) { ChillorInspector(capture: capture) }
        .alert(L("开始新的回复？"), isPresented: $newConfirmation) {
            Button(L("保留当前回复"), role: .cancel) {}
            Button(L("开始新回复"), role: .destructive) { reset() }
        } message: { Text(L("本次原文、草稿和修改记录会被清除。")) }
        .onReceive(NotificationCenter.default.publisher(for: .chillorSettings)) { _ in settings = true }
        .onReceive(NotificationCenter.default.publisher(for: .chillorNew)) { _ in newReply() }
        .onChange(of: capture.target) { _, _ in syncSource() }
        .onChange(of: capture.context) { _, _ in syncSource() }
        .onChange(of: capture.sender) { _, _ in syncSource() }
        .onChange(of: capture.busy) { _, busy in
            if busy { copied = false; copyTask?.cancel() }
            else { syncSource() }
        }
        .onChange(of: reply.english) { _, _ in copied = false; copyTask?.cancel() }
        .onChange(of: runtime.ready) { _, ready in reply.setModelReady(ready) }
        .onAppear { reply.setModelReady(runtime.ready) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chillor Reply").font(.system(size: 15, weight: .semibold))

            }
            Spacer()
            Button { memoryVisible = true } label: { Image(systemName: "brain.head.profile").frame(width: 20, height: 20) }
                .modifier(LiquidAction()).help(L("记忆")).accessibilityLabel(L("记忆"))
            if hasWork {
                Button { inspector = true } label: {
                    Label(L("消息来源"), systemImage: "sidebar.left")
                }.modifier(LiquidAction()).disabled(capture.busy)
                    .help(L("查看原文、截图与附近上下文"))
            }
            Button { newReply() } label: { Image(systemName: "square.and.pencil").frame(width: 20, height: 20) }
                .modifier(LiquidAction()).help(L("新回复 ⌘N")).accessibilityLabel(L("新回复")).disabled(capture.busy)
            Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 20, height: 20) }
                .modifier(LiquidAction()).help(L("设置 ⌘,")).accessibilityLabel(L("设置"))
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                .padding(.bottom, 24).accessibilityHidden(true)
            Text(L("翻译与回复")).font(.system(size: 30, weight: .medium)).tracking(-0.7)
            Text(L("指向内容，按快捷键查看翻译和回复。"))
                .font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 12)
            HStack(spacing: 12) {
                Button { capture.delayCapture() } label: { Label(L("抓取一条消息"), systemImage: "viewfinder").padding(.horizontal, 12).padding(.vertical, 5) }
                    .modifier(LiquidAction(primary: true)).controlSize(.large)
                Button { beginWriting() } label: { Label(L("直接写回复"), systemImage: "square.and.pencil").padding(.horizontal, 8).padding(.vertical, 5) }
                    .modifier(LiquidAction()).controlSize(.large)
            }.padding(.top, 30)
            HStack(spacing: 7) {
                Text(L("指向消息，按")).foregroundStyle(.secondary)
                Text("⌃ ⌥ Space").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                if tap.enabled { Text(tap.taps == 3 ? L("或轻拍三下机身") : L("或轻拍两下机身")).foregroundStyle(.secondary) }
            }.font(.system(size: 11)).padding(.top, 18)
            Spacer(minLength: 35)
            if memory.ready && !memory.state.decided {
                VStack(spacing: 10) {
                    Text(L("本机记忆")).font(.system(size: 13, weight: .medium))
                    Text(L("在本机记住主动截取的文字和采用的回复，逐渐熟悉你的表达。随时可暂停或删除。")).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button(L("开启本机记忆")) { memory.setEnabled(true) }.modifier(LiquidAction(primary: true))
                        Button(L("暂不开启")) { memory.setEnabled(false) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: 520).padding(.bottom, 20)
            }
            if capture.status != "把鼠标移到一条消息上，按 ⌃⌥Space。" && capture.status != "本次内容已清除。" {
                Text(localizedStatus(capture.status)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).multilineTextAlignment(.center).padding(.horizontal, 50).padding(.bottom, 20)
            }
            if !runtime.ready || !capture.axGranted || !capture.screenGranted {
                Button { settings = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                        Text(runtime.ready ? L("完成权限设置，开始跨应用抓取") : localizedStatus(runtime.status))
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                    }.font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(Chillor.accent).padding(.bottom, 14)
            }
            Button(L("试一条示例")) { Task { await capture.loadDemo() } }.buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeStep(_ number: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(number: number, title: title)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var workspace: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Text(capture.target.isEmpty ? L("撰写回复") : L("翻译与回复"))
                    .font(.system(size: 21, weight: .medium)).tracking(-0.4)
                Spacer()
                if reply.busy || capture.busy {
                    ProgressView().controlSize(.small)
                    Text(capture.busy ? L("正在读取消息") : phase).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button { reply.cancel(); reply.status = "已停止，可继续编辑。" } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.plain).help(L("停止生成")).disabled(capture.busy)
                } else if reply.canCheck {
                    Label(L("可以核对了"), systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Chillor.accent)
                }
            }
            HStack(spacing: 12) {
                Toggle(L("不记住这次"), isOn: Binding(get: { reply.privateReply }, set: { reply.setPrivateReply($0) }))
                    .toggleStyle(.checkbox).help(L("本次不读取、不保存记忆。"))
                if !reply.usedMemories.isEmpty {
                    Button(L("参考了 %@ 条记忆", String(reply.usedMemories.count))) { usedMemoryVisible = true }.buttonStyle(.plain).foregroundStyle(Chillor.accent)
                }
                Spacer()
            }.font(.system(size: 11))
            HStack(alignment: .top, spacing: 16) {
                intentPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                englishPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            actionBar
        }.padding(24)
    }

    private var intentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !capture.target.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow(number: "01", title: capture.sender.isEmpty ? L("读懂来信") : L("来自 ") + capture.sender)
                            Spacer()
                            Button { reply.translate(original: capture.target, context: capture.context, sender: capture.sender) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).help(L("重新翻译来信")).accessibilityLabel(L("重新翻译来信"))
                                .disabled(reply.busy || capture.busy || !runtime.ready)
                            Button(originalVisible ? L("看译文") : L("看原文")) { withAnimation(motion) { originalVisible.toggle() } }
                                .buttonStyle(.plain).foregroundStyle(Chillor.accent).font(.system(size: 11))
                        }
                        Text(originalVisible ? capture.target : (reply.chineseReading.isEmpty ? L("来信译文会显示在这里…") : reply.chineseReading))
                            .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                            .foregroundStyle(!originalVisible && reply.chineseReading.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Text(reply.incomingIsChinese ? L("中文 → 英文") : L("英文 → 中文"))
                            Spacer()
                            Button(L("%@ 条附近上下文", String(capture.selectedCount))) { inspector = true }.buttonStyle(.plain)
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Eyebrow(number: "02", title: L("你想怎么说"))
                        Spacer()
                        Text(L("中文草稿")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    ZStack(alignment: .topLeading) {
                        if reply.draft.isEmpty {
                            Text(L("输入中文草稿…"))
                                .font(.system(size: 15)).lineSpacing(7).foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                        TextEditor(text: $reply.draft).font(.system(size: 15)).lineSpacing(6)
                            .scrollContentBackground(.hidden).frame(minHeight: 150)
                            .focused($focus, equals: .draft).accessibilityLabel(L("中文草稿"))
                    }
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                        Text(L("停笔后，英文与回译自动更新")).font(.system(size: 10))
                        Spacer()
                        Button { reply.generate(original: capture.target, context: capture.context, sender: capture.sender) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).help(L("立即更新英文")).accessibilityLabel(L("立即更新英文"))
                            .disabled(reply.busy || !runtime.ready || reply.draft.isEmpty)
                    }.foregroundStyle(.secondary)
                }
            }.padding(22)
        }.background(Chillor.paper, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(focus == .draft ? 0.15 : 0.05)))
    }

    private var englishPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Eyebrow(number: "03", title: L("英文回复"))
                    Spacer()
                    Text(L("可直接编辑")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                ZStack(alignment: .topLeading) {
                    if reply.english.isEmpty {
                        Text(L("英文回复将显示在这里。")).font(.system(size: 21, weight: .regular, design: .serif))
                            .lineSpacing(8).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 8).allowsHitTesting(false)
                    }
                    TextEditor(text: $reply.english).font(.system(size: 17)).lineSpacing(6)
                        .scrollContentBackground(.hidden).frame(minHeight: 155)
                        .focused($focus, equals: .english).accessibilityLabel(L("英文回复"))
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L("英文实际表达的意思"), systemImage: "checkmark.shield").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button { reply.recheck() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                            .buttonStyle(.plain).help(L("重新独立回译")).accessibilityLabel(L("重新独立回译"))
                            .disabled(reply.busy || !runtime.ready || reply.english.isEmpty)
                    }.foregroundStyle(Chillor.accent)
                    Text(reply.backChinese.isEmpty ? L("英文生成后，会独立回译成中文供你核对。") : reply.backChinese)
                        .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                        .foregroundStyle(reply.backChinese.isEmpty ? .secondary : .primary)
                    Text(L("只看英文，不参考你的中文草稿。")).font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Chillor.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                if historyVisible && !reply.turns.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(reply.turns.suffix(6)) { turn in
                            Label(previewText(turn.instruction, limit: 180), systemImage: "arrow.turn.down.right")
                                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.transition(.opacity)
                }
                revisionComposer
            }.padding(22)
        }.background(Chillor.paper, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(focus == .english ? 0.15 : 0.05)))
    }

    private var revisionComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("再调整一点")).font(.system(size: 11, weight: .medium))
                Spacer()
                if !reply.turns.isEmpty {
                    Button(L("%@ 次修改", String(reply.turns.count))) { withAnimation(motion) { historyVisible.toggle() } }.buttonStyle(.plain)
                    Button { reply.undoTurn() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).help(L("撤销上一步"))
                        .disabled(reply.busy || !runtime.ready)
                    Menu { Button(L("清空修改记录")) { reply.clearConversation() } } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 20).disabled(reply.busy)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                suggestion(L("简短一点"), "写得更简短，保留原有意思。")
                suggestion(L("柔和一点"), "语气再柔和自然一点，不增加任何承诺。")
                suggestion(L("不承诺时间"), "去掉时间承诺，不要增加新的承诺。")
            }
            HStack(spacing: 8) {
                TextField(L("告诉我怎么改…"), text: $reply.instruction).textFieldStyle(.plain)
                    .font(.system(size: 13)).focused($focus, equals: .instruction)
                    .onSubmit { revise() }.accessibilityLabel(L("修改要求"))
                Button { revise() } label: { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 21, height: 23) }
                    .modifier(LiquidAction(primary: true)).disabled(!runtime.ready || !reply.canSend)
                    .help(L("改写英文，不发送消息")).accessibilityLabel(L("应用修改要求"))
            }.padding(10).background(Chillor.canvas, in: RoundedRectangle(cornerRadius: 13))
        }
    }

    private func suggestion(_ label: String, _ instruction: String) -> some View {
        Button(label) { reply.instruction = instruction; revise() }
            .font(.system(size: 10)).modifier(LiquidAction())
            .disabled(reply.busy || !runtime.ready || reply.english.isEmpty)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: copied ? "checkmark.circle.fill" : "hand.raised")
                .foregroundStyle(Chillor.accent).contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                Text(copied ? L("英文已复制") : L("核对回复")).font(.system(size: 12, weight: .medium))
                Text(copied ? L("回到原应用粘贴，检查后发送。") : L("核对中文与回译，再确认使用。不会自动发送。"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if reply.canFill {
                Button(L("复制英文")) { confirmCopy() }.modifier(LiquidAction()).disabled(!reply.canCheck)
                Button { reply.checked = true; reply.fill() } label: {
                    Label(L("确认并填回"), systemImage: "arrow.up.forward.app").padding(.vertical, 3)
                }.modifier(LiquidAction(primary: true)).disabled(!reply.canCheck)
            } else {
                Button { confirmCopy() } label: {
                    Label(copied ? L("已复制") : L("确认并复制英文"), systemImage: copied ? "checkmark" : "doc.on.doc").padding(.vertical, 3)
                }.modifier(LiquidAction(primary: true)).disabled(!reply.canCheck)
            }
        }.padding(16).modifier(LiquidSurface())
            .animation(motion, value: copied)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(runtime.ready ? Chillor.accent : Color.orange).frame(width: 5, height: 5)
            Button(runtime.ready ? L("本地模型已就绪") : localizedStatus(runtime.status)) { settings = true }.buttonStyle(.plain).lineLimit(1)
            if hasWork && !reply.status.isEmpty {
                Text("·"); Text(localizedStatus(reply.status)).lineLimit(1).truncationMode(.tail).help(localizedStatus(reply.status))
            }
            if !memory.error.isEmpty {
                Button(L("记忆未保存")) { memoryVisible = true }.foregroundStyle(.orange).help(L(memory.error))
            }
            Spacer(minLength: 10)
            Image(systemName: "lock").font(.system(size: 9))
            Text(L("仅在本机")).fixedSize()
            Text("CHILLOR").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.6).padding(.leading, 10)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.bottom, 12)
    }

    private var phase: String {
        if reply.status.contains("回译") { return L("正在核对英文含义") }
        if reply.status.contains("中文") { return L("正在整理你的意思") }
        return L("正在写英文")
    }
    private func syncSource() { if !capture.busy { reply.updateSource(original: capture.target, context: capture.context, sender: capture.sender, app: capture.appName, memoryEligible: !capture.isDemo) } }
    private func beginWriting() { writing = true; focus = .draft }
    private func newReply() { guard !capture.busy else { return }; if hasWork { newConfirmation = true } else { beginWriting() } }
    private func reset() { reply.clear(); capture.clear(); writing = false; copied = false; historyVisible = false; focus = nil }
    private func revise() { if runtime.ready && reply.canSend { reply.send(original: capture.target, context: capture.context) } }
    private func confirmCopy() {
        guard reply.canCheck else { return }
        reply.checked = true; reply.copyEnglish(); copied = true
        copyTask?.cancel()
        copyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { copied = false }
        }
    }
}
