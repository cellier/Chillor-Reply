import Foundation
import LocalAuthentication
import CryptoKit
import Security

@MainActor
func runMemoryTests() async throws {
    func check(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        if !condition() { throw LocalAIError(message: "Memory: " + reason) }
    }
    func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LocalAIError(message: "Memory: async timeout")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChillorMemoryTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let key = Data(repeating: 47, count: 32), url = folder.appendingPathComponent("memory.sqlite")
    let disk = MemoryDisk(url: url, testKey: key), store = MemoryStore(disk: disk)
    try await wait { store.ready }
    try check(!FileManager.default.fileExists(atPath: url.path), "no vault created before opt-in")
    let now = Date()
    func fixture(_ date: Date = Date(), _ instructions: [String] = []) -> ReplyMemory {
        ReplyMemory(id: UUID(), created: date, updated: date, app: "FictionalApp", sender: "Example Person", source: "PRIVATE_FIXTURE_SOURCE_" + UUID().uuidString, context: "selected context only", draft: "虚构中文草稿", english: "Fictional English reply", back: "虚构回译", instructions: instructions)
    }
    let first = fixture()
    store.record(first, eligible: true)
    try check(store.state.replies.isEmpty, "opt-out blocks capture")
    store.setEnabled(true); try await wait { !store.saving }
    store.record(first, eligible: false)
    try check(store.state.replies.isEmpty, "demo and private capture excluded")
    store.record(first, eligible: true)
    try check(store.state.replies.count == 1 && store.state.replies[0].adopted.isEmpty, "capture is not adoption")
    store.adopt(first, action: "sent", eligible: true)
    try check(store.state.replies[0].adopted.isEmpty, "cannot invent a sent event")
    store.adopt(first, action: "copied", eligible: true); store.adopt(first, action: "copied", eligible: true)
    try check(store.state.replies[0].adopted.count == 1, "repeated copy is one evidence item")
    var edited = first; edited.context = "corrected context"; edited.english = ""; store.record(edited, eligible: true)
    try check(store.state.replies[0].context == "corrected context" && store.state.replies[0].adopted.count == 1, "source corrections update current record and preserve adopted version")
    try check(store.context(query: first.source, privateReply: false, eligible: true).items.isEmpty, "raw historical facts never auto-promoted")
    let oneDay = fixture(now, ["简短一点"]), second = fixture(now, ["简短一点"])
    store.adopt(oneDay, action: "copied", eligible: true); store.adopt(second, action: "copied", eligible: true)
    try check(store.state.personal.isEmpty, "two sessions cannot establish style")
    let third = fixture(now.addingTimeInterval(-2 * 86400), ["简短一点"])
    store.adopt(third, action: "filled", eligible: true)
    try check(store.state.personal.count == 1 && store.state.personal[0].evidence.count == 3, "cross-day adopted instructions establish low-risk style")
    store.forgetSession(third.id)
    try check(store.state.personal.isEmpty, "deleting evidence retires unsupported learning")
    store.adopt(third, action: "copied", eligible: true)
    try check(!store.state.replies.contains { $0.id == third.id }, "deleted session cannot resurrect")
    store.savePersonal(kind: "term", source: "Orbit", value: "轨道产品")
    store.savePersonal(kind: "term", source: "orbit", value: "Sofi")
    try check(store.state.personal.count == 1, "term correction supersedes mapping")
    store.savePersonal(kind: "preference", source: "", value: "Prefer concise replies.")
    try check(!MemoryStore.matchesTerm("Orbit", in: "orbital") && MemoryStore.matchesTerm("Orbit", in: "使用Orbit产品"), "term boundary avoids partial English matches")
    let context = store.context(query: "What about Orbit?", privateReply: false, eligible: true)
    try check(context.items.count == 2 && context.terms.count == 1, "only matching terms and preferences retrieved")
    try check(store.context(query: "Unrelated customer", privateReply: false, eligible: true).terms.isEmpty, "no unrelated terms")
    try check(store.context(query: "Orbit", privateReply: true, eligible: true).items.isEmpty, "private reply has no reads")
    try check(store.context(query: "Orbit", privateReply: false, eligible: true, inputBytes: 12000).items.isEmpty, "current content takes precedence over memory budget")
    try check(store.context(query: "Orbit", privateReply: false, eligible: true, excluding: Set(context.items.map(\.id))).items.isEmpty, "exclude reference")
    let verification = ReplyPrompts.backTranslation("Fictional English")
    try check(verification.last?.content == "Fictional English" && !verification.map(\.content).joined().contains("Sofi"), "independent back-translation sees English only")
    try await wait { !store.saving }
    let bytes = try Data(contentsOf: url)
    try check(bytes.range(of: Data("PRIVATE_FIXTURE_SOURCE".utf8)) == nil && bytes.range(of: Data("Prefer concise".utf8)) == nil, "disk contains no plaintext contents or index")
    let reopened = MemoryStore(disk: MemoryDisk(url: url, testKey: key))
    try await wait { reopened.ready }
    try check(reopened.state.replies.sorted { $0.id.uuidString < $1.id.uuidString } == store.state.replies.sorted { $0.id.uuidString < $1.id.uuidString }, "encrypted restart preserves records")
    let wrong = MemoryStore(disk: MemoryDisk(url: url, testKey: Data(repeating: 12, count: 32)))
    try await wait { !wrong.error.isEmpty }
    try check(!wrong.ready && !wrong.enabled, "wrong key fails closed without replacing data")
    let before = try Data(contentsOf: url)
    try check(before == bytes, "failed decrypt does not rewrite database")
    store.setEnabled(false)
    try check(store.context(query: "Orbit", privateReply: false, eligible: true).items.isEmpty, "pause disables reads")
    store.setEnabled(true)
    let pending = fixture(); store.register(pending.id)
    store.clearAll(); store.record(pending, eligible: true)
    try check(store.state.replies.isEmpty && store.state.personal.isEmpty, "clear all blocks active late writes and derived data")
    try await wait { !store.saving }
    let empty = MemoryStore(disk: MemoryDisk(url: url, testKey: key)); try await wait { empty.ready }
    try check(empty.state.replies.isEmpty && empty.state.personal.isEmpty, "deletion survives restart")
    let old = fixture(now.addingTimeInterval(-100 * 86400)); store.record(old, eligible: true); store.prune(now: now)
    try check(store.state.replies.isEmpty, "retention removes expired history")

    // Fresh memory uses only a local key and never calls the Keychain.
    let service = "local.cellier.chillor.memory.test." + UUID().uuidString
    defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "vault-key"] as CFDictionary) }
    let keychainURL = folder.appendingPathComponent("keychain.sqlite")
    let keychainStore = MemoryStore(disk: MemoryDisk(url: keychainURL, keychainService: service, keychainRead: { _ in preconditionFailure("Fresh/local memory must not call Keychain") }))
    try await wait { keychainStore.ready }; keychainStore.setEnabled(true)
    try await wait { !keychainStore.saving }
    try check(keychainStore.error.isEmpty, "local key creation and encryption")
    let keychainReopen = MemoryStore(disk: MemoryDisk(url: keychainURL, keychainService: service, keychainRead: { _ in preconditionFailure("Fresh/local memory must not call Keychain") }))
    try await wait { keychainReopen.ready || !keychainReopen.error.isEmpty }
    try check(keychainReopen.ready && keychainReopen.enabled, "local key reload without Keychain")

    let localKeyURL = keychainURL.appendingPathExtension("key")
    let attributes = try FileManager.default.attributesOfItem(atPath: localKeyURL.path)
    let localKeyBytes = try Data(contentsOf: localKeyURL)
    try check(localKeyBytes.count == 32 && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "local key is readable only by its owner")

    // A changed signing identity must not prompt during startup or retries.
    // Simulate Keychain refusing silent access, then a canceled and successful unlock.
    let lockedURL = folder.appendingPathComponent("locked.sqlite")
    try FileManager.default.copyItem(at: url, to: lockedURL)
    let originalCiphertext = try Data(contentsOf: lockedURL)
    var originalInteraction = DarwinBoolean(false)
    SecKeychainGetUserInteractionAllowed(&originalInteraction)
    var interactions: [Bool] = []
    var allowCount = 0
    let lockedDisk = MemoryDisk(url: lockedURL, keychainRead: { query in
        let auth = (query as NSDictionary)[kSecUseAuthenticationContext] as! LAContext
        let interactive = !auth.interactionNotAllowed
        var processInteraction = DarwinBoolean(false)
        precondition(SecKeychainGetUserInteractionAllowed(&processInteraction) == errSecSuccess)
        precondition(processInteraction.boolValue == interactive, "Legacy Keychain UI policy must match")
        interactions.append(interactive)
        if !interactive { return (errSecInteractionNotAllowed, nil) }
        allowCount += 1
        return allowCount == 1 ? (errSecUserCanceled, nil) : (errSecSuccess, key)
    })
    let locked = MemoryStore(disk: lockedDisk)
    try await wait { !locked.loading }
    try check(locked.needsUnlock && !locked.ready && interactions == [false], "startup never authorizes Keychain UI")
    locked.record(fixture(now), eligible: true); locked.flush()
    let afterSilentFailure = try Data(contentsOf: lockedURL)
    try check(afterSilentFailure == originalCiphertext, "locked memory never overwrites ciphertext")
    locked.retrySave(); try await wait { !locked.loading }
    try check(interactions == [false, false], "ordinary retry remains noninteractive")
    locked.unlock(); locked.unlock(); try await wait { !locked.loading }
    try check(locked.needsUnlock && interactions == [false, false, true], "canceled unlock is not retried and duplicate unlock is ignored")
    let afterCanceledUnlock = try Data(contentsOf: lockedURL)
    try check(afterCanceledUnlock == originalCiphertext, "canceling unlock preserves memory")
    locked.unlock(); try await wait { !locked.loading }
    try check(locked.ready && !locked.needsUnlock && interactions == [false, false, true, true], "explicit unlock reuses the existing encryption key")
    locked.setEnabled(true); try await wait { !locked.saving }
    try check(interactions.count == 4, "background saves reuse the cached key")
    var restoredInteraction = DarwinBoolean(false)
    SecKeychainGetUserInteractionAllowed(&restoredInteraction)
    try check(restoredInteraction.boolValue == originalInteraction.boolValue, "process interaction policy restored")
    print("PASS: silent Keychain startup/retry, explicit unlock, canceled/duplicate unlock, ciphertext preservation and cached saves")

    let migrated = MemoryStore(disk: MemoryDisk(url: lockedURL, keychainRead: { _ in preconditionFailure("Migrated vault must not call Keychain") }))
    try await wait { migrated.ready || !migrated.error.isEmpty }
    try check(migrated.ready && migrated.enabled, "migration survives restart and unavailable Keychain")
    let badURL = folder.appendingPathComponent("wrong-legacy-key.sqlite")
    try FileManager.default.copyItem(at: url, to: badURL)
    let badBytes = try Data(contentsOf: badURL)
    let bad = MemoryStore(disk: MemoryDisk(url: badURL, keychainRead: { _ in (errSecSuccess, Data(repeating: 99, count: 32)) }))
    try await wait { !bad.loading }
    let afterBadRead = try Data(contentsOf: badURL)
    try check(!bad.ready && afterBadRead == badBytes && !FileManager.default.fileExists(atPath: badURL.appendingPathExtension("key").path), "failed decryption never publishes a migration key or replaces records")
    try Data([1,2,3]).write(to: localKeyURL)
    let corruptLocal = MemoryStore(disk: MemoryDisk(url: keychainURL, keychainRead: { _ in preconditionFailure("Corrupt local keys must not fall back or reset") }))
    try await wait { !corruptLocal.loading }
    let corruptKeyBytes = try Data(contentsOf: localKeyURL)
    try check(!corruptLocal.ready && corruptKeyBytes == Data([1,2,3]), "corrupt key is not silently replaced")
    print("PASS: local-only key creation/restart, owner-only permissions, legacy migration, failed migration preservation and corrupt-key protection")

    // Model integration uses deterministic fake generation, no real chats or clipboard.
    store.savePersonal(kind: "term", source: "Orbit", value: "Sofi")
    var requests: [[LocalChatMessage]] = []
    let model = ReplyModel(chat: { messages, options, delta in
        requests.append(messages)
        let result = options.label == Sampling.reading.label ? "阅读" : options.label == Sampling.draft.label ? "回复 Orbit" : options.label == Sampling.verify.label ? "回译" : "Reply about Sofi"
        delta(result); return result
    })
    model.memory = store
    model.updateSource(original: "What about Orbit?", context: "", immediate: true)
    model.setModelReady(true)
    try await wait { model.canCheck }
    try check(requests.count == 4, "four-stage pipeline unchanged")
    try check(requests[0].contains { $0.content.contains("Personal memory") } && requests[2].contains { $0.content.contains("Personal memory") }, "terms reach reading and reply")
    try check(!requests[3].contains { $0.content.contains("Personal memory") } && requests[3].last?.content == "Reply about Sofi", "verification receives no memory")
    model.checked = true
    model.copyToClipboard = { _ in false }; model.copyEnglish()
    try check(!store.state.replies.contains { !$0.adopted.isEmpty && $0.source == "What about Orbit?" }, "failed copy is not adopted")
    model.copyToClipboard = { _ in true }; model.copyEnglish()
    try check(store.state.replies.contains { $0.adopted.count == 1 && $0.source == "What about Orbit?" }, "successful confirmed copy records adoption")
    model.copyEnglish()
    try check(store.state.replies.first { $0.source == "What about Orbit?" }?.adopted.count == 1, "model copy deduplication")
    model.setPrivateReply(true); requests.removeAll()
    try await wait { model.canCheck }
    try check(requests.allSatisfy { !$0.contains { $0.content.contains("Personal memory") } }, "private regenerate has no memory")
    try check(!store.state.replies.contains { $0.source == "What about Orbit?" }, "switching private removes current stored session")
    model.english = "My hand-edited reply"
    model.setPrivateReply(false)
    try await wait { model.canCheck }
    try check(model.english == "My hand-edited reply", "privacy changes preserve hand-edited English")
    model.clear()
    requests.removeAll()
    model.updateSource(original: "Orbit demo", context: "", immediate: true, memoryEligible: false)
    try await wait { model.canCheck }
    try check(requests.allSatisfy { !$0.contains { $0.content.contains("Personal memory") } } && !store.state.replies.contains { $0.source == "Orbit demo" }, "demo neither reads nor writes")
    model.clear()
    try await wait { !store.saving }
    store.flush()
    print("PASS: encrypted memory, consent, private/demo isolation, adoption deduplication, evidence learning/deletion, restart, wrong-key failure, retention, scoped retrieval, prompt budget and independent back-translation")
}
