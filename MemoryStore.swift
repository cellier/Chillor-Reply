import Foundation
import SwiftUI
import CryptoKit
import Security
import LocalAuthentication
import SQLite3
import Darwin

struct RememberedVersion: Codable, Equatable, Identifiable {
    var id: String
    var at: Date
    var action: String // copied / filled; never means sent
    var source: String
    var context: String
    var draft: String
    var english: String
    var back: String
    var instructions: [String]
}
struct ReplyMemory: Codable, Equatable, Identifiable {
    var id: UUID
    var created: Date
    var updated: Date
    var app: String
    var sender: String
    var source: String
    var context: String
    var draft: String
    var english: String
    var back: String
    var instructions: [String]
    var adopted: [RememberedVersion] = []
    var searchText: String { ([app, sender, source, context, draft, english] + adopted.map { $0.english }).joined(separator: "\n") }
}
struct PersonalMemory: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: String // preference / term
    var source: String
    var value: String
    var created: Date = Date()
    var enabled: Bool = true
    var learned: String? = nil // limited to audited, low-risk style signals
    var evidence: [UUID] = []
}
struct MemoryState: Codable, Equatable {
    var schema: Int = 1
    var enabled: Bool = false
    var decided: Bool = false
    var retentionDays: Int = 90
    var replies: [ReplyMemory] = []
    var personal: [PersonalMemory] = []
    var suppressed: Set<String> = []
}
struct MemoryReference: Identifiable, Equatable {
    let id: UUID
    let title: String
    let value: String
    let kind: String
}
struct MemoryContext {
    var items: [MemoryReference] = []
    var terms: [MemoryReference] { items.filter { $0.kind == "term" } }
    // Only user-authored rules and vetted style signals enter prompts, never raw
    // captured history or an inferred relationship based on a display name.
    func applying(to messages: [LocalChatMessage], reading: Bool = false) -> [LocalChatMessage] {
        let selected = reading ? terms : items
        guard !selected.isEmpty else { return messages }
        let rows = selected.map { ["kind": $0.kind, "source": $0.title, "value": $0.value] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return messages }
        let policy = reading
            ? "Use these user-confirmed terminology mappings only when the source has that meaning. Do not add content, change tone or import facts."
            : "These are personal style preferences and terminology, not facts about this conversation. Apply only when relevant. The current user's intent and instructions take precedence. Never add facts, identities, offers, promises, dates or commitments from memory."
        // Insert before the user content, not after the latest user instruction.
        var result = messages
        result.insert(LocalChatMessage(role: "system", content: policy + "\nPersonal memory (JSON):\n" + text), at: min(1, result.count))
        return result
    }
}

enum MemoryFailure: Error { case keychain(OSStatus), database, corrupt, unsupportedSchema }

