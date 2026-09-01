import SwiftUI
import UIKit

struct SettingsHubView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ExportCoordinator
    let returnHome: () -> Void

    var body: some View {
        List {
            Section("Transfer") {
                NavigationLink {
                    TransferOptionsView(model: model)
                } label: {
                    SettingsRow(
                        systemImage: "slider.horizontal.3",
                        title: "Transfer Options",
                        detail: "Portable Master Library"
                    )
                }

                NavigationLink {
                    AdvancedExportView(
                        model: model,
                        coordinator: coordinator,
                        returnHome: returnHome
                    )
                } label: {
                    SettingsRow(
                        systemImage: "ellipsis.circle",
                        title: "Advanced Export",
                        detail: "All, new or changed, or a date range"
                    )
                }

                NavigationLink {
                    ManualPairingView(model: model, dismissAfterConnect: false)
                } label: {
                    SettingsRow(
                        systemImage: "link",
                        title: "Connection Help",
                        detail: coordinator.isConnected
                            ? "Connected to \(coordinator.destination?.displayName ?? "Windows")"
                            : "Enter a pairing URL manually"
                    )
                }
            }

            Section("Photos") {
                NavigationLink {
                    PhotoAccessSettingsView(model: model)
                } label: {
                    SettingsRow(
                        systemImage: "photo.on.rectangle.angled",
                        title: "Photo Access",
                        detail: photoAccessDetail
                    )
                }
            }

            Section("Activity & Support") {
                NavigationLink {
                    HistoryView(model: model, onResume: returnHome)
                } label: {
                    SettingsRow(
                        systemImage: "clock.arrow.circlepath",
                        title: "Transfer History",
                        detail: model.history.isEmpty
                            ? "No transfers yet"
                            : "\(model.history.count) saved transfer\(model.history.count == 1 ? "" : "s")"
                    )
                }

                NavigationLink {
                    DiagnosticsView(store: model.diagnostics)
                } label: {
                    SettingsRow(
                        systemImage: "stethoscope",
                        title: "Diagnostics",
                        detail: "View and share local logs"
                    )
                }
            }
        }
        .navigationTitle("Settings")
        .task { await model.refreshHistory() }
    }

    private var photoAccessDetail: String {
        switch model.authorization {
        case .notDetermined: "Not selected"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .limited: "Limited to \(model.assets.count) items"
        case .authorized: "\(model.assets.count) accessible items"
        }
    }
}

