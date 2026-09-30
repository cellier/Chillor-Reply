import Foundation

// Bundle language negotiation honors both system and per-app language preferences.
// UI localization never changes prompts, captured text, drafts, or detector state.
private enum UILanguage {
    static let code = Bundle.main.preferredLocalizations.first ?? "en"
    static let bundle = Bundle(path: Bundle.main.path(forResource: code, ofType: "lproj") ?? "") ?? Bundle.main
    static func catalog(_ language: String) -> [String: String] {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")),
              let result = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return result
    }
    static let source = catalog("zh")
    // Existing models expose status strings as internal state. Translate only their
    // presentation, using anchored, known templates; unknown system errors pass through.
    static let statusTemplates: [(String, NSRegularExpression)] = source.keys
        .filter { $0.contains("%@") }
        .sorted { $0.count > $1.count }
        .compactMap { key in
            let pattern = "^" + key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "([\\s\\S]*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (key, regex)
        }
}

func L(_ key: String, _ arguments: String...) -> String {
    let format = UILanguage.bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, arguments: arguments.map { $0 as CVarArg })
}

func localizedStatus(_ raw: String) -> String {
    if UILanguage.source[raw] != nil { return L(raw) }
    let full = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    for (key, regex) in UILanguage.statusTemplates {
        guard let match = regex.firstMatch(in: raw, range: full) else { continue }
        let arguments = (1..<match.numberOfRanges).compactMap { i -> String? in
            guard let range = Range(match.range(at: i), in: raw) else { return nil }
            return String(raw[range])
        }
        let format = UILanguage.bundle.localizedString(forKey: key, value: key, table: nil)
        return String(format: format, arguments: arguments.map { $0 as CVarArg })
    }
    return raw
}

func localizedStats(_ stats: ChatStats) -> String {
    let speed = stats.outputMS > 0 ? Double(stats.outputTokens) / (stats.outputMS / 1000) : 0
    let load = stats.loadMS > 50 ? L("载入 %@ 秒", String(format: "%.1f", stats.loadMS / 1000)) : ""
    return L("%@ · %@ 秒 · %@ · 输入 %@ tok · 输出 %@ tok · %@ tok/s",
             L(stats.label), String(format: "%.1f", stats.wallMS / 1000), load,
             String(stats.promptTokens), String(stats.outputTokens), String(format: "%.0f", speed))
}

func runLocalizationTests() {
    func check(_ value: Bool, _ reason: String) {
        guard value else { fputs("FAIL localization: \(reason)\n", stderr); exit(1) }
    }
    let en = UILanguage.catalog("en"), zh = UILanguage.catalog("zh")
    check(en.count > 200 && en.keys.sorted() == zh.keys.sorted(), "catalog coverage")
    for key in en.keys {
        check(key.components(separatedBy: "%@").count == en[key]!.components(separatedBy: "%@").count, "English arguments: \(key)")
        check(key.components(separatedBy: "%@").count == zh[key]!.components(separatedBy: "%@").count, "Chinese arguments: \(key)")
    }
    let requested = Locale.preferredLanguages.first ?? "en"
    let chinese = requested.hasPrefix("zh")
    let traditional = requested.hasPrefix("zh-Hant") || requested.hasPrefix("zh-TW")
    let expectedCode = traditional ? "zh-Hant" : (chinese ? "zh" : "en")
    check(UILanguage.code == expectedCode, "language negotiation: \(requested) → \(UILanguage.code)")
    check(L("设置") == (traditional ? "設定" : (chinese ? "设置" : "Settings")), "settings label")
    check(L("%@ 次修改", "3") == (chinese ? "3 次修改" : "3 revisions"), "count interpolation")
    check(localizedStatus("收到第 2 下") == (chinese ? "收到第 2 下" : "Tap 2 detected"), "dynamic tap state")
    check(localizedStatus("正在生成英文回复…") == (traditional ? "正在生成英文回覆…" : (chinese ? "正在生成英文回复…" : "Writing your English reply…")), "generation state")
    check(localizedStatus("下载中断：HTTP 503 (50%)。再点一次会从断点继续。") == (traditional ? "下載中斷：HTTP 503 (50%)。再點一次會從斷點繼續。" : (chinese ? "下载中断：HTTP 503 (50%)。再点一次会从断点继续。" : "Download interrupted: HTTP 503 (50%). Resume to continue where you left off.")), "dynamic error payload")
    check(localizedStatus("unrecognized OS error 42") == "unrecognized OS error 42", "unknown errors preserved")
    print("PASS: \(requested) → \(UILanguage.code), \(en.count) keys, interpolation, statuses and error payloads")
}
