import Foundation
import Observation

enum Fuzzy {
    static func score(_ query: String, _ text: String, substringOnly: Bool = false) -> Double? {
        guard !query.isEmpty, !text.isEmpty else { return nil }
        let t = Array(text.lowercased())
        let q = Array(query.lowercased())
        guard q.count <= t.count else { return nil }

        if let start = firstIndex(of: q, in: t) {
            var s = 100.0 - Double(min(start, 40))
            if start == 0 {
                s += 40
            } else if isBoundary(t, start) {
                s += 20
            }
            if q.count == t.count { s += 30 }
            return s
        }
        guard !substringOnly else { return nil }

        var s = 0.0
        var qi = 0
        var last = -2
        for (i, c) in t.enumerated() where qi < q.count && c == q[qi] {
            s += 2
            if i == last + 1 { s += 4 }
            if isBoundary(t, i) { s += 6 }
            last = i
            qi += 1
        }
        return qi == q.count ? s : nil
    }

    private static func firstIndex(of q: [Character], in t: [Character]) -> Int? {
        for i in 0...(t.count - q.count) where t[i] == q[0] && t[i..<i + q.count].elementsEqual(q) {
            return i
        }
        return nil
    }

    private static func isBoundary(_ t: [Character], _ i: Int) -> Bool {
        i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber)
    }
}

enum Ranker {
    static func rank(_ tokens: [Token], query: String, usage: [String: Usage]) -> [Token] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return byRecency(tokens, usage: usage) }

        var scored: [(token: Token, score: Double)] = []
        for token in tokens {
            var total = 0.0
            var matchedAll = true
            for term in terms {
                let candidates: [Double?] = [
                    Fuzzy.score(term, token.name),
                    Fuzzy.score(term, token.variableName).map { $0 * 0.9 },
                    token.tags.compactMap { Fuzzy.score(term, $0) }.max().map { $0 * 0.8 },
                    Fuzzy.score(term, token.notes, substringOnly: true).map { $0 * 0.3 },
                ]
                guard let best = candidates.compactMap({ $0 }).max() else {
                    matchedAll = false
                    break
                }
                total += best
            }
            guard matchedAll else { continue }
            total += log1p(Double(usage[token.id]?.count ?? 0)) * 3
            scored.append((token, total))
        }
        return scored.sorted { $0.score > $1.score }.map(\.token)
    }

    private static func byRecency(_ tokens: [Token], usage: [String: Usage]) -> [Token] {
        tokens.sorted { a, b in
            switch (usage[a.id]?.lastUsed, usage[b.id]?.lastUsed) {
            case let (x?, y?): x > y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}

@MainActor @Observable
final class SearchModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selection = 0
            message = nil
        }
    }
    var selection = 0
    var message: String?
    private(set) var presentCount = 0

    @ObservationIgnored var onCopy: (Token, CopyFormat) -> Void = { _, _ in }
    @ObservationIgnored var onNew: (String) -> Void = { _ in }
    @ObservationIgnored var onEdit: (Token) -> Void = { _ in }
    @ObservationIgnored var onSettings: () -> Void = {}
    @ObservationIgnored var onManage: () -> Void = {}

    let store: TokenStore
    let lock: SessionLock

    init(store: TokenStore, lock: SessionLock) {
        self.store = store
        self.lock = lock
    }

    var results: [Token] {
        Ranker.rank(store.tokens, query: query, usage: store.usage)
    }

    var selected: Token? {
        let r = results
        return r.indices.contains(selection) ? r[selection] : nil
    }

    func prepareForPresent() {
        query = ""
        selection = 0
        message = nil
        presentCount += 1
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func submit(_ format: CopyFormat) {
        if let token = selected {
            onCopy(token, format)
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty || store.tokens.isEmpty {
            onNew(query.trimmingCharacters(in: .whitespaces))
        }
    }

    func editSelected() {
        if let token = selected { onEdit(token) }
    }
}
