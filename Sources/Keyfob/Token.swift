import Foundation

struct Token: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var envVar: String
    var tags: [String]
    var notes: String
    var expiresAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        envVar: String = "",
        tags: [String] = [],
        notes: String = "",
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.envVar = envVar
        self.tags = tags
        self.notes = notes
        self.expiresAt = expiresAt
        self.createdAt = .now
        self.updatedAt = .now
    }

    var variableName: String {
        envVar.isEmpty ? Self.variableName(from: name) : envVar
    }

    static func variableName(from name: String) -> String {
        var out = ""
        for ch in name.uppercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else if !out.isEmpty && !out.hasSuffix("_") {
                out.append("_")
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if let first = out.first, first.isNumber { out = "_" + out }
        return out.isEmpty ? "TOKEN" : out
    }

    enum Expiry: Equatable {
        case none, valid, soon(days: Int), expired
    }

    func expiry(now: Date = .now) -> Expiry {
        guard let expiresAt else { return .none }
        if expiresAt <= now { return .expired }
        let days = Calendar.current.dateComponents([.day], from: now, to: expiresAt).day ?? 0
        return days < 14 ? .soon(days: days) : .valid
    }
}

struct Usage: Codable, Hashable {
    var lastUsed: Date
    var count: Int
}

enum CopyFormat {
    case value, export, dotenv

    func render(_ token: Token, secret: String) -> String {
        switch self {
        case .value: secret
        case .export: "export \(token.variableName)=\(Self.shellQuote(secret))"
        case .dotenv: "\(token.variableName)=\(Self.shellQuote(secret))"
        }
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:@+=,%")
        if !s.isEmpty && s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