// The SQLite database stores authenticated ciphertext only. There is no plaintext
// full-text index, transcript file or embedding cache alongside it.
final class MemoryDisk: @unchecked Sendable {
    private static let interactionLock = NSLock()
    private let queue = DispatchQueue(label: "ChillorReply.memory", qos: .utility)
    let url: URL
    private let testKey: Data?
    private let keychainService: String
    private let keychainRead: (CFDictionary) -> (OSStatus, Data?)
    private var pendingLocalKey: Data?
    private var localKeyURL: URL { url.appendingPathExtension("key") }
    private var cachedKey: SymmetricKey?
    private var connection: OpaquePointer?
    private var lastRows: [String: Data] = [:]
    init(url: URL, testKey: Data? = nil, keychainService: String = "local.cellier.chillor.memory.v1", keychainRead: @escaping (CFDictionary) -> (OSStatus, Data?) = { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        return (status, result as? Data)
    }) { self.url = url; self.testKey = testKey; self.keychainService = keychainService; self.keychainRead = keychainRead }
    private func saveLocalKey(_ raw: Data) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let temporary = folder.appendingPathComponent(".memory-key-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw MemoryFailure.database }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        try raw.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw MemoryFailure.database }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw MemoryFailure.database }
        // Publish only a complete key, without replacing an existing key.
        if Darwin.link(temporary.path, localKeyURL.path) != 0 {
            guard errno == EEXIST, try Data(contentsOf: localKeyURL) == raw else { throw MemoryFailure.corrupt }
        }
        var file = localKeyURL
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
    }
    private func key(allowInteraction: Bool = false) throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        if let testKey { let key = SymmetricKey(data: testKey); cachedKey = key; return key }
        if FileManager.default.fileExists(atPath: localKeyURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: localKeyURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw MemoryFailure.corrupt }
            let raw = try Data(contentsOf: localKeyURL)
            guard raw.count == 32 else { throw MemoryFailure.corrupt }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localKeyURL.path)
            let key = SymmetricKey(data: raw); cachedKey = key; return key
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try saveLocalKey(raw)
            let key = SymmetricKey(data: raw); cachedKey = key; return key
        }
        // Legacy vault only: recover its existing key once, without deleting it.
        // The login (file-based) Keychain ignores SecItem's per-query UI policy.
        // Serialize and restore this process-local setting; never change item ACLs.
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        var previousInteraction = DarwinBoolean(false)
        let previousStatus = SecKeychainGetUserInteractionAllowed(&previousInteraction)
        guard previousStatus == errSecSuccess else { throw MemoryFailure.keychain(previousStatus) }
        let policyStatus = SecKeychainSetUserInteractionAllowed(allowInteraction)
        guard policyStatus == errSecSuccess else { throw MemoryFailure.keychain(policyStatus) }
        defer { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "vault-key",
            kSecAttrSynchronizable as String: false]
        let authentication = LAContext()
        authentication.interactionNotAllowed = !allowInteraction
        var read = query; read[kSecUseAuthenticationContext as String] = authentication; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychainRead(read as CFDictionary)
        let raw: Data
        if status == errSecSuccess, let data = result, data.count == 32 { raw = data }
        else { throw MemoryFailure.keychain(status) }
        pendingLocalKey = raw // Persist only after every legacy row decrypts successfully.
        let key = SymmetricKey(data: raw); cachedKey = key; return key
    }
    private func db(allowInteraction: Bool = false) throws -> OpaquePointer {
        if let connection { return connection }
        _ = try key(allowInteraction: allowInteraction)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { throw MemoryFailure.database }
        connection = db
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS vault (id TEXT PRIMARY KEY, payload BLOB NOT NULL);", db)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var resourceURL = url; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? resourceURL.setResourceValues(values)
        return db
    }
    private func execute(_ sql: String, _ db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MemoryFailure.database }
    }
    func load(allowInteraction: Bool = false, _ completion: @escaping @Sendable (Result<MemoryState, Error>) -> Void) {
        queue.async {
            do {
                // No disk/keychain creation until the user opts in or saves settings.
                guard FileManager.default.fileExists(atPath: self.url.path) else { completion(.success(MemoryState())); return }
                let db = try self.db(allowInteraction: allowInteraction), key = try self.key()
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT id,payload FROM vault", -1, &stmt, nil) == SQLITE_OK else { throw MemoryFailure.database }
                defer { sqlite3_finalize(stmt) }
                var state = MemoryState(), replies: [ReplyMemory] = [], personal: [PersonalMemory] = []
                let decoder = JSONDecoder()
                var step = sqlite3_step(stmt)
                while step == SQLITE_ROW {
                    guard let name = sqlite3_column_text(stmt, 0), let bytes = sqlite3_column_blob(stmt, 1) else { throw MemoryFailure.corrupt }
                    let id = String(cString: name)
                    let sealed = try AES.GCM.SealedBox(combined: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1))))
                    let data = try AES.GCM.open(sealed, using: key, authenticating: Data(id.utf8))
                    self.lastRows[id] = data
                    if id == "settings" { state = try decoder.decode(MemoryState.self, from: data) }
                    else if id.hasPrefix("reply:") { replies.append(try decoder.decode(ReplyMemory.self, from: data)) }
                    else if id.hasPrefix("personal:") { personal.append(try decoder.decode(PersonalMemory.self, from: data)) }
                    else { throw MemoryFailure.corrupt }
                    step = sqlite3_step(stmt)
                }
                guard step == SQLITE_DONE else { throw MemoryFailure.database }
                guard state.schema == 1 else { throw MemoryFailure.unsupportedSchema }
                state.replies = replies; state.personal = personal
                if let raw = self.pendingLocalKey { try self.saveLocalKey(raw); self.pendingLocalKey = nil }
                completion(.success(state))
            } catch { completion(.failure(error)) }
        }
    }
    func save(_ state: MemoryState, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                let db = try self.db(), key = try self.key(), encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                var settings = state; settings.replies = []; settings.personal = []
                var rows = ["settings": try encoder.encode(settings)]
                for record in state.replies { rows["reply:" + record.id.uuidString] = try encoder.encode(record) }
                for record in state.personal { rows["personal:" + record.id.uuidString] = try encoder.encode(record) }
                try self.execute("BEGIN IMMEDIATE", db)
                do {
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    for id in self.lastRows.keys where rows[id] == nil {
                        var stmt: OpaquePointer?
                        guard sqlite3_prepare_v2(db, "DELETE FROM vault WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw MemoryFailure.database }
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_text(stmt, 1, id, -1, transient)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MemoryFailure.database }
                    }
                    for (id, data) in rows where self.lastRows[id] != data {
                        let encrypted = try AES.GCM.seal(data, using: key, authenticating: Data(id.utf8)).combined!
                        var stmt: OpaquePointer?
                        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO vault(id,payload) VALUES(?,?)", -1, &stmt, nil) == SQLITE_OK else { throw MemoryFailure.database }
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_text(stmt, 1, id, -1, transient)
                        _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(encrypted.count), transient) }
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MemoryFailure.database }
                    }
                    try self.execute("COMMIT", db)
                    self.lastRows = rows
                } catch { try? self.execute("ROLLBACK", db); throw error }
                completion(true)
            } catch { completion(false) }
        }
    }
    func flush() { queue.sync {} }
    deinit { if let connection { sqlite3_close(connection) } }
}

