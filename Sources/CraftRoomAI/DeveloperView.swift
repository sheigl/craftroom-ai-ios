import SwiftUI
import UIKit
import CraftRoomCore

/// The folded-away developer section (plan T4.11): payload status + download,
/// the manual T5 ladder, the telemetry toggle, the log, and the seed.
///
/// Nothing here runs on its own. In particular the bundled `auto_default.json`
/// ladder starts only from the "Run ladder" button below — the owner will be
/// testing the product UI, not the ladder.
struct DeveloperView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ladder: LadderController

    @State private var seedText = ""
    @State private var seedProblem: String?
    @State private var showLog = false

    var body: some View {
        Form {
            payloadSection
            ladderSection
            diagnosticsSection
            seedSection
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            seedText = model.seedText
            model.refreshPayload()
            ladder.refreshLog()
        }
        .sheet(isPresented: $showLog) {
            LogView()
        }
    }

    // MARK: payload

    private var payloadSection: some View {
        Section {
            HStack {
                Text(payloadSummary)
                Spacer()
                if model.isDownloadingPayload {
                    ProgressView().controlSize(.small)
                }
            }
            if case .downloading(let fraction, let doneMB, let totalMB) = model.payloadState {
                ProgressView(value: fraction)
                Text("\(doneMB) / \(totalMB) MB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = model.payloadState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Picker("Attention variant", selection: variantBinding) {
                ForEach(AttentionVariant.allCases) { variant in
                    Text(variant.label).tag(variant)
                }
            }
            .disabled(model.isDownloadingPayload)
            if model.isDownloadingPayload {
                Button("Cancel download", role: .destructive) {
                    model.cancelModelDownload()
                }
            } else {
                Button("Download / repair models") {
                    model.downloadModels()
                }
                .disabled(isPayloadReady)
            }
        } header: {
            Text("On-device payload")
        } footer: {
            Text("Only the On-device engine uses these models. "
                 + "Base: \(PayloadStore.shared.baseURL)")
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

    private var variantBinding: Binding<AttentionVariant> {
        Binding(
            get: { AttentionVariant(rawValue: PayloadStore.shared.variant) ?? .sdpa },
            set: { newValue in
                PayloadStore.shared.variant = newValue.rawValue
                model.refreshPayload()
            })
    }

    // MARK: ladder

    private var ladderSection: some View {
        Section {
            Toggle("Load even if the preflight says impossible",
                   isOn: $ladder.forceLoad)
            Button {
                ladder.start()
            } label: {
                HStack {
                    Text(ladder.isRunning ? "Ladder running…" : "Run ladder")
                    if ladder.isRunning {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(ladder.isRunning)
            Text(ladder.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !ladder.lastLine.isEmpty {
                Text(ladder.lastLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Button("Show ladder log") { showLog = true }
        } header: {
            Text("T5 ladder (manual)")
        } footer: {
            Text("The bundled matrix runs only when you tap Run ladder. "
                 + "Nothing starts it on launch; the product flow does not use it.")
        }
    }

    // MARK: diagnostics

    private var diagnosticsSection: some View {
        Section {
            Toggle("Send log lines to desktop2", isOn: telemetryBinding)
            Button("Show log") { showLog = true }
            Text(model.versionLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Telemetry posts ladder and payload lines to "
                 + "\(Telemetry.endpoint). Off sends nothing.")
        }
    }

    private var telemetryBinding: Binding<Bool> {
        Binding(get: { Telemetry.enabled },
                set: { Telemetry.enabled = $0 })
    }

    // MARK: seed

    private var seedSection: some View {
        Section {
            HStack {
                Text("Seed")
                Spacer()
                TextField("default", text: $seedText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 140)
            }
            HStack {
                Button("Save seed") { saveSeed() }
                Spacer()
                Button("Clear") {
                    seedText = ""
                    seedProblem = nil
                    model.setSeed(nil)
                }
            }
            if let seedProblem {
                Text(seedProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Used by both engines. Empty uses the server's frozen default "
                 + "(42) on desktop2 and 42 on-device; Regenerate always picks a "
                 + "fresh seed.")
        }
    }

    private func saveSeed() {
        let text = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            seedProblem = nil
            model.setSeed(nil)
            return
        }
        guard let value = UInt64(text) else {
            seedProblem = "The seed must be a positive whole number."
            return
        }
        seedProblem = nil
        model.setSeed(value)
    }
}

/// The crash-surviving log, reachable from Developer (the iPad has no console).
struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "(no log yet)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reload") { text = Diagnostics.tail(250) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button("Copy") { UIPasteboard.general.string = text }
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear { text = Diagnostics.tail(250) }
        }
    }
}
