import PounceCore
import SwiftUI

struct SnippetListView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Snippet?

    var body: some View {
        List {
            ForEach(app.snippets) { snippet in
                Button {
                    editing = snippet
                } label: {
                    SnippetRow(snippet: snippet)
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in
                for index in offsets { app.delete(app.snippets[index]) }
            }
            .onMove { app.moveSnippets(from: $0, to: $1) }
        }
        .overlay {
            if app.snippets.isEmpty {
                ContentUnavailableView {
                    Label("No Snippets", systemImage: "text.alignleft")
                } description: {
                    Text(
                        "Save commands you type often and send them to a session with one tap. Use {{name}} for parts that change."
                    )
                } actions: {
                    Button("Add Snippet") { editing = Snippet(name: "", command: "") }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle("Snippets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { editing = Snippet(name: "", command: "") }
            }
            if !app.snippets.isEmpty {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
        .sheet(item: $editing) { SnippetEditor(snippet: $0) }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snippet.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if !snippet.name.isEmpty {
                Text(snippet.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct SnippetEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var snippet: Snippet
    private let saved: (Snippet) -> Void

    init(snippet: Snippet, saved: @escaping (Snippet) -> Void = { _ in }) {
        _snippet = State(initialValue: snippet)
        self.saved = saved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $snippet.name, prompt: Text("Optional"))
                }
                Section {
                    CodeEditor(text: $snippet.command, font: .system(.body, design: .monospaced), minHeight: 100)
                } header: {
                    Text("Command")
                } footer: {
                    let placeholders = snippet.placeholders
                    Text(
                        placeholders.isEmpty
                            ? "Write {{name}} where a value should be asked for when it runs."
                            : "Asks for: \(placeholders.joined(separator: ", "))")
                }
                Section {
                    Toggle("Press Return", isOn: $snippet.runImmediately)
                } footer: {
                    Text("Off types the command and leaves it for you to edit.")
                }
            }
            .editorToolbar(
                snippet.name.isEmpty ? "Snippet" : snippet.name,
                disabled: snippet.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                app.save(snippet)
                saved(snippet)
                dismiss()
            }
        }
    }
}

struct SnippetPicker: View {
    let session: Session
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var filling: Snippet?
    @State private var values: [String: String] = [:]
    @State private var sent = 0

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.snippets) { snippet in
                    Button {
                        if snippet.placeholders.isEmpty {
                            run(snippet)
                        } else {
                            values = [:]
                            filling = snippet
                        }
                    } label: {
                        SnippetRow(snippet: snippet)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .overlay {
                if app.snippets.isEmpty {
                    ContentUnavailableView(
                        "No Snippets", systemImage: "text.alignleft",
                        description: Text("Add snippets in the Snippets tab."))
                }
            }
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .dismissToolbar("Close", cancel: true)
            .navigationDestination(item: $filling) { snippet in
                SnippetFillForm(snippet: snippet, values: $values) { run(snippet) }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.success, trigger: sent)
    }

    private func run(_ snippet: Snippet) {
        session.run(snippet, values: values)
        sent += 1
        dismiss()
    }
}

private struct SnippetFillForm: View {
    let snippet: Snippet
    @Binding var values: [String: String]
    let send: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(snippet.placeholders, id: \.self) { name in
                    TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text(snippet.filled(values)).font(.system(.footnote, design: .monospaced))
            }
        }
        .navigationTitle(snippet.name.isEmpty ? "Fill In" : snippet.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Send", systemImage: "paperplane", action: send)
            }
        }
    }
}

struct StartupSnippetSheet: View {
    let session: Session
    let snippet: Snippet
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            SnippetFillForm(snippet: snippet, values: $values) {
                session.run(snippet, values: values)
                dismiss()
            }
            .dismissToolbar("Skip", cancel: true)
        }
        .presentationDetents([.medium, .large])
    }
}

extension Snippet {
    var title: String { name.isEmpty ? command : name }
}