@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var state = MemoryState()
    @Published private(set) var ready = false
    @Published private(set) var error = ""
    @Published private(set) var generation = 0
    @Published private(set) var saving = false
    @Published private(set) var needsUnlock = false
    @Published private(set) var loading = false
    private let disk: MemoryDisk
    private var writeID = 0
    private var blockedSessions: Set<UUID> = []
    private var activeSessions: Set<UUID> = []
    var enabled: Bool { ready && state.enabled && error.isEmpty }
    init(disk: MemoryDisk? = nil) {
        self.disk = disk ?? MemoryDisk(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ChillorReply/memory.sqlite"))
        load()
    }
    func load(allowInteraction: Bool = false) {
        guard !loading else { return }
        loading = true; ready = false
        disk.load(allowInteraction: allowInteraction) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let state): self.state = state; self.needsUnlock = false; self.error = ""; self.ready = true; self.prune(); self.generation += 1
                case .failure(let failure):
                    if case MemoryFailure.keychain = failure {
                        self.needsUnlock = true
                        self.error = "旧版记忆需要一次迁移。完成后无需再解锁，已有记录会保留。"
                    } else { self.needsUnlock = false; self.error = "记忆暂不可用，当前回复不会保存。" }
                    self.ready = false
                }
            }
        }
    }
    private func persist() {
        guard ready else { return }
        writeID += 1; let id = writeID; saving = true
        disk.save(state) { [weak self] success in
            Task { @MainActor in
                guard let self, self.writeID == id else { return }
                self.saving = false
                self.error = success ? "" : "记忆未能保存，请打开记忆重试。"
            }
        }
    }
    // Only a deliberate user action may allow a system authorization prompt.
    func unlock() { load(allowInteraction: true) }
    func retrySave() { if ready { persist() } else { load() } }
    func flush() { disk.flush() }
    func register(_ id: UUID) { activeSessions.insert(id) }
    func setEnabled(_ enabled: Bool) {
        guard ready else { return }
        state.decided = true; state.enabled = enabled; generation += 1; persist()
    }
    func setRetention(_ days: Int) {
        guard [30,90,0].contains(days) else { return }
        state.retentionDays = days; prune(); persist()
    }
    func prune(now: Date = Date()) {
        guard state.retentionDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(state.retentionDays) * 86400)
        let removed = state.replies.filter { $0.updated < cutoff }.map(\.id)
        guard !removed.isEmpty else { return }
        blockedSessions.formUnion(removed); state.replies.removeAll { removed.contains($0.id) }
        reconcileLearning(); generation += 1; persist()
    }
    func record(_ snapshot: ReplyMemory, eligible: Bool) {
        guard enabled, eligible, !blockedSessions.contains(snapshot.id), !snapshot.source.isEmpty || !snapshot.draft.isEmpty else { return }
        var record = snapshot
        if let i = state.replies.firstIndex(where: { $0.id == record.id }) {
            record.created = state.replies[i].created; record.adopted = state.replies[i].adopted
            // Captures and edits never replace adopted evidence with generated drafts.
            if record == state.replies[i] { return }
            state.replies[i] = record
        } else { state.replies.append(record) }
        persist()
    }
    func adopt(_ snapshot: ReplyMemory, action: String, eligible: Bool) {
        guard enabled, eligible, ["copied","filled"].contains(action), !blockedSessions.contains(snapshot.id), !snapshot.english.isEmpty else { return }
        record(snapshot, eligible: eligible)
        guard let i = state.replies.firstIndex(where: { $0.id == snapshot.id }) else { return }
        let evidenceData = try? JSONEncoder().encode([snapshot.source, snapshot.context, snapshot.draft, snapshot.english, snapshot.instructions.joined(separator: "\n")])
        let hash = SHA256.hash(data: evidenceData ?? Data()).map { String(format: "%02x", $0) }.joined()
        guard !state.replies[i].adopted.contains(where: { $0.id == hash }) else { return }
        state.replies[i].adopted.append(RememberedVersion(id: hash, at: snapshot.updated, action: action, source: snapshot.source, context: snapshot.context, draft: snapshot.draft, english: snapshot.english, back: snapshot.back, instructions: snapshot.instructions))
        reconcileLearning(); persist()
    }
    func forgetSession(_ id: UUID) {
        blockedSessions.insert(id); state.replies.removeAll { $0.id == id }
        reconcileLearning(); generation += 1; persist()
    }
    func clearAll() {
        blockedSessions.formUnion(activeSessions); blockedSessions.formUnion(state.replies.map(\.id))
        state.replies = []; state.personal = []; state.suppressed = []
        generation += 1; persist()
    }
    func savePersonal(id: UUID? = nil, kind: String, source: String, value: String) {
        let source = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let value = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard ready, ["preference","term"].contains(kind), !value.isEmpty, kind != "term" || !source.isEmpty else { return }
        if let id, let i = state.personal.firstIndex(where: { $0.id == id }) {
            state.personal[i].source = source; state.personal[i].value = value; state.personal[i].kind = kind
            if let code = state.personal[i].learned { state.suppressed.insert(code) }
            state.personal[i].learned = nil; state.personal[i].evidence = []
        } else {
            // One active mapping per exact term. A correction supersedes it.
            if kind == "term" { state.personal.removeAll { $0.kind == "term" && $0.source.caseInsensitiveCompare(source) == .orderedSame } }
            state.personal.append(PersonalMemory(kind: kind, source: source, value: value))
        }
        generation += 1; persist()
    }
    func setPersonalEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = state.personal.firstIndex(where: { $0.id == id }) else { return }
        state.personal[i].enabled = enabled; generation += 1; persist()
    }
    func deletePersonal(_ id: UUID) {
        if let code = state.personal.first(where: { $0.id == id })?.learned { state.suppressed.insert(code) }
        state.personal.removeAll { $0.id == id }; generation += 1; persist()
    }
    static let styleSignals: [(String, String, Set<String>)] = [
        ("shorter", "Prefer concise replies, without dropping the user's intended meaning.", ["写得更简短，保留原有意思。", "简短一点", "shorter", "make it shorter", "please make it shorter"]),
        ("softer", "Prefer a softer, natural tone without adding apologies, offers or commitments.", ["语气再柔和自然一点，不增加任何承诺。", "柔和一点", "softer", "make it softer", "please make it softer"])
    ]
    private func reconcileLearning() {
        for (code, rule, signals) in Self.styleSignals {
            var seenVersions: Set<String> = []
            let evidence = state.replies.sorted { $0.updated > $1.updated }.filter { record in
                guard let version = record.adopted.last,
                      version.instructions.contains(where: { signals.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) else { return false }
                return seenVersions.insert(version.id).inserted
            }
            let days = Set(evidence.compactMap { $0.adopted.last?.at }.map { Calendar.current.startOfDay(for: $0) })
            let qualifies = evidence.count >= 3 && days.count >= 2 && !state.suppressed.contains(code)
            if let i = state.personal.firstIndex(where: { $0.learned == code }) {
                if qualifies { state.personal[i].evidence = evidence.map(\.id) }
                else { state.personal.remove(at: i) }
            } else if qualifies {
                state.personal.append(PersonalMemory(kind: "preference", source: code == "shorter" ? "更简洁的回复" : "更柔和的语气", value: rule, learned: code, evidence: evidence.map(\.id)))
            }
        }
    }
    static func matchesTerm(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])"
        if term.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return text.localizedCaseInsensitiveContains(term)
    }
    func context(query: String, privateReply: Bool, eligible: Bool, excluding: Set<UUID> = [], inputBytes: Int = 0) -> MemoryContext {
        guard enabled, !privateReply, eligible else { return MemoryContext() }
        // Byte cap is conservative for the existing 6144-token model context.
        let budget = min(2000, max(0, 12000 - inputBytes - 1200))
        var remaining = budget, result: [MemoryReference] = []
        let terms = state.personal.filter { $0.enabled && $0.kind == "term" && Self.matchesTerm($0.source, in: query) }
        let rules = state.personal.filter { $0.enabled && $0.kind == "preference" }.sorted { ($0.learned == nil ? 0 : 1) < ($1.learned == nil ? 0 : 1) }
        for item in terms + rules where !excluding.contains(item.id) {
            let cost = item.source.utf8.count + item.value.utf8.count + 120
            guard cost <= remaining, result.count < 6 else { continue }
            result.append(MemoryReference(id: item.id, title: item.source, value: item.value, kind: item.kind)); remaining -= cost
        }
        return MemoryContext(items: result)
    }
}
