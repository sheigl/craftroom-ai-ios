import SwiftUI
import CraftRoomCore

/// Settings (plan T4.7): engine picker, server URL, Test connection with the
/// health the service reports, and the current engine's state. Persisted; the
/// Developer row at the bottom folds the payload/ladder/diagnostics away.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var urlProblem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: engineBinding) {
                        ForEach(EngineID.allCases, id: \.self) { id in
                            Text(id.label).tag(id)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Backend")
                } footer: {
                    Text(model.settings.engine.detail)
                }

                if model.settings.engine == .localServer {
                    serverSection
                } else {
                    onDeviceSection
                }

                Section {
                    NavigationLink {
                        DeveloperView()
                    } label: {
                        Label("Developer", systemImage: "hammer")
                    }
                }

                Section {
                    Text(model.versionLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                urlText = model.settings.baseURL.absoluteString
                model.refreshPayload()
            }
            .task {
                // Show the current state immediately; the button re-checks on
                // demand (and after a URL change).
                if model.health == nil { await model.testConnection() }
            }
        }
        .tint(Theme.accent)
    }

    private var engineBinding: Binding<EngineID> {
        Binding(get: { model.settings.engine },
                set: { model.setEngine($0) })
    }

    // MARK: local server

    private var serverSection: some View {
        Section {
            TextField("http://192.168.68.92:8124", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { saveURL() }

            HStack {
                Button("Save address") { saveURL() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    Task { await model.testConnection() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Test connection")
                        if model.testingConnection {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.testingConnection)
            }

            if let urlProblem {
                Text(urlProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let health = model.health {
                healthRows(health)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("desktop2 runs the generation server (sdxl/api, port 8124). "
                 + "This engine needs no model download.")
        }
    }

    // MARK: on-device

    private var onDeviceSection: some View {
        Section {
            HStack {
                Text(payloadSummary)
                Spacer()
                if isPayloadReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if let health = model.health {
                healthRows(health)
            }
        } header: {
            Text("On this iPad")
        } footer: {
            Text("The Core ML models are a one-time download and then run offline. "
                 + "Download or manage them under Developer below; "
                 + "Local server needs none of it.")
        }
    }

    private var isPayloadReady: Bool {
        if case .ready = model.payloadState { return true }
        return false
    }

    private var payloadSummary: String {
        switch model.payloadState {
        case .ready:
            return "Models installed"
        case .missing(let totalMB):
            return "Models not downloaded — \(totalMB / 1024) GB"
        case .downloading(let fraction, _, _):
            return String(format: "Downloading %.0f %%", fraction * 100)
        case .failed:
            return "Download failed"
        case .checking:
            return "Checking models…"
        }
    }

    // MARK: health rows

    @ViewBuilder
    private func healthRows(_ health: EngineHealth) -> some View {
        HStack(spacing: 8) {
            Image(systemName: health.ok ? "checkmark.circle.fill"
                                        : "xmark.circle.fill")
                .foregroundStyle(health.ok ? Color.green : Color.red)
            Text(health.summary)
                .font(.callout)
        }
        if let comfy = health.comfyVersion {
            LabeledContent("ComfyUI", value: comfy)
        }
        if let modelID = health.modelID {
            LabeledContent("Model", value: modelID)
        }
        if let sha = health.modelSHAShort {
            LabeledContent("Student sha256", value: sha)
        }
        if let queue = health.queue {
            LabeledContent("Queue", value: queue)
        }
        if let free = health.vramFreeMB, let total = health.vramTotalMB, total > 0 {
            LabeledContent("VRAM free",
                           value: String(format: "%.1f / %.0f GB",
                                         free / 1024, total / 1024))
        }
        if let detail = health.detail, !health.ok {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if let checked = health.checkedAt {
            Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: URL

    private func saveURL() {
        if let problem = model.applyBaseURL(urlText) {
            urlProblem = problem
            return
        }
        urlProblem = nil
        urlText = model.settings.baseURL.absoluteString
        Task { await model.testConnection() }
    }
}
