import Foundation
import Observation

enum StoreError: LocalizedError {
    case missingName, missingValue

    var errorDescription: String? {
        switch self {
        case .missingName: "A name is required."
        case .missingValue: "A token value is required."
        }
    }
}

@MainActor @Observable
final class TokenStore {
    private(set) var tokens: [Token] = []
    private(set) var usage: [String: Usage] = [:]
    private(set) var loadError: String?

    private let usageKey = "usage.v1"
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: usageKey),
           let saved = try? JSONDecoder().decode([String: Usage].self, from: data) {
            usage = saved
        }
    }

    var allTags: [String] {
        Set(tokens.flatMap(\.tags)).sorted()
    }

    func token(id: String) -> Token? {
        tokens.first { $0.id == id }
    }

    func reload() {
        do {
            tokens = try Keychain.list()
                .map(decode)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func decode(_ record: KeychainRecord) -> Token {
        if let data = record.generic, var token = try? decoder.decode(Token.self, from: data) {
            token.id = record.account
            return token
        }
        return Token(id: record.account, name: record.label ?? record.account)
    }

    @discardableResult
    func save(_ token: Token, value: String?) throws -> Token {
        var token = token
        token.name = token.name.trimmingCharacters(in: .whitespacesAndNewlines)
        token.envVar = token.envVar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.name.isEmpty else { throw StoreError.missingName }
        token.updatedAt = .now

        let secret = value
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        let meta = try encoder.encode(token)

        if self.token(id: token.id) != nil {
            try Keychain.update(account: token.id, label: token.name, generic: meta, secret: secret)
        } else {
            guard let secret else { throw StoreError.missingValue }
            try Keychain.add(account: token.id, label: token.name, generic: meta, secret: secret)
        }
        reload()
        return token
    }

    func delete(id: String) throws {
        try Keychain.delete(account: id)
        usage[id] = nil
        persistUsage()
        reload()
    }

    func secret(for id: String) throws -> String {
        let data = try Keychain.read(account: id)
        guard let string = String(data: data, encoding: .utf8) else { throw KeychainError.badData }
        return string
    }

    func recordUse(_ id: String) {
        var entry = usage[id] ?? Usage(lastUsed: .now, count: 0)
        entry.lastUsed = .now
        entry.count += 1
        usage[id] = entry
        persistUsage()
    }

    private func persistUsage() {
        if let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: usageKey)
        }
    }
}