private struct SettingsRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct TransferOptionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Portable Library") {
                LabeledContent("Format", value: ExportProfileKind.portableLibrary.label)
                Text("Master contains one exact, current full-quality photo or video per item. A Live Photo contributes only its current still to Master.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Reversible Archive") {
                Text("MB Photos Data keeps untouched originals, Live Photo motion, edit resources, metadata, and small browsing thumbnails. Exact PhotoKit resources are never transcoded or stripped of metadata.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Copy Master by itself for a simple media folder. Copy the whole library root to keep original and Live Photo export options available in the Windows app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Transfer Options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ManualPairingView: View {
    @ObservedObject var model: AppModel
    let dismissAfterConnect: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pairingText = ""
    @State private var isConnecting = false

    var body: some View {
        Form {
            Section("Pairing URL") {
                TextField("mbphotos://pair?…", text: $pairingText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                Button {
                    connect()
                } label: {
                    if isConnecting {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
            }

            Section("How to Find It") {
                Text("Open MB Photos Receiver on the Windows PC and choose a backup folder. The pairing URL appears with the one-time QR code.")
                Text("Both devices must be on the same private local network. Pairing data is used only for this in-memory connection.")
                    .foregroundStyle(.secondary)
            }

            if let destination = model.coordinator?.destination,
               model.coordinator?.isConnected == true {
                Section {
                    Label("Connected to \(destination.displayName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Connection Help")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if dismissAfterConnect {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func connect() {
        isConnecting = true
        Task {
            await model.connect(pairingText: pairingText)
            isConnecting = false
            if dismissAfterConnect, model.coordinator?.isConnected == true {
                dismiss()
            }
        }
    }
}

private struct PhotoAccessSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Current Access") {
                switch model.authorization {
                case .notDetermined:
                    Label("Photo access has not been chosen.", systemImage: "photo.on.rectangle.angled")
                    Button("Choose Photo Access") {
                        Task { await model.authorizeAndLoad() }
                    }
                case .denied, .restricted:
                    Label("Photo access is required for transfers.", systemImage: "photo.badge.exclamationmark")
                    Button("Open System Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                case .limited:
                    Label("\(model.assets.count) shared items", systemImage: "photo.badge.checkmark")
                    Button("Choose More Photos") { model.presentLimitedPicker() }
                case .authorized:
                    Label("\(model.assets.count) accessible items", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Text("MB Photos reads only the Photos items you allow. Transfers go directly to the paired Windows receiver on your local network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Photo Access")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdvancedExportView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ExportCoordinator
    let returnHome: () -> Void
    @State private var selectionKind: SelectionKind = .newOrChanged
    @State private var showingReview = false

    var body: some View {
        Form {
            Section("Windows PC") {
                ReceiverConnectionControl(model: model, coordinator: coordinator)
            }

            Section("What to Export") {
                Picker("Source", selection: $selectionKind) {
                    Text("All Accessible").tag(SelectionKind.allAccessible)
                    Text("New or Changed").tag(SelectionKind.newOrChanged)
                    Text("Date Range").tag(SelectionKind.dateRange)
                }

                if selectionKind == .dateRange {
                    DatePicker("From", selection: $model.rangeStart, displayedComponents: .date)
                    DatePicker("Through", selection: $model.rangeEnd, displayedComponents: .date)
                } else if selectionKind == .newOrChanged {
                    Text("The selected Windows folder’s verified ledger decides which files can be skipped or resumed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Includes every photo and video currently visible to MB Photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    prepareReview()
                } label: {
                    if model.isPlanning {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Review Transfer").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.assets.isEmpty || !coordinator.isConnected
                        || coordinator.isRunning || model.isPlanning
                )
            }
        }
        .navigationTitle("Advanced Export")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReview) {
            TransferReviewView(
                model: model,
                coordinator: coordinator,
                onStart: returnHome
            )
        }
    }

    private func prepareReview() {
        model.selectionKind = selectionKind
        Task {
            await model.buildPreflight()
            if model.plannedExport != nil { showingReview = true }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    let onResume: () -> Void

    var body: some View {
        List {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No transfers yet",
                    systemImage: "externaldrive",
                    description: Text("Verified and paused transfers will appear here.")
                )
            } else {
                ForEach(model.history) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.destinationName ?? "Windows backup").font(.headline)
                            Spacer()
                            Text(entry.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                        Text("\(entry.verifiedFileCount) verified · \(entry.skippedFileCount) skipped · \(entry.failedFileCount) failed")
                            .font(.footnote)
                        if let report = entry.completionReport {
                            NavigationLink("View Completion Report") {
                                CompletionReportView(report: report)
                            }
                        }
                        if entry.status == .paused {
                            Button("Resume This Transfer") {
                                Task {
                                    if await model.loadResume(jobID: entry.id) {
                                        onResume()
                                    }
                                }
                            }
                        } else if entry.status == .completedWithFailures {
                            Text("Resolve unavailable sources, then use New or Changed to try them again.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Transfer History")
        .refreshable { await model.refreshHistory() }
        .task { await model.refreshHistory() }
    }
}

private struct CompletionReportView: View {
    let report: CompletionReport
    @State private var json: String?
    @State private var isFormatting = false

    var body: some View {
        ScrollView {
            if let json {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                ProgressView("Formatting completion report…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .navigationTitle("Completion Report")
        .toolbar {
            if let json {
                ShareLink(item: json) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if isFormatting, json != nil {
                ProgressView().padding()
            }
        }
        .task(id: CompletionReportRenderID(report: report)) {
            isFormatting = true
            let rendered = await CompletionReportTextRenderer.render(report)
            guard !Task.isCancelled else { return }
            json = rendered
            isFormatting = false
        }
    }
}

private struct CompletionReportRenderID: Hashable {
    let jobID: UUID
    let completedAt: Date
    let failureCount: Int

    init(report: CompletionReport) {
        jobID = report.jobId
        completedAt = report.completedAt
        failureCount = report.failures.count
    }
}

private enum CompletionReportTextRenderer {
    static func render(_ report: CompletionReport) async -> String {
        let work = Task.detached(priority: .utility) { () -> String in
            guard !Task.isCancelled else { return "" }
            let encoder = WireCoders.encoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(report), !Task.isCancelled else {
                return "The stored completion report could not be displayed."
            }
            return String(decoding: data, as: UTF8.self)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
