import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class ManagerModel {
    struct Draft {
        var token: Token
        var value = ""
        var isNew: Bool
        var revealed = false
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

    var selection: String? {
        didSet { if selection != oldValue { loadSelection() } }
    }
    var draft: Draft?
    var search = ""
    var error: String?
    var status: String?
    var importSession: ImportSession?

    @ObservationIgnored var onCopy: (Token) -> Void = { _ in }
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    let store: TokenStore
    let lock: SessionLock

    init(store: TokenStore, lock: SessionLock) {
        self.store = store
        self.lock = lock
    }

    var filtered: [Token] {
        search.isEmpty ? store.tokens : Ranker.rank(store.tokens, query: search, usage: store.usage)
    }

    func select(_ id: String) {
        if selection == id { loadSelection() } else { selection = id }
    }

    func newToken(name: String = "") {
        selection = nil
        error = nil
        draft = Draft(token: Token(name: name), isNew: true)
    }

    private func loadSelection() {
        error = nil
        guard let selection, let token = store.token(id: selection) else {
            draft = nil
            return
        }
        draft = Draft(token: token, isNew: false)
    }

    func save() {
        guard let draft else { return }
        do {
            let saved = try store.save(draft.materialized(), value: draft.value)
            flash(draft.isNew ? "Added" : "Saved")
            select(saved.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete() {
        guard let draft, !draft.isNew else { return }
        do {
            try store.delete(id: draft.token.id)
            selection = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copy() {
        if let draft, !draft.isNew { onCopy(draft.token) }
    }

    func toggleReveal() async {
        guard let current = draft, !current.isNew else { return }
        if current.revealed {
            draft?.revealed = false
            return
        }
        guard await lock.authorize(reason: "reveal “\(current.token.name)”") else { return }
        do {
            let secret = try store.secret(for: current.token.id)
            guard draft?.token.id == current.token.id else { return }
            if draft?.value.isEmpty == true { draft?.value = secret }
            draft?.revealed = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func beginImport() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .env file to import"
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
                error = "No KEY=value pairs found in \(url.lastPathComponent)."
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
        var imported = 0
        for entry in session.entries where entry.include {
            let token = Token(name: entry.key, envVar: entry.key, tags: tag.isEmpty ? [] : [tag])
            do {
                try store.save(token, value: entry.value)
                imported += 1
            } catch {
                self.error = "\(entry.key): \(error.localizedDescription)"
            }
        }
        importSession = nil
        flash("Imported \(imported) token\(imported == 1 ? "" : "s")")
    }

    private func flash(_ message: String) {
        status = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }
}

struct ManagerView: View {
    @Bindable var model: ManagerModel

    var body: some View {
        NavigationSplitView {
            List(model.filtered, selection: $model.selection) { token in
                SidebarRow(token: token)
            }
            .searchable(text: $model.search, placement: .sidebar, prompt: "Filter")
            .overlay {
                if model.store.tokens.isEmpty {
                    ContentUnavailableView {
                        Label("No Tokens", systemImage: "key.horizontal")
                    } description: {
                        Text("Add one with ⌘N or import a .env file.")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            if model.draft != nil {
                TokenEditor(model: model)
            } else {
                ContentUnavailableView("Select a Token", systemImage: "key.horizontal")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.beginImport()
                } label: {
                    Label("Import .env", systemImage: "square.and.arrow.down")
                }
                .help("Import from a .env file")
                Button {
                    model.newToken()
                } label: {
                    Label("New Token", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("New token (⌘N)")
            }
        }
        .sheet(isPresented: Binding(
            get: { model.importSession != nil },
            set: { if !$0 { model.importSession = nil } }
        )) {
            ImportSheet(model: model)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct SidebarRow: View {
    let token: Token

    var body: some View {
        HStack(spacing: 10) {
            Monogram(name: token.name, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.name).lineLimit(1)
                Text(token.variableName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            switch token.expiry() {
            case .expired: Circle().fill(.red).frame(width: 7, height: 7).help("Expired")
            case .soon: Circle().fill(.orange).frame(width: 7, height: 7).help("Expires soon")
            case .none, .valid: EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

struct TokenEditor: View {
    @Bindable var model: ManagerModel
    @State private var confirmDelete = false

    var body: some View {
        if let draft = Binding($model.draft) {
            editor(draft)
        }
    }

    private func editor(_ draft: Binding<ManagerModel.Draft>) -> some View {
        let d = draft.wrappedValue
        return Form {
            Section {
                TextField("Name", text: draft.token.name, prompt: Text("GitHub (work)"))
                TextField("Variable", text: draft.token.envVar, prompt: Text(Token.variableName(from: d.token.name)))
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Value") {
                    HStack(spacing: 6) {
                        Group {
                            if d.revealed {
                                TextField("Value", text: draft.value)
                            } else {
                                SecureField("Value", text: draft.value, prompt: Text(d.isNew ? "Paste token" : "Unchanged"))
                            }
                        }
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        if !d.isNew {
                            Button {
                                Task { await model.toggleReveal() }
                            } label: {
                                Image(systemName: d.revealed ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(d.revealed ? "Hide" : "Reveal")
                        }
                    }
                }
            }

            Section {
                TextField("Tags", text: draft.tagsText, prompt: Text("work, github"))
                Toggle("Expires", isOn: draft.hasExpiry)
                if d.hasExpiry {
                    DatePicker("Expiry date", selection: draft.expiry, displayedComponents: .date)
                }
                TextField("Notes", text: draft.token.notes, prompt: Text("Scopes, where it's used…"), axis: .vertical)
                    .lineLimit(2...6)
            }

            if !d.isNew {
                Section {
                    LabeledContent("Created", value: d.token.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Updated", value: d.token.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if let usage = model.store.usage[d.token.id] {
                        LabeledContent("Last copied", value: usage.lastUsed.formatted(.relative(presentation: .named)))
                        LabeledContent("Times copied", value: "\(usage.count)")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(d.isNew ? "New Token" : d.token.name)
        .safeAreaInset(edge: .bottom) { bottomBar(d) }
        .confirmationDialog("Delete “\(d.token.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete() }
        } message: {
            Text("This removes the token from your keychain. It can't be undone.")
        }
    }

    private func bottomBar(_ d: ManagerModel.Draft) -> some View {
        HStack(spacing: 10) {
            if !d.isNew {
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).lineLimit(2)
            } else if let status = model.status {
                Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            if !d.isNew {
                Button("Copy") { model.copy() }
            }
            Button(d.isNew ? "Add Token" : "Save") { model.save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct ImportSheet: View {
    @Bindable var model: ManagerModel

    var body: some View {
        if let session = Binding($model.importSession) {
            let count = session.wrappedValue.entries.filter(\.include).count
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import from \(session.wrappedValue.source)").font(.headline)
                    Text("Selected values are stored in your login keychain. Keys that already exist are unchecked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                List {
                    ForEach(session.entries) { $entry in
                        Toggle(isOn: $entry.include) {
                            HStack {
                                Text(entry.key).font(.system(.body, design: .monospaced))
                                if entry.exists {
                                    Text("exists").font(.caption).foregroundStyle(.orange)
                                }
                                Spacer()
                                Text("\(entry.value.count) chars").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
                TextField("Tag", text: session.tag, prompt: Text("optional"))
                HStack {
                    Spacer()
                    Button("Cancel") { model.importSession = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Import \(count)") { model.commitImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(count == 0)
                }
            }
            .padding(20)
            .frame(width: 500)
        }
    }
}
