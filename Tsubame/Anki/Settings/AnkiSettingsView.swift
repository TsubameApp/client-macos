import SwiftUI

struct AnkiSettingsView: View {
    @Bindable var model: AnkiSettingsModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anki")
                            .font(.headline)
                        Text("Connect to AnkiConnect and map Tsubame values to your note fields.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.enabled)
                        .labelsHidden()
                }

                if model.enabled {
                    Divider()
                    connectionSection

                    if model.isConnected {
                        selectionSection
                        if !model.modelName.isEmpty {
                            mappingSection
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("AnkiConnect URL", text: $model.endpoint)
                    .textFieldStyle(.roundedBorder)
                Button("Connect") {
                    Task { await model.testConnection() }
                }
                .disabled(model.connectionState == .connecting)
            }
            Label(model.connectionMessage, systemImage: connectionSymbol)
                .font(.caption)
                .foregroundStyle(connectionColor)
                .textSelection(.enabled)
        }
    }

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Deck", selection: $model.deckName) {
                    Text("Choose a deck…").tag("")
                    ForEach(model.deckNames, id: \.self) { deck in
                        Text(deck).tag(deck)
                    }
                }
                Picker("Note type", selection: modelSelection) {
                    Text("Choose a note type…").tag("")
                    ForEach(model.modelNames, id: \.self) { noteType in
                        Text(noteType).tag(noteType)
                    }
                }
            }
            TextField("Tags separated by spaces", text: $model.tagsText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Field mapping")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.isLoadingModelFields {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("Use text and supported markers. Unsupported Yomitan markers will be validated when mining is added.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.modelFieldNames, id: \.self) { field in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(field)
                        .font(.callout)
                        .frame(width: 150, alignment: .trailing)
                        .lineLimit(1)
                        .help(field)
                    TextField("Leave empty to omit", text: templateBinding(for: field))
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(AnkiSettingsModel.supportedMarkers, id: \.self) { marker in
                            Button(marker) {
                                let existing = model.fieldTemplates[field, default: ""]
                                model.setFieldTemplate(existing + marker, for: field)
                            }
                        }
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Insert marker")
                }
            }
        }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { model.modelName },
            set: { selected in
                Task { await model.selectModel(selected) }
            }
        )
    }

    private func templateBinding(for field: String) -> Binding<String> {
        Binding(
            get: { model.fieldTemplates[field, default: ""] },
            set: { model.setFieldTemplate($0, for: field) }
        )
    }

    private var connectionSymbol: String {
        switch model.connectionState {
        case .notTested: "circle.dashed"
        case .connecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .notTested, .connecting: .secondary
        case .connected: .green
        case .failed: .red
        }
    }
}
