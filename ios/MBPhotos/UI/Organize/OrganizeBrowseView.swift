import SwiftUI

struct OrganizeBrowseView: View {
    @ObservedObject var model: OrganizeViewModel
    let title: String
    var scopeAssetIDs: Set<String>?
    var scopeKey: String
    var recommendationKind: OrganizeRecommendationCategory?

    @State private var isSelecting = false
    @State private var showingFilters = false
    @State private var protectedSelection: [OrganizeAssetPresentation] = []
    @State private var sections: [OrganizeBrowseSection] = []
    @State private var completedQuery: BrowseQuery?

    init(
        model: OrganizeViewModel,
        title: String,
        scopeAssetIDs: Set<String>? = nil,
        scopeKey: String = "all",
        recommendationKind: OrganizeRecommendationCategory? = nil
    ) {
        self.model = model
        self.title = title
        self.scopeAssetIDs = scopeAssetIDs
        self.scopeKey = scopeKey
        self.recommendationKind = recommendationKind
    }

    var body: some View {
        Group {
            if sections.isEmpty, completedQuery == query {
                ContentUnavailableView(
                    model.browseConfiguration.filter.isActive ? "No Matching Items" : "No Items",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(model.browseConfiguration.filter.isActive
                        ? "Try removing one or more filters."
                        : "Accessible photos and videos will appear here.")
                )
            } else if sections.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 105), spacing: 3)],
                                    spacing: 12
                                ) {
                                    ForEach(section.assets) { asset in
                                        assetDestination(asset)
                                    }
                                }
                            } header: {
                                if let title = section.title {
                                    HStack {
                                        Text(title).font(.headline)
                                        Spacer()
                                        Text("\(section.assets.count)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 7)
                                    .background(.background)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.bottom, isSelecting ? 80 : 12)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                filterButton
                groupingMenu
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { Task { await model.clearSelection() } }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .sheet(isPresented: $showingFilters) {
            OrganizeFilterSheet(model: model)
        }
        .task(id: query) {
            guard let next = await model.browseSections(for: query) else { return }
            sections = next
            completedQuery = query
        }
        .confirmationDialog(
            "Override Protection?",
            isPresented: Binding(
                get: { !protectedSelection.isEmpty },
                set: { if !$0 { protectedSelection = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Queue \(protectedSelection.count) Protected Item\(protectedSelection.count == 1 ? "" : "s")", role: .destructive) {
                Task {
                    _ = await model.queueAssetsInBackground(
                        model.selectedAssetIDs,
                        allowProtected: true,
                        recommendationKind: recommendationKind
                    )
                    await model.clearSelection()
                    protectedSelection = []
                }
            }
            .disabled(model.isMovingToRecentlyDeleted)
            Button("Cancel", role: .cancel) { protectedSelection = [] }
        } message: {
            Text("Favorites, hidden or edited items, and items in protected albums require an explicit override. This only stages them; nothing moves until final confirmation.")
        }
    }

    private var query: BrowseQuery {
        model.browseQuery(scopeAssetIDs: scopeAssetIDs, scopeKey: scopeKey)
    }

    @ViewBuilder
    private func assetDestination(_ asset: OrganizeAssetPresentation) -> some View {
        if isSelecting {
            Button { Task { await model.toggleSelection(asset.id) } } label: {
                OrganizeAssetGridCell(
                    model: model,
                    asset: asset,
                    metric: model.activeMetric(for: asset),
                    isSelected: model.selectedAssetIDs.contains(asset.id),
                    showsSelection: true,
                    isQueued: model.queuedAssetIDs.contains(asset.id)
                )
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.selectedAssetIDs.contains(asset.id) ? "Selected" : "Not selected")
        } else {
            NavigationLink {
                OrganizeAssetDetailView(
                    model: model,
                    assetID: asset.id,
                    recommendationKind: recommendationKind
                )
            } label: {
                OrganizeAssetGridCell(
                    model: model,
                    asset: asset,
                    metric: model.activeMetric(for: asset),
                    isSelected: false,
                    showsSelection: false,
                    isQueued: model.queuedAssetIDs.contains(asset.id)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $model.browseConfiguration.sort) {
                ForEach(availableSortOptions) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
            Divider()
            Picker("Direction", selection: $model.browseConfiguration.direction) {
                ForEach(OrganizeSortDirection.allCases, id: \.rawValue) { direction in
                    Label(direction.organizeLabel, systemImage: direction.organizeSystemImage).tag(direction)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort, currently \(model.browseConfiguration.sort.label), \(model.browseConfiguration.direction.organizeLabel)")
    }

    private var availableSortOptions: [OrganizeBrowseSortOption] {
        OrganizeBrowseSortOption.allCases.filter { option in
            option != .addedDate || model.hasAssetsWithAddedDate
        }
    }

    private var filterButton: some View {
        Button { showingFilters = true } label: {
            Image(systemName: model.browseConfiguration.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(model.browseConfiguration.filter.isActive ? "Filters, active" : "Filters")
    }

    private var groupingMenu: some View {
        Menu {
            Picker("Group by", selection: $model.browseConfiguration.grouping) {
                ForEach(OrganizeBrowseGrouping.allCases) { grouping in
                    Text(grouping.label).tag(grouping)
                }
            }
        } label: {
            Label("Group", systemImage: "rectangle.3.group")
        }
        .accessibilityLabel("Group by \(model.browseConfiguration.grouping.label)")
    }

    private var selectionBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Text("\(model.selectedAssetIDs.count) selected")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Queue for Recently Deleted") { queueSelection() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(model.selectedAssetIDs.isEmpty || model.isMovingToRecentlyDeleted)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private func queueSelection() {
        Task {
            let protected = await model.queueAssetsInBackground(
                model.selectedAssetIDs,
                recommendationKind: recommendationKind
            )
            if protected.isEmpty {
                await model.clearSelection()
            } else {
                protectedSelection = protected
            }
        }
    }
}

private struct OrganizeAssetGridCell: View {
    @ObservedObject var model: OrganizeViewModel
    let asset: OrganizeAssetPresentation
    let metric: String
    let isSelected: Bool
    let showsSelection: Bool
    let isQueued: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    OrganizeThumbnailView(
                        model: model,
                        asset: asset,
                        size: CGSize(width: proxy.size.width, height: 92)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        OrganizeAssetBadges(asset: asset).padding(5)
                    }

                    if showsSelection {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? .blue : .black.opacity(0.45))
                            .padding(5)
                    } else if isQueued {
                        Image(systemName: "trash.slash.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.orange, in: Circle())
                            .padding(5)
                    }
                }

                Text(metric)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 116)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(asset.mediaKind == .video ? "Video" : "Photo"), \(metric)")
        .accessibilityValue(isQueued ? "Queued for Recently Deleted" : "")
    }
}

private struct OrganizeFilterSheet: View {
    @ObservedObject var model: OrganizeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Media") {
                    Picker("Kind", selection: $model.browseConfiguration.filter.media) {
                        ForEach(OrganizeMediaFilter.allCases) { value in Text(value.label).tag(value) }
                    }
                    triStatePicker("Screenshots", selection: $model.browseConfiguration.filter.screenshots)
                    triStatePicker("Live Photos", selection: $model.browseConfiguration.filter.livePhotos)
                    triStatePicker("RAW", selection: $model.browseConfiguration.filter.rawPhotos)
                    Picker("Format", selection: $model.browseConfiguration.filter.fileFormat) {
                        Text("Any").tag(nil as String?)
                        ForEach(formats, id: \.self) { Text($0).tag($0 as String?) }
                    }
                    Picker("Orientation", selection: $model.browseConfiguration.filter.orientation) {
                        Text("Any").tag(nil as OrganizeOrientation?)
                        Text("Portrait").tag(OrganizeOrientation.portrait as OrganizeOrientation?)
                        Text("Landscape").tag(OrganizeOrientation.landscape as OrganizeOrientation?)
                        Text("Square").tag(OrganizeOrientation.square as OrganizeOrientation?)
                    }
                }

                Section("Dates") {
                    Toggle("Starting", isOn: $model.browseConfiguration.filter.useStartDate)
                    if model.browseConfiguration.filter.useStartDate {
                        DatePicker("From", selection: $model.browseConfiguration.filter.startDate, displayedComponents: .date)
                    }
                    Toggle("Ending", isOn: $model.browseConfiguration.filter.useEndDate)
                    if model.browseConfiguration.filter.useEndDate {
                        DatePicker("Through", selection: $model.browseConfiguration.filter.endDate, displayedComponents: .date)
                    }
                }

                Section("Size & Duration") {
                    Picker("Minimum known size", selection: $model.browseConfiguration.filter.minimumBytes) {
                        Text("Any").tag(nil as Int64?)
                        Text("10 MB").tag(Int64(10_000_000) as Int64?)
                        Text("100 MB").tag(Int64(100_000_000) as Int64?)
                        Text("500 MB").tag(Int64(500_000_000) as Int64?)
                        Text("1 GB").tag(Int64(1_000_000_000) as Int64?)
                    }
                    Picker("Minimum resolution", selection: $model.browseConfiguration.filter.minimumMegapixels) {
                        Text("Any").tag(nil as Double?)
                        Text("2 MP").tag(Double(2) as Double?)
                        Text("8 MP").tag(Double(8) as Double?)
                        Text("12 MP").tag(Double(12) as Double?)
                        Text("24 MP").tag(Double(24) as Double?)
                    }
                    Picker("Minimum video duration", selection: $model.browseConfiguration.filter.minimumDurationMilliseconds) {
                        Text("Any").tag(nil as Int?)
                        Text("30 seconds").tag(Int(30_000) as Int?)
                        Text("1 minute").tag(Int(60_000) as Int?)
                        Text("5 minutes").tag(Int(300_000) as Int?)
                        Text("30 minutes").tag(Int(1_800_000) as Int?)
                    }
                }

                Section("Attributes") {
                    triStatePicker("Favorites", selection: $model.browseConfiguration.filter.favorites)
                    triStatePicker("Edited", selection: $model.browseConfiguration.filter.edited)
                    triStatePicker("Hidden", selection: $model.browseConfiguration.filter.hidden)
                    triStatePicker("Location", selection: $model.browseConfiguration.filter.location)
                }

                Section("Albums") {
                    Picker("Membership", selection: $model.browseConfiguration.filter.albumMode) {
                        ForEach(OrganizeAlbumFilterMode.allCases) { value in Text(value.label).tag(value) }
                    }
                    if model.browseConfiguration.filter.albumMode == .selectedAlbum {
                        Picker("Album", selection: $model.browseConfiguration.filter.selectedAlbumID) {
                            Text("Choose Album").tag(nil as String?)
                            ForEach(model.albums) { album in Text(album.title).tag(album.id as String?) }
                        }
                    }
                }

                Section("Workflow") {
                    Picker("Review state", selection: $model.browseConfiguration.filter.reviewState) {
                        ForEach(OrganizeReviewStateFilter.allCases) { value in Text(value.label).tag(value) }
                    }
                    Picker("Analysis", selection: $model.browseConfiguration.filter.analysisState) {
                        ForEach(OrganizeAnalysisFilter.allCases) { value in Text(value.label).tag(value) }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { model.browseConfiguration.filter = OrganizeBrowseFilter() }
                        .disabled(!model.browseConfiguration.filter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var formats: [String] {
        model.availableFormats
    }

    private func triStatePicker(
        _ title: String,
        selection: Binding<OrganizeTriStateFilter>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(OrganizeTriStateFilter.allCases) { value in Text(value.label).tag(value) }
        }
    }
}

private struct OrganizeAssetDetailView: View {
    @ObservedObject var model: OrganizeViewModel
    let assetID: String
    let recommendationKind: OrganizeRecommendationCategory?
    @State private var confirmingProtection = false

    var body: some View {
        Group {
            if let asset = model.asset(id: assetID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        OrganizeAssetPreviewView(model: model, asset: asset, playsLivePhotos: true)
                            .frame(height: 390)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                OrganizeAssetBadges(asset: asset)
                                Text(asset.originalFilename)
                                    .font(.headline)
                                    .textSelection(.enabled)
                            }
                            metadata(asset)
                        }

                        HStack {
                            Button {
                                Task { await model.keepQueuedAsset(asset.id) }
                            } label: {
                                Label("Keep", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                Task {
                                    let protected = await model.queueAssets(
                                        [asset.id],
                                        recommendationKind: recommendationKind
                                    )
                                    if !protected.isEmpty { confirmingProtection = true }
                                }
                            } label: {
                                Label(
                                    model.queuedAssetIDs.contains(asset.id) ? "Queued" : "Queue",
                                    systemImage: "trash.slash"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(model.queuedAssetIDs.contains(asset.id))
                        }
                        .disabled(model.isMovingToRecentlyDeleted)
                    }
                    .padding()
                }
                .navigationTitle(asset.mediaKind == .video ? "Video" : "Photo")
                .navigationBarTitleDisplayMode(.inline)
                .confirmationDialog("Override Protection?", isPresented: $confirmingProtection, titleVisibility: .visible) {
                    Button("Queue Anyway", role: .destructive) {
                        Task {
                            _ = await model.queueAssets(
                                [asset.id],
                                allowProtected: true,
                                recommendationKind: recommendationKind
                            )
                        }
                    }
                    .disabled(model.isMovingToRecentlyDeleted)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("\(asset.protectionSummary ?? "This item") is protected by default. Queueing only stages it for the final review.")
                }
            } else {
                ContentUnavailableView("Item Unavailable", systemImage: "photo.badge.exclamationmark")
            }
        }
    }

    private func metadata(_ asset: OrganizeAssetPresentation) -> some View {
        VStack(spacing: 8) {
            LabeledContent("Captured", value: asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
            LabeledContent("Dimensions", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
            if let duration = asset.durationMilliseconds {
                LabeledContent("Duration", value: OrganizeViewModel.durationString(duration))
            }
            LabeledContent("Known size", value: asset.knownBytes.map(OrganizeViewModel.byteString) ?? "Pending analysis")
            LabeledContent("Albums", value: "\(asset.albumCount)")
            if let format = asset.fileFormat { LabeledContent("Format", value: format) }
            LabeledContent("Review", value: asset.isReviewed ? "Reviewed" : "Unreviewed")
        }
        .font(.subheadline)
    }
}
