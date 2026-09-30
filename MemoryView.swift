import SwiftUI

struct MemoryView: View {
    @ObservedObject var memory: MemoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var query = ""
    @State private var selected: UUID?
    @State private var editing = false
    @State private var editID: UUID?
    @State private var kind = "preference"
    @State private var term = ""
    @State private var value = ""
    @State private var deletingAll = false
    @State private var deletingRecord: UUID?
    private var records: [ReplyMemory] {
        memory.state.replies.filter { query.isEmpty || $0.searchText.localizedCaseInsensitiveContains(query) }.sorted { $0.updated > $1.updated }
    }
    private var personal: [PersonalMemory] {
        memory.state.personal.filter { $0.kind == (tab == 1 ? "preference" : "term") && (query.isEmpty || ($0.source + $0.value).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("记忆")).font(.system(size: 21, weight: .medium))
                    Text(L("管理本机保存的记录、偏好与术语。")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("完成")) { dismiss() }.modifier(LiquidAction(primary: true)).keyboardShortcut(.defaultAction)
            }.padding(22)
            HStack(spacing: 14) {
                Picker(L("记忆"), selection: $tab) {
                    Text(L("沟通记录")).tag(0); Text(L("表达偏好")).tag(1); Text(L("术语")).tag(2)
                }.pickerStyle(.segmented).frame(width: 330)
                TextField(L("搜索记忆…"), text: $query).textFieldStyle(.roundedBorder).accessibilityLabel(L("搜索记忆"))
                if tab > 0 {
                    Button { editID = nil; kind = tab == 1 ? "preference" : "term"; term = ""; value = ""; editing = true } label: { Image(systemName: "plus") }
                        .modifier(LiquidAction()).help(L("添加记忆"))
                }
            }.padding(.horizontal, 22).padding(.bottom, 16)
            Divider()
            if !memory.error.isEmpty {
                HStack { Text(L(memory.error)).font(.caption); Spacer(); Button(memory.needsUnlock ? L("迁移已有记忆") : L("重试")) { if memory.needsUnlock { memory.unlock() } else { memory.retrySave() } }.disabled(memory.loading) }.padding().foregroundStyle(.orange)
            }
            if !memory.ready && memory.error.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !memory.ready {
                ContentUnavailableView(L("迁移已有记忆"), systemImage: "arrow.triangle.2.circlepath", description: Text(L(memory.error)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == 0 {
                history
            } else {
                rules
            }
            Divider()
            HStack {
                Toggle(L("本机记忆"), isOn: Binding(get: { memory.state.enabled }, set: { memory.setEnabled($0) })).toggleStyle(.switch).controlSize(.small).disabled(!memory.ready)
                if memory.saving { ProgressView().controlSize(.mini) }
                Text(memory.state.enabled ? L("加密保存在本机") : L("已暂停读取和保存")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu(L("保留记录")) {
                    ForEach([30,90,0], id: \.self) { days in
                        Button {
                            memory.setRetention(days)
                        } label: { Label(days == 0 ? L("永久") : L("%@ 天", String(days)), systemImage: memory.state.retentionDays == days ? "checkmark" : "") }
                    }
                }.fixedSize()
                Button(L("清空全部"), role: .destructive) { deletingAll = true }.disabled(!memory.ready)
            }.padding(18)
        }.frame(width: 800, height: 680).background(Chillor.canvas).tint(Chillor.accent)
        .sheet(isPresented: $editing) { editor }
        .alert(L("删除全部记忆？"), isPresented: $deletingAll) {
            Button(L("取消"), role: .cancel) {}
            Button(L("删除"), role: .destructive) { memory.clearAll(); selected = nil }
        } message: { Text(L("沟通记录、术语和偏好都会删除。当前回复不会重新写回记忆；新回复可以重新积累。")) }
        .alert(L("删除这条记录？"), isPresented: Binding(get: { deletingRecord != nil }, set: { if !$0 { deletingRecord = nil } })) {
            Button(L("取消"), role: .cancel) { deletingRecord = nil }
            Button(L("删除"), role: .destructive) { if let id = deletingRecord { memory.forgetSession(id); selected = nil }; deletingRecord = nil }
        } message: { Text(L("这条记录支持的自动偏好也会重新评估。")) }
    }
    private var history: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(records.prefix(100)) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(previewText(record.source.isEmpty ? record.draft : record.source, limit: 90)).font(.system(size: 12)).lineLimit(2)
                            HStack {
                                Text(record.updated, style: .date)
                                Spacer()
                                Text(record.adopted.isEmpty ? L("未采用") : L("已采用"))
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(record.id)
                    }
                }.listStyle(.sidebar)
                if records.count > 100 { Text(L("显示最近 100 条，搜索可缩小范围。")).font(.caption).padding(8) }
            }.frame(minWidth: 230, idealWidth: 250, maxWidth: 300)
            ScrollView {
                if let record = memory.state.replies.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text(record.updated, style: .date).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { deletingRecord = record.id } label: { Image(systemName: "trash") }.help(L("删除"))
                        }
                        Text([record.app, record.sender].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        field("目标原文", record.source)
                        field("选中的上下文", record.context)
                        field("中文草稿", record.draft)
                        field("英文回复", record.english)
                        field("英文实际表达的意思", record.back)
                        if !record.adopted.isEmpty {
                            Text(L("采用版本不代表已经发送。")).font(.caption).foregroundStyle(.secondary)
                            ForEach(record.adopted.reversed()) { version in
                                DisclosureGroup {
                                    field("中文草稿", version.draft)
                                    field("英文回复", version.english)
                                    field("修改要求", version.instructions.joined(separator: "\n"))
                                } label: {
                                    HStack {
                                        Text(version.action == "filled" ? L("已填回") : L("已复制"))
                                        Spacer(); Text(version.at, style: .time)
                                    }.font(.caption)
                                }
                            }
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ContentUnavailableView(L("暂无沟通记录"), systemImage: "clock.arrow.circlepath", description: Text(L("开启后记录主动截取的文字和回复。只保留所选上下文，不保存截图。")))
                        .padding(.top, 65)
                }
            }.frame(minWidth: 400)
        }
    }
    private var rules: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tab == 1 ? L("反复采用的简洁、柔和修改会逐渐形成偏好；一次修改不会变成永久规则。也可以直接写下你的偏好。") : L("记住产品名或常用词的译法，只在当前文字出现该术语时参考。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
                ForEach(personal) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle(isOn: Binding(get: { item.enabled }, set: { memory.setPersonalEnabled(item.id, $0) })) {
                                Text(item.kind == "term" ? item.source : (item.learned != nil ? L(item.source) : L("你的偏好"))).font(.system(size: 13, weight: .medium))
                            }.toggleStyle(.switch).controlSize(.small)
                            Spacer()
                            Button(L("编辑")) { editID = item.id; kind = item.kind; term = item.source; value = item.value; editing = true }.buttonStyle(.plain)
                            Button(role: .destructive) { memory.deletePersonal(item.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help(L("删除"))
                        }
                        Text(item.learned != nil ? L(item.value) : item.value).font(.system(size: 13)).textSelection(.enabled)
                        if item.learned != nil {
                            DisclosureGroup(L("来自 %@ 条采用记录", String(item.evidence.count))) {
                                ForEach(item.evidence, id: \.self) { id in
                                    if let record = memory.state.replies.first(where: { $0.id == id }) {
                                        Button { tab = 0; query = ""; selected = id } label: {
                                            HStack { Text(record.updated, style: .date); Text(previewText(record.source.isEmpty ? record.draft : record.source, limit: 70)).lineLimit(1) }
                                        }.buttonStyle(.plain).font(.caption)
                                    }
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        } else { Text(L("由你指定")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(18).background(Chillor.paper, in: RoundedRectangle(cornerRadius: 16))
                }
                if personal.isEmpty { ContentUnavailableView(L("暂无偏好"), systemImage: "sparkles", description: Text(L("可添加偏好；采用回复后，系统会逐步学习表达习惯。"))) }
            }.padding(22)
        }
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !value.isEmpty {
                Text(L(title)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
            }
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == "term" ? L("术语") : L("表达偏好")).font(.title3.weight(.medium))
            if kind == "term" { TextField(L("原词，例如产品名称"), text: $term).textFieldStyle(.roundedBorder) }
            Text(kind == "term" ? L("希望使用的译法") : L("例如：回复先说结论，避免不必要的客套。")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $value).font(.system(size: 14)).frame(height: 120).accessibilityLabel(L("记忆内容"))
            HStack {
                Text(L("当前明确要求始终优先。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("取消")) { editing = false }
                Button(L("保存")) { memory.savePersonal(id: editID, kind: kind, source: term, value: value); editing = false }
                    .modifier(LiquidAction(primary: true)).disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind == "term" && term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(24).frame(width: 500)
    }
}

struct UsedMemoryView: View {
    @ObservedObject var reply: ReplyModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("这次参考了什么")).font(.title3.weight(.medium)); Spacer()
                Button(L("完成")) { dismiss() }.modifier(LiquidAction(primary: true))
            }
            Text(L("这些内容提供给了生成步骤，独立回译不会读取记忆。")).font(.caption).foregroundStyle(.secondary)
            ForEach(reply.usedMemories) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(item.kind == "term" ? item.title : L("表达偏好")).font(.headline)
                        Spacer(); Button(L("这次不用")) { reply.excludeMemory(item.id); dismiss() }.buttonStyle(.plain)
                    }
                    Text(item.value).font(.system(size: 13)).textSelection(.enabled)
                }.padding(16).background(Chillor.paper, in: RoundedRectangle(cornerRadius: 14))
            }
        }.padding(24).frame(width: 520).background(Chillor.canvas)
    }
}
