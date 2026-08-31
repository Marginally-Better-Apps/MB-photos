import AVFoundation
import SwiftUI
import VisionKit

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.startupState {
            case .loading:
                ProgressView("Preparing your photo library…")
            case let .failed(startupError):
                NavigationStack {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Photo library unavailable",
                            systemImage: "externaldrive.badge.exclamationmark",
                            description: Text(startupError)
                        )
                        NavigationLink {
                            DiagnosticsView(store: model.diagnostics)
                        } label: {
                            Label("Open Diagnostics", systemImage: "stethoscope")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .ready:
                if let coordinator = model.coordinator {
                    MainTabs(model: model, coordinator: coordinator)
                } else {
                    ContentUnavailableView("App unavailable", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .alert(
            "MB Photos",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

private struct MainTabs: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ExportCoordinator
    @ObservedObject var organizeModel: OrganizeViewModel

    init(model: AppModel, coordinator: ExportCoordinator) {
        _model = ObservedObject(wrappedValue: model)
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _organizeModel = ObservedObject(wrappedValue: model.organizeViewModel)
    }

    var body: some View {
        TabView {
            NavigationStack {
                OrganizeView(model: organizeModel)
            }
            .tabItem { Label("Organize", systemImage: "rectangle.3.group") }

            NavigationStack {
                ExportView(model: model, coordinator: coordinator)
            }
            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }

            NavigationStack {
                HistoryView(model: model)
            }
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            NavigationStack {
                DiagnosticsView(store: model.diagnostics)
            }
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .task {
            await model.refreshLibrary()
            await model.refreshHistory()
        }
        .onChange(of: model.catalog.catalogRevision) { _, _ in
            Task { await model.refreshLibrary() }
        }
        .onChange(of: coordinator.progress.phase) { _, phase in
            if phase == .completed || phase == .completedWithFailures || phase == .failed || phase == .paused {
                Task { await model.refreshHistory() }
            }
        }
    }

}

private struct ExportView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ExportCoordinator
    @State private var showingScanner = false
    @State private var pairingText = ""
    @State private var showingManualPairing = false
    @State private var requestingCamera = false

    var body: some View {
        Form {
            permissionSection
            if model.authorization == .authorized || model.authorization == .limited {
                receiverSection
                selectionSection
                profileSection
                preflightSection
                progressSection
            }
        }
        .navigationTitle("Export to Windows")
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                QRScannerView { value in
                    showingScanner = false
                    Task { await model.connect(pairingText: value) }
                } onError: { message in
                    showingScanner = false
                    model.alertMessage = message
                }
                .ignoresSafeArea()
                .navigationTitle("Scan receiver")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingScanner = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        Section("Photo Library") {
            switch model.authorization {
            case .notDetermined:
                Text("Choose which photos to back up or review. Organize decisions are staged first; only items you confirm in the final queue move to Apple Photos’ Recently Deleted collection.")
                Button("Allow photo access") {
                    Task { await model.authorizeAndLoad() }
                }
            case .denied, .restricted:
                Label("Photo access is required to export.", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            case .limited:
                Label("Limited access: \(model.assets.count) visible item(s)", systemImage: "photo.on.rectangle.angled")
                Button("Choose more photos") { model.presentLimitedPicker() }
            case .authorized:
                HStack {
                    Label("\(model.assets.count) accessible item(s)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if model.isLoadingLibrary { ProgressView() }
                }
            }
        }
    }

    private var receiverSection: some View {
        Section("Windows receiver") {
            if let destination = coordinator.destination, coordinator.isConnected {
                LabeledContent("Connected", value: destination.displayName)
                LabeledContent("Free space", value: ByteCountFormatter.string(fromByteCount: destination.freeBytes, countStyle: .file))
            } else {
                Text("Open the small receiver app on the PC, choose the backup folder, then scan its one-time code.")
                    .foregroundStyle(.secondary)
            }
            Button {
                requestCameraAndScan()
            } label: {
                Label(requestingCamera ? "Opening camera…" : "Scan receiver QR code", systemImage: "qrcode.viewfinder")
            }
            .disabled(requestingCamera || coordinator.isRunning)

            DisclosureGroup("Enter pairing URL", isExpanded: $showingManualPairing) {
                TextField("mbphotos://pair?…", text: $pairingText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                Button("Connect") {
                    Task { await model.connect(pairingText: pairingText) }
                }
                .disabled(pairingText.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var selectionSection: some View {
        Section("What to export") {
            Picker("Source", selection: $model.selectionKind) {
                ForEach(SelectionKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }

            switch model.selectionKind {
            case .dateRange:
                DatePicker("From", selection: $model.rangeStart, displayedComponents: .date)
                DatePicker("Through", selection: $model.rangeEnd, displayedComponents: .date)
            case .albums:
                if model.albums.isEmpty {
                    Text("No user albums are visible.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.albums) { album in
                                Button {
                                    model.toggleSelectedAlbumID(album.id)
                                } label: {
                                    HStack {
                                        Image(systemName: model.selectedAlbumIDs.contains(album.id) ? "checkmark.circle.fill" : "circle")
                                        Text(album.title)
                                        Spacer()
                                        Text("\(album.assetIDs.count)").foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            case .manual:
                Text("\(model.selectedAssetIDs.count) selected")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 3)], spacing: 3) {
                    ForEach(model.assets) { asset in
                        PhotoThumbnailButton(
                            catalog: model.catalog,
                            asset: asset,
                            isSelected: model.selectedAssetIDs.contains(asset.id)
                        ) {
                            model.toggleSelectedAssetID(asset.id)
                        }
                    }
                }
            case .newOrChanged:
                Text("Uses the selected backup folder’s verified ledger. Missing destination files are offered again.")
                    .foregroundStyle(.secondary)
            case .allAccessible:
                Text("Includes every photo and video currently visible to this app.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var profileSection: some View {
        Section("Export profile") {
            Picker("Profile", selection: $model.profileKind) {
                ForEach(ExportProfileKind.allCases, id: \.self) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            Toggle("Keep location in manifests and compatible copies", isOn: $model.preserveLocation)
            if model.profileKind == .originalsAndCurrentJpegs {
                Text("HEIC, RAW, and edited stills get an 8-bit sRGB JPEG at quality 0.92. Videos are never transcoded.")
                    .foregroundStyle(.secondary)
            }
            Text("Location removal never alters exact originals. Only receiver-verified originals count as backed up.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var preflightSection: some View {
        Section("Preflight") {
            Button("Review export") {
                Task { await model.buildPreflight() }
            }
            .disabled(
                model.assets.isEmpty || !coordinator.isConnected
                    || coordinator.isRunning || model.isPlanning
            )

            if model.isPlanning {
                ProgressView("Preparing export review…")
            }

            if let summary = model.plannedExport?.preflight {
                LabeledContent("Assets", value: "\(summary.assetCount)")
                LabeledContent("Original resources", value: "\(summary.originalFileCount)")
                LabeledContent("JPEGs to create", value: "\(summary.generatedJPEGCount)")
                if let freeBytes = summary.destinationFreeBytes {
                    LabeledContent(
                        "Destination free",
                        value: ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
                    )
                }
                LabeledContent("Already verified", value: "\(summary.unchangedFileCount)")
                if summary.resumableFileCount > 0 {
                    LabeledContent("Ready to resume", value: "\(summary.resumableFileCount)")
                }
                if summary.changedFileCount > 0 {
                    LabeledContent("Changed renditions", value: "\(summary.changedFileCount)")
                }
                if summary.conflictFileCount > 0 {
                    LabeledContent("Path conflicts", value: "\(summary.conflictFileCount)")
                }
                if summary.estimatedKnownBytes > 0 {
                    LabeledContent(
                        "Known source size",
                        value: ByteCountFormatter.string(fromByteCount: summary.estimatedKnownBytes, countStyle: .file)
                    )
                }
                if summary.unknownByteCount > 0 {
                    LabeledContent("Size pending", value: "\(summary.unknownByteCount) file(s)")
                }
                ForEach(summary.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Start verified export") { model.startExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.isConnected || coordinator.isRunning || model.isPlanning)
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if coordinator.progress.phase != .idle {
            Section("Current job") {
                Label(coordinator.progress.phase.rawValue.capitalized, systemImage: phaseIcon)
                if !coordinator.progress.currentFilename.isEmpty {
                    Text(coordinator.progress.currentFilename).lineLimit(1)
                    ProgressView(value: coordinator.progress.currentFileFraction)
                    LabeledContent(
                        "File",
                        value: "\(coordinator.progress.currentFileIndex) of \(coordinator.progress.totalFileCount)"
                    )
                }
                HStack {
                    statusMetric("Verified", coordinator.progress.verifiedFileCount)
                    statusMetric("Skipped", coordinator.progress.skippedFileCount)
                    statusMetric("Failed", coordinator.progress.failedFileCount)
                }
                if let message = coordinator.progress.lastMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if coordinator.isRunning {
                    Button("Stop for now") { coordinator.pause() }
                } else if coordinator.progress.phase == .paused || coordinator.progress.phase == .failed {
                    Button("Retry / resume") { coordinator.retry() }
                        .disabled(!coordinator.isConnected)
                    Button("Discard partial job", role: .destructive) {
                        Task { await coordinator.discardCurrentJob() }
                    }
                }
                if let report = coordinator.completionReport {
                    LabeledContent("Report", value: report.reportRelativePath)
                    Text("\(report.counts.verifiedOriginalFiles) original file(s) verified")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var phaseIcon: String {
        switch coordinator.progress.phase {
        case .completed: "checkmark.seal.fill"
        case .completedWithFailures: "exclamationmark.triangle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private func statusMetric(_ title: String, _ value: Int) -> some View {
        VStack { Text("\(value)").font(.headline); Text(title).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }

    private func requestCameraAndScan() {
        guard DataScannerViewController.isSupported else {
            model.alertMessage = "QR scanning is not available on this device. Enter the pairing URL instead."
            return
        }
        requestingCamera = true
        Task {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            requestingCamera = false
            if allowed { showingScanner = true }
            else { model.alertMessage = "Camera access is required to scan. You can enter the pairing URL manually." }
        }
    }
}

private struct PhotoThumbnailButton: View {
    let catalog: PhotoKitCatalog
    let asset: PhotoAsset
    let isSelected: Bool
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                    else { Rectangle().fill(.quaternary).overlay { ProgressView() } }
                }
                .frame(height: 82)
                .clipped()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isSelected ? .white : .white, isSelected ? .blue : .black.opacity(0.4))
                    .padding(4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.mediaKind == .video ? "Video" : "Photo")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .task(id: thumbnailTaskID) {
            image = nil
            let loaded = await catalog.thumbnail(
                assetID: asset.id,
                size: Self.thumbnailSize,
                scale: UIScreen.main.scale
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private static let thumbnailSize = CGSize(width: 100, height: 82)

    private var thumbnailTaskID: PhotoThumbnailTaskID {
        let scale = UIScreen.main.scale
        return PhotoThumbnailTaskID(
            assetID: asset.id,
            sourceRevision: asset.sourceRevision,
            pixelWidth: max(Int((Self.thumbnailSize.width * scale).rounded(.up)), 1),
            pixelHeight: max(Int((Self.thumbnailSize.height * scale).rounded(.up)), 1)
        )
    }
}

private struct PhotoThumbnailTaskID: Hashable {
    let assetID: String
    let sourceRevision: String
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No exports yet",
                    systemImage: "externaldrive",
                    description: Text("Verified and paused jobs will appear here.")
                )
            } else {
                ForEach(model.history) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.destinationName ?? "Windows backup").font(.headline)
                            Spacer()
                            Text(entry.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                        Text("\(entry.verifiedFileCount) verified • \(entry.skippedFileCount) skipped • \(entry.failedFileCount) failed")
                            .font(.footnote)
                        if let report = entry.completionReport {
                            NavigationLink("View JSON completion report") {
                                CompletionReportView(report: report)
                            }
                        }
                        if entry.status == .paused {
                            Button("Load frozen job for resume") {
                                Task { await model.loadResume(jobID: entry.id) }
                            }
                        } else if entry.status == .completedWithFailures {
                            Text("Resolve unavailable sources, then run New or Changed to try them again.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Export History")
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
