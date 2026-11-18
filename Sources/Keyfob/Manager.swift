import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class ManagerModel {
    enum Category: Hashable {
        case all, recent, expiring
        case tag(String)
    }

    struct Draft {
        var token: Token
        var value = ""
        var isNew: Bool
        var tagsText: String
        var hasExpiry: Bool
        var expiry: Date

        init(token: Token, isNew: Bool) {
            self.token = token
            self.isNew = isNew
            tagsText = token.tags.joined(separator: ", ")
            hasExpiry = token.expiresAt != nil
            expiry = token.expiresAt ?? Calendar.current.date(byAdding: .day, value: 90, to: .now) ?? .now
        }

        var canSave: Bool {
            !token.name.trimmingCharacters(in: .whitespaces).isEmpty
                && (!isNew || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        func materialized() -> Token {
            var t = token
            t.tags = tagsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            t.expiresAt = hasExpiry ? expiry : nil
            return t
        }
    }

    struct ImportSession {
        var source: String
        var entries: [DotEnv.Entry]
        var tag: String
    }

    var category: Category? = .all
    var selection: String? {
        didSet { if selection != oldValue { resetDetail() } }
    }
    var search = ""
    var isEditing = false
    var editDraft: Draft?
    var newDraft: Draft?
    var revealed: String?
    var pendingDelete: Token?
    var importSession: ImportSession?
    var error: String?

    @ObservationIgnored var onCopy: (Token, CopyFormat) -> Void = { _, _ in }

    let store: TokenStore
    let lock: SessionLock

    init(store: TokenStore, lock: SessionLock) {
        self.store = store
        self.lock = lock
    }

    var selectedToken: Token? {
        selection.flatMap(store.token(id:))
    }

    var tags: [String] { store.allTags }

    var categoryTitle: String {
        switch category ?? .all {
        case .all: "All Tokens"
        case .recent: "Recently Used"
        case .expiring: "Expiring"
        case .tag(let tag): tag
        }
    }

    func tokens(in category: Category) -> [Token] {
        switch category {
        case .all:
            return store.tokens
        case .recent:
            return store.tokens
                .filter { store.usage[$0.id] != nil }
                .sorted { (store.usage[$0.id]?.lastUsed ?? .distantPast) > (store.usage[$1.id]?.lastUsed ?? .distantPast) }
        case .expiring:
            return store.tokens
                .filter { $0.expiry().isUrgent }
                .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        case .tag(let tag):
            return store.tokens.filter { $0.tags.contains(tag) }
        }
    }

    var visibleTokens: [Token] {
        let base = tokens(in: category ?? .all)
        return search.isEmpty ? base : Ranker.rank(base, query: search, usage: store.usage)
    }

    func select(_ id: String) {
        if let category, !tokens(in: category).contains(where: { $0.id == id }) {
            self.category = .all
        }
        search = ""
        if selection == id { resetDetail() } else { selection = id }
    }

    private func resetDetail() {
        isEditing = false
        editDraft = nil
        revealed = nil
    }

    func newToken(name: String = "") {
        newDraft = Draft(token: Token(name: name), isNew: true)
    }

    func saveNew() {
        guard let draft = newDraft, draft.canSave else { return }
        do {
            let saved = try store.save(draft.materialized(), value: draft.value)
            newDraft = nil
            select(saved.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func beginEditing() {
        guard let token = selectedToken else { return }
        editDraft = Draft(token: token, isNew: false)
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        editDraft = nil
    }

    func commitEditing() {
        guard let draft = editDraft, draft.canSave else { return }
        do {
            try store.save(draft.materialized(), value: draft.value)
            revealed = nil
            cancelEditing()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func confirmDelete() {
        guard let token = pendingDelete else { return }
        pendingDelete = nil
        do {
            try store.delete(id: token.id)
            if selection == token.id { selection = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copy(_ token: Token, as format: CopyFormat = .value) {
        onCopy(token, format)
    }

    func toggleReveal() async {
        guard let token = selectedToken else { return }
        if revealed != nil {
            revealed = nil
            return
        }
        guard await lock.authorize(reason: "reveal “\(token.name)”") else { return }
        do {
            let secret = try store.secret(for: token.id)
            if selection == token.id { revealed = secret }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func beginImport() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .env file to import."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let existing = Set(store.tokens.map(\.variableName))
            let entries = DotEnv.parse(text).map { entry in
                var e = entry
                e.exists = existing.contains(e.key)
                e.include = !e.exists
                return e
            }
            guard !entries.isEmpty else {
                error = "No KEY=value pairs were found in \(url.lastPathComponent)."
                return
            }
            importSession = ImportSession(
                source: url.lastPathComponent,
                entries: entries,
                tag: url.deletingLastPathComponent().lastPathComponent.lowercased()
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    func commitImport() {
        guard let session = importSession else { return }
        let tag = session.tag.trimmingCharacters(in: .whitespaces).lowercased()
        for entry in session.entries where entry.include {
            let token = Token(name: entry.key, envVar: entry.key, tags: tag.isEmpty ? [] : [tag])
            do {
                try store.save(token, value: entry.value)
            } catch {
                self.error = "\(entry.key): \(error.localizedDescription)"
            }
        }
        importSession = nil
        if !tag.isEmpty { category = .tag(tag) }
    }
}

struct ManagerView: View {
    @Bindable var model: ManagerModel

    var body: some View {
        NavigationSplitView {
            SidebarColumn(model: model)
        } content: {
            TokenListColumn(model: model)
        } detail: {
            DetailColumn(model: model)
        }
        .sheet(isPresented: present(\.newDraft)) {
            NewTokenSheet(model: model)
        }
        .sheet(isPresented: present(\.importSession)) {
            ImportSheet(model: model)
        }
        .confirmationDialog(
            "Delete “\(model.pendingDelete?.name ?? "")”?",
            isPresented: present(\.pendingDelete)
        ) {
            Button("Delete Token", role: .destructive) { model.confirmDelete() }
        } message: {
            Text("This permanently removes the token from your keychain.")
        }
        .alert("Something Went Wrong", isPresented: present(\.error)) {
            Button("OK") {}
        } message: {
            Text(model.error ?? "")
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private func present<T>(_ keyPath: ReferenceWritableKeyPath<ManagerModel, T?>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] != nil },
            set: { if !$0 { model[keyPath: keyPath] = nil } }
        )
    }
}

struct SidebarColumn: View {
    @Bindable var model: ManagerModel

    var body: some View {
        List(selection: $model.category) {
            Section {
                row("All Tokens", "key.horizontal", .all)
                row("Recently Used", "clock", .recent)
                row("Expiring", "calendar.badge.exclamationmark", .expiring)
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.self) { tag in
                        row(tag, "tag", .tag(tag))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }

    private func row(_ title: String, _ symbol: String, _ category: ManagerModel.Category) -> some View {
        Label(title, systemImage: symbol)
            .badge(model.tokens(in: category).count)
            .tag(category)
    }
}

struct TokenListColumn: View {
    @Bindable var model: ManagerModel

    var body: some View {
        let tokens = model.visibleTokens
        List(tokens, selection: $model.selection) { token in
            TokenListRow(token: token)
                .contextMenu { contextMenu(for: token) }
        }
        .overlay {
            if tokens.isEmpty {
                if !model.search.isEmpty {
                    ContentUnavailableView.search(text: model.search)
                } else if model.store.tokens.isEmpty {
                    ContentUnavailableView {
                        Label("No Tokens", systemImage: "key.horizontal")
                    } description: {
                        Text("Add a token or import a .env file to get started.")
                    } actions: {
                        Button("New Token") { model.newToken() }
                    }
                } else {
                    ContentUnavailableView("No Tokens", systemImage: "key.horizontal")
                }
            }
        }
        .searchable(text: $model.search, prompt: "Search")
        .navigationTitle(model.categoryTitle)
        .navigationSubtitle(tokens.count == 1 ? "1 token" : "\(tokens.count) tokens")
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Token", systemImage: "plus") { model.newToken() }
                    Button("Import from .env File…", systemImage: "square.and.arrow.down") { model.beginImport() }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    model.newToken()
                }
                .help("New Token")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for token: Token) -> some View {
        Button("Copy Token", systemImage: "doc.on.doc") { model.copy(token) }
        Button("Copy as Export Line", systemImage: "terminal") { model.copy(token, as: .export) }
        Button("Copy as .env Line", systemImage: "doc.plaintext") { model.copy(token, as: .dotenv) }
        Divider()
        Button("Edit", systemImage: "pencil") {
            model.select(token.id)
            model.beginEditing()
        }
        Button("Delete…", systemImage: "trash", role: .destructive) { model.pendingDelete = token }
    }
}

struct TokenListRow: View {
    let token: Token

    var body: some View {
        let expiry = token.expiry()
        HStack(spacing: 10) {
            Monogram(name: token.name, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(token.variableName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if expiry.isUrgent {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(expiry.tint)
                    .help(expiry.label ?? "")
            }
        }
        .padding(.vertical, 3)
    }
}

struct DetailColumn: View {
    @Bindable var model: ManagerModel

    var body: some View {
        Group {
            if let token = model.selectedToken {
                if model.isEditing, let draft = Binding($model.editDraft) {
                    TokenForm(draft: draft) {
                        Section {
                            Button("Delete Token", role: .destructive) { model.pendingDelete = token }
                                .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    TokenDetail(token: token, model: model)
                }
            } else {
                ContentUnavailableView(
                    "No Token Selected",
                    systemImage: "key.horizontal",
                    description: Text("Select a token to view its details.")
                )
            }
        }
        .toolbar {
            if model.selectedToken != nil {
                if model.isEditing {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Cancel") { model.cancelEditing() }
                            .keyboardShortcut(.cancelAction)
                        Button("Done") { model.commitEditing() }
                            .keyboardShortcut("s")
                            .buttonStyle(.borderedProminent)
                            .disabled(model.editDraft?.canSave != true)
                    }
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let token = model.selectedToken {
                            Menu {
                                Button("Copy Token") { model.copy(token) }
                                Button("Copy as Export Line") { model.copy(token, as: .export) }
                                Button("Copy as .env Line") { model.copy(token, as: .dotenv) }
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            } primaryAction: {
                                model.copy(token)
                            }
                            .help("Copy Token")
                        }
                        Button("Edit") { model.beginEditing() }
                            .keyboardShortcut("e")
                    }
                }
            }
        }
    }
}

struct TokenDetail: View {
    let token: Token
    @Bindable var model: ManagerModel

    var body: some View {
        let expiry = token.expiry()
        let usage = model.store.usage[token.id]
        Form {
            Section {
                HStack(spacing: 16) {
                    Monogram(name: token.name, size: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(token.name)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text("Last modified \(token.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                LabeledContent("Variable") {
                    Text(token.variableName)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Token") {
                    HStack(spacing: 10) {
                        Text(model.revealed ?? String(repeating: "•", count: 16))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            Task { await model.toggleReveal() }
                        } label: {
                            Image(systemName: model.revealed == nil ? "eye" : "eye.slash")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.borderless)
                        .help(model.revealed == nil ? "Show Token" : "Hide Token")
                        Button {
                            model.copy(token)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy Token")
                    }
                }
            }

            Section {
                LabeledContent("Tags", value: token.tags.isEmpty ? "None" : token.tags.joined(separator: ", "))
                LabeledContent("Expires") {
                    if let date = token.expiresAt {
                        HStack(spacing: 6) {
                            Text(date.formatted(date: .long, time: .omitted))
                            if let label = expiry.label {
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(expiry.tint)
                            }
                        }
                    } else {
                        Text("Never")
                    }
                }
            }

            if !token.notes.isEmpty {
                Section("Notes") {
                    Text(token.notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Activity") {
                LabeledContent("Created", value: token.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last Copied", value: usage.map { $0.lastUsed.formatted(.relative(presentation: .named)) } ?? "Never")
                LabeledContent("Times Copied", value: "\(usage?.count ?? 0)")
            }
        }
        .formStyle(.grouped)
    }
}

struct TokenForm<Footer: View>: View {
    let draft: Binding<ManagerModel.Draft>
    @ViewBuilder var footer: Footer

    var body: some View {
        let d = draft.wrappedValue
        Form {
            Section {
                TextField("Name", text: draft.token.name, prompt: Text("Required"))
                TextField("Variable", text: draft.token.envVar, prompt: Text(Token.variableName(from: d.token.name)))
                    .font(.body.monospaced())
                SecureField("Token", text: draft.value, prompt: Text(d.isNew ? "Required" : "Unchanged"))
                    .font(.body.monospaced())
            }
            Section {
                TextField("Tags", text: draft.tagsText, prompt: Text("Comma separated"))
                Toggle("Expires", isOn: draft.hasExpiry)
                if d.hasExpiry {
                    DatePicker("Expiration Date", selection: draft.expiry, displayedComponents: .date)
                }
            }
            Section("Notes") {
                TextField("Notes", text: draft.token.notes, prompt: Text("Scopes, where it's used…"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(3...8)
            }
            footer
        }
        .formStyle(.grouped)
    }
}

extension TokenForm where Footer == EmptyView {
    init(draft: Binding<ManagerModel.Draft>) {
        self.draft = draft
        self.footer = EmptyView()
    }
}

struct NewTokenSheet: View {
    @Bindable var model: ManagerModel

    var body: some View {
        if let draft = Binding($model.newDraft) {
            VStack(spacing: 0) {
                Text("New Token")
                    .font(.headline)
                    .padding(.top, 20)
                TokenForm(draft: draft)
                    .scrollDisabled(true)
                HStack {
                    Spacer()
                    Button("Cancel") { model.newDraft = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { model.saveNew() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.wrappedValue.canSave)
                }
                .controlSize(.large)
                .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 460, height: draft.wrappedValue.hasExpiry ? 540 : 500)
        }
    }
}

struct ImportSheet: View {
    @Bindable var model: ManagerModel

    var body: some View {
        if let session = Binding($model.importSession) {
            let count = session.wrappedValue.entries.filter(\.include).count
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("Import from \(session.wrappedValue.source)")
                        .font(.headline)
                    Text("Keys you already have are unchecked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                Form {
                    Section {
                        ForEach(session.entries) { $entry in
                            Toggle(isOn: $entry.include) {
                                HStack {
                                    Text(entry.key).font(.body.monospaced())
                                    if entry.exists {
                                        Text("Exists").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        TextField("Tag", text: session.tag, prompt: Text("Optional"))
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Cancel") { model.importSession = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(count == 1 ? "Import 1 Token" : "Import \(count) Tokens") { model.commitImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(count == 0)
                }
                .controlSize(.large)
                .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 480, height: 460)
        }
    }
}
