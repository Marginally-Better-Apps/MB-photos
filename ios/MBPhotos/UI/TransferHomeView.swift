import AVFoundation
import SwiftUI
import UIKit
import VisionKit

struct TransferHomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ExportCoordinator
    @ObservedObject private var organizeModel: OrganizeViewModel
    @State private var showingSelection = false
    @State private var showingReview = false
    @State private var confirmingDiscard = false

    init(model: AppModel, coordinator: ExportCoordinator) {
        self.model = model
        self.coordinator = coordinator
        self._organizeModel = ObservedObject(wrappedValue: model.organizeViewModel)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                connectionStep
                selectionStep
                transferStep
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("MB Photos")
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(isPresented: $showingSelection) {
            TransferSelectionView(model: model)
        }
        .sheet(isPresented: $showingReview) {
            TransferReviewView(model: model, coordinator: coordinator)
        }
        .confirmationDialog(
            "Discard this partial transfer?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Partial Transfer", role: .destructive) {
                Task { await coordinator.discardCurrentJob() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files already verified on the PC will not be removed.")
        }
    }

    private var connectionStep: some View {
        TransferSurface {
            TransferStepHeader(number: 1, title: "Windows PC")
            ReceiverConnectionControl(model: model, coordinator: coordinator)
        }
    }

    private var selectionStep: some View {
        TransferSurface {
            TransferStepHeader(number: 2, title: "Photos & Albums")

            switch model.authorization {
            case .notDetermined:
                ProgressView("Requesting photo access…")
            case .denied, .restricted:
                Label("Photo access is required to choose items.", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.bordered)
            case .limited, .authorized:
                if !model.selectionPreviewAssets.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(model.selectionPreviewAssets) { asset in
                            SelectionPreviewThumbnail(catalog: model.catalog, asset: asset)
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectionSummary)
                            .font(hasQuickSelection ? .headline : .body)
                            .foregroundStyle(hasQuickSelection ? .primary : .secondary)
                        if hasQuickSelection {
                            Text(selectionSizeText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.isLoadingLibrary { ProgressView() }
                }

                Button {
                    model.selectionKind = .manual
                    showingSelection = true
                } label: {
                    Text(hasQuickSelection ? "Change Selection" : "Choose Photos & Albums")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isRunning || model.assets.isEmpty)

                if model.authorization == .limited {
                    Button("Choose More Photos") { model.presentLimitedPicker() }
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var transferStep: some View {
        TransferSurface {
            TransferStepHeader(number: 3, title: "Transfer")

            switch coordinator.progress.phase {
            case .idle:
                if model.isPlanning {
                    ProgressView("Preparing transfer review…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(reviewSupportingText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        reviewTransfer()
                    } label: {
                        Label(reviewButtonTitle, systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReview)
                }
            case .completed, .completedWithFailures:
                completionContent
            default:
                progressContent
            }
        }
    }

    @ViewBuilder
    private var progressContent: some View {
        Label(coordinator.progress.phase.rawValue, systemImage: phaseIcon)
            .font(.headline)
            .foregroundStyle(phaseTint)

        ProgressView(value: coordinator.progress.overallFraction)

        if !coordinator.progress.currentFilename.isEmpty {
            Text(coordinator.progress.currentFilename)
                .font(.subheadline)
                .lineLimit(1)
            Text("File \(coordinator.progress.currentFileIndex) of \(coordinator.progress.totalFileCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }

        TransferMetrics(progress: coordinator.progress)

        if let message = coordinator.progress.lastMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if coordinator.isRunning {
            Button("Pause Transfer") { coordinator.pause() }
                .buttonStyle(.bordered)
        } else if coordinator.progress.phase == .paused || coordinator.progress.phase == .failed {
            Button("Retry or Resume") { coordinator.retry() }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.isConnected)
            Button("Discard Partial Transfer", role: .destructive) {
                confirmingDiscard = true
            }
        }
    }

    @ViewBuilder
    private var completionContent: some View {
        let succeeded = coordinator.progress.phase == .completed
        Label(
            succeeded ? "Transfer complete" : "Transfer completed with issues",
            systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.headline)
        .foregroundStyle(succeeded ? .green : .orange)

        TransferMetrics(progress: coordinator.progress)

        if let message = coordinator.progress.lastMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let report = coordinator.completionReport {
            Text("Report saved to \(report.reportRelativePath)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button(succeeded ? "Choose Another Transfer" : "Done") {
            coordinator.dismissCompletion()
        }
        .buttonStyle(.borderedProminent)
    }

    private var hasQuickSelection: Bool {
        !model.selectedAssetIDs.isEmpty || !model.selectedAlbumIDs.isEmpty
    }

    private var selectionSummary: String {
        guard hasQuickSelection else { return "Nothing selected yet" }
        let photoCount = model.selectedAssetIDs.count
        let albumCount = model.selectedAlbumIDs.count
        let photos = "\(photoCount) photo\(photoCount == 1 ? "" : "s")"
        let albums = "\(albumCount) album\(albumCount == 1 ? "" : "s")"
        if photoCount == 0 { return albums }
        if albumCount == 0 { return photos }
        return "\(photos) · \(albums)"
    }

    private var selectionSizeText: String {
        TransferSelectionSizePresentation.text(
            for: selectionSize,
            byteCountFormatter: ByteCountFormatter.string
        )
    }

    private var selectionSize: TransferSelectionSize {
        TransferSelectionSize.calculate(
            selectedAssetIDs: model.selectedAssetIDs,
            selectedAlbumIDs: model.selectedAlbumIDs,
            albums: model.albums,
            knownByteCount: { organizeModel.asset(id: $0)?.knownBytes }
        )
    }

    private var canReview: Bool {
        coordinator.isConnected
            && !coordinator.isRunning
            && !model.isPlanning
            && (hasQuickSelection || model.plannedExport != nil)
    }

    private var reviewButtonTitle: String {
        model.plannedExport == nil ? "Review Transfer" : "Review Prepared Transfer"
    }

    private var reviewSupportingText: String {
        if !coordinator.isConnected { return "Connect to the Windows receiver first." }
        if !hasQuickSelection && model.plannedExport == nil { return "Choose photos or albums to continue." }
        return "Check the item count, destination, and any warnings before transfer."
    }

    private var phaseIcon: String {
        switch coordinator.progress.phase {
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var phaseTint: Color {
        switch coordinator.progress.phase {
        case .failed: .red
        case .paused: .orange
        default: .blue
        }
    }

    private func reviewTransfer() {
        if model.plannedExport != nil {
            showingReview = true
            return
        }
        model.selectionKind = .manual
        Task {
            await model.buildPreflight()
            if model.plannedExport != nil { showingReview = true }
        }
    }
}

struct TransferStepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            Text(title).font(.headline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title)")
    }
}

struct ReceiverConnectionControl: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ExportCoordinator
    @State private var showingScanner = false
    @State private var showingManualPairing = false
    @State private var requestingCamera = false
    @State private var scannerUnavailable = false

    var body: some View {
        Group {
            if let destination = coordinator.destination, coordinator.isConnected {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(destination.displayName).font(.headline)
                        Text("\(formattedFreeSpace(destination.freeBytes)) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") { requestCameraAndScan() }
                        .disabled(requestingCamera || coordinator.isRunning)
                }
            } else {
                Text("Open MB Photos Receiver on the PC, choose a backup folder, then scan its one-time code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    requestCameraAndScan()
                } label: {
                    Label(
                        requestingCamera ? "Opening Camera…" : "Scan Windows QR Code",
                        systemImage: "qrcode.viewfinder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(requestingCamera || coordinator.isRunning)
            }

            if scannerUnavailable {
                Button("Enter Pairing URL Manually") { showingManualPairing = true }
                    .font(.subheadline)
            }
        }
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                QRScannerView { value in
                    showingScanner = false
                    Task { await model.connect(pairingText: value) }
                } onError: { message in
                    showingScanner = false
                    scannerUnavailable = true
                    model.alertMessage = message
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Receiver")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingScanner = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showingManualPairing) {
            NavigationStack {
                ManualPairingView(model: model, dismissAfterConnect: true)
            }
        }
    }

    private func formattedFreeSpace(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func requestCameraAndScan() {
        guard DataScannerViewController.isSupported else {
            scannerUnavailable = true
            model.alertMessage = "QR scanning is unavailable on this device. Enter the pairing URL manually."
            return
        }
        requestingCamera = true
        Task {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                allowed = true
            case .notDetermined:
                allowed = await AVCaptureDevice.requestAccess(for: .video)
            default:
                allowed = false
            }
            requestingCamera = false
            if allowed {
                showingScanner = true
            } else {
                scannerUnavailable = true
                model.alertMessage = "Camera access is required to scan. Enter the pairing URL manually or allow camera access in Settings."
            }
        }
    }
}

struct TransferMetrics: View {
    let progress: ExportProgressState

    var body: some View {
        HStack(spacing: 8) {
            metric("Verified", progress.verifiedFileCount)
            metric("Skipped", progress.skippedFileCount)
            metric("Failed", progress.failedFileCount)
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TransferReviewView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ExportCoordinator
    var onStart: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let plan = model.plannedExport {
                    Form {
                        Section("Destination") {
                            LabeledContent("Windows PC", value: coordinator.destination?.displayName ?? "Not connected")
                            if let freeBytes = plan.preflight.destinationFreeBytes {
                                LabeledContent(
                                    "Available space",
                                    value: ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
                                )
                            }
                        }

                        Section("Transfer") {
                            LabeledContent("Photos and videos", value: "\(plan.preflight.assetCount)")
                            LabeledContent("Master files", value: "\(plan.preflight.masterFileCount)")
                            LabeledContent("Archive resources", value: "\(plan.preflight.archiveFileCount)")
                            LabeledContent("Browsing thumbnails", value: "\(plan.preflight.thumbnailFileCount)")
                            if plan.preflight.missingMasterCount > 0 {
                                LabeledContent("Missing current resource", value: "\(plan.preflight.missingMasterCount)")
                            }
                            if plan.preflight.estimatedKnownBytes > 0 {
                                LabeledContent(
                                    "Known source size",
                                    value: ByteCountFormatter.string(
                                        fromByteCount: plan.preflight.estimatedKnownBytes,
                                        countStyle: .file
                                    )
                                )
                            }
                            if plan.preflight.unknownByteCount > 0 {
                                LabeledContent("Size still loading", value: "\(plan.preflight.unknownByteCount) files")
                            }
                            LabeledContent("Already verified", value: "\(plan.preflight.unchangedFileCount)")
                            if plan.preflight.resumableFileCount > 0 {
                                LabeledContent("Ready to resume", value: "\(plan.preflight.resumableFileCount)")
                            }
                        }

                        Section("Format") {
                            LabeledContent("Copies", value: plan.job.profile.kind.label)
                            LabeledContent("Master quality", value: "Exact PhotoKit bytes")
                            LabeledContent("Embedded metadata", value: "Preserved")
                        }

                        if !plan.preflight.warnings.isEmpty {
                            Section("Before You Start") {
                                ForEach(plan.preflight.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "info.circle")
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Review unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Return to Home and prepare the transfer again.")
                    )
                }
            }
            .navigationTitle("Review Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.plannedExport != nil {
                    Button {
                        model.startExport()
                        guard coordinator.isRunning else { return }
                        dismiss()
                        onStart?()
                    } label: {
                        Text("Start Transfer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.isConnected || coordinator.isRunning || model.isPlanning)
                    .padding()
                    .background(.bar)
                }
            }
        }
    }
}

private struct SelectionPreviewThumbnail: View {
    let catalog: PhotoKitCatalog
    let asset: PhotoAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary).overlay { ProgressView() }
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: asset.sourceRevision) {
            image = await catalog.thumbnail(
                assetID: asset.id,
                size: CGSize(width: 62, height: 62),
                scale: UIScreen.main.scale
            )
        }
        .accessibilityLabel(asset.mediaKind == .video ? "Selected video" : "Selected photo")
    }
}
