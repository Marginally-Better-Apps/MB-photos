import SwiftUI
import UIKit

struct TransferSelectionView: View {
    enum Tab: String, CaseIterable {
        case photos = "Photos"
        case albums = "Albums"
    }

    @ObservedObject var model: AppModel
    @ObservedObject private var organizeModel: OrganizeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .photos
    @State private var photoDateGrouping: TransferPhotoDateGrouping = .day
    @State private var photoSections: [TransferPhotoDateSection] = []
    @State private var photoFrames: [String: CGRect] = [:]
    @State private var dragSession: TransferPhotoDragSession?
    @State private var dragIntent: TransferPhotoDragIntent = .undecided

    init(model: AppModel) {
        self.model = model
        self._organizeModel = ObservedObject(wrappedValue: model.organizeViewModel)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Selection Type", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 12)

                switch tab {
                case .photos:
                    photosGrid
                case .albums:
                    albumsList
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Choose Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(bulkSelectionTitle) {
                        toggleBulkSelection()
                    }
                    .disabled(bulkSelectionIsDisabled)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectionSummary)
                            .font(.subheadline)
                            .foregroundStyle(hasSelection ? .primary : .secondary)
                        if hasSelection {
                            Text(selectionSizeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.authorization == .limited {
                        Button("Choose More") { model.presentLimitedPicker() }
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }

    private var photosGrid: some View {
        ScrollView {
            if model.assets.isEmpty {
                ContentUnavailableView(
                    "No Photos Available",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Photos and videos shared with MB Photos will appear here.")
                )
                .frame(minHeight: 320)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("\(model.assets.count) item\(model.assets.count == 1 ? "" : "s")")
                            .monospacedDigit()
                        Spacer()
                        Menu {
                            Picker("Group photos by", selection: $photoDateGrouping) {
                                ForEach(TransferPhotoDateGrouping.allCases) { grouping in
                                    Text(grouping.label).tag(grouping)
                                }
                            }
                        } label: {
                            Label("By \(photoDateGrouping.label)", systemImage: "calendar")
                        }
                        .accessibilityLabel("Group photos by \(photoDateGrouping.label)")
                    }
                    Label("Tap or drag to select", systemImage: "hand.draw")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(photoSections) { section in
                        Section {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 104), spacing: 3)],
                                spacing: 3
                            ) {
                                ForEach(section.assets) { asset in
                                    TransferPhotoCell(
                                        catalog: model.catalog,
                                        asset: asset,
                                        isSelected: model.selectedAssetIDs.contains(asset.id)
                                    ) {
                                        model.toggleSelectedAssetID(asset.id)
                                    }
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: TransferPhotoFramePreferenceKey.self,
                                                value: [
                                                    asset.id: geometry.frame(
                                                        in: .named(TransferPhotoGridCoordinateSpace.name)
                                                    )
                                                ]
                                            )
                                        }
                                    }
                                }
                            }
                        } header: {
                            photoSectionHeader(section)
                        }
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 24)
                .onPreferenceChange(TransferPhotoFramePreferenceKey.self) { frames in
                    photoFrames = frames
                }
            }
        }
        .coordinateSpace(name: TransferPhotoGridCoordinateSpace.name)
        // Let vertical motion begin scrolling, then freeze the viewport once
        // the same gesture resolves to range selection.
        .scrollDisabled(dragIntent == .selecting)
        .simultaneousGesture(photoDragGesture)
        .onReceive(model.$assets) { assets in
            rebuildPhotoSections(from: assets)
        }
        .onChange(of: photoDateGrouping) {
            rebuildPhotoSections(from: model.assets)
        }
    }

    private func photoSectionHeader(_ section: TransferPhotoDateSection) -> some View {
        let isSelected = section.assets.allSatisfy {
            model.selectedAssetIDs.contains($0.id)
        }
        return Button {
            model.setSelectedAssetIDs(section.assets.map(\.id), isSelected: !isSelected)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(section.assets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.title), \(section.assets.count) item\(section.assets.count == 1 ? "" : "s")")
        .accessibilityValue(isSelected ? "All selected" : "Not all selected")
        .accessibilityHint("Double tap to toggle every item in this date group.")
    }

    private func rebuildPhotoSections(from assets: [PhotoAsset]) {
        photoSections = TransferPhotoDateSection.sections(
            for: assets,
            grouping: photoDateGrouping
        )
    }

    private var albumsList: some View {
        ScrollView {
            if model.albums.isEmpty {
                ContentUnavailableView(
                    "No Albums Available",
                    systemImage: "rectangle.stack",
                    description: Text("User-created albums shared with MB Photos will appear here.")
                )
                .frame(minHeight: 320)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.albums) { album in
                        let isSelected = model.selectedAlbumIDs.contains(album.id)
                        Button {
                            model.toggleSelectedAlbumID(album.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(album.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("\(album.assetIDs.count) item\(album.assetIDs.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.10) : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .overlay {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
    }

    private var photoDragGesture: some Gesture {
        DragGesture(
            minimumDistance: 8,
            coordinateSpace: .named(TransferPhotoGridCoordinateSpace.name)
        )
        .onChanged { value in
            updateDragSelection(value)
        }
        .onEnded { _ in
            dragSession = nil
            dragIntent = .undecided
        }
    }

    private func updateDragSelection(_ value: DragGesture.Value) {
        if dragIntent == .undecided {
            dragIntent = TransferPhotoDragIntent.resolve(value.translation)
        }
        guard dragIntent == .selecting else { return }

        let previousLocation = dragSession?.lastLocation ?? value.startLocation
        let assetIDs = assetIDsAlongPath(from: previousLocation, to: value.location)
        guard !assetIDs.isEmpty else { return }

        var session = dragSession
        if session == nil, let firstID = assetIDs.first {
            session = TransferPhotoDragSession(
                isSelecting: !model.selectedAssetIDs.contains(firstID),
                lastLocation: previousLocation
            )
        }
        guard var session else { return }

        var newlyVisitedAssetIDs: [String] = []
        for assetID in assetIDs where session.visit(assetID) {
            newlyVisitedAssetIDs.append(assetID)
        }
        if !newlyVisitedAssetIDs.isEmpty {
            model.setSelectedAssetIDs(
                newlyVisitedAssetIDs,
                isSelected: session.isSelecting
            )
        }
        session.lastLocation = value.location
        dragSession = session
    }

    private func assetIDsAlongPath(from start: CGPoint, to end: CGPoint) -> [String] {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let sampleCount = max(Int(ceil(distance / 8)), 1)
        var result: [String] = []
        var seen: Set<String> = []

        for step in 0...sampleCount {
            let fraction = CGFloat(step) / CGFloat(sampleCount)
            let point = CGPoint(
                x: start.x + ((end.x - start.x) * fraction),
                y: start.y + ((end.y - start.y) * fraction)
            )
            guard let assetID = photoFrames.first(where: { $0.value.contains(point) })?.key,
                  seen.insert(assetID).inserted else { continue }
            result.append(assetID)
        }
        return result
    }

    private var allPhotosSelected: Bool {
        !model.assets.isEmpty
            && model.assets.allSatisfy { model.selectedAssetIDs.contains($0.id) }
    }

    private var allAlbumsSelected: Bool {
        !model.albums.isEmpty
            && model.albums.allSatisfy { model.selectedAlbumIDs.contains($0.id) }
    }

    private var bulkSelectionTitle: String {
        switch tab {
        case .photos: allPhotosSelected ? "Deselect All" : "Select All"
        case .albums: allAlbumsSelected ? "Deselect All" : "Select All"
        }
    }

    private var bulkSelectionIsDisabled: Bool {
        switch tab {
        case .photos: model.assets.isEmpty
        case .albums: model.albums.isEmpty
        }
    }

    private func toggleBulkSelection() {
        switch tab {
        case .photos: model.setAllAssetsSelected(!allPhotosSelected)
        case .albums: model.setAllAlbumsSelected(!allAlbumsSelected)
        }
    }

    private var hasSelection: Bool {
        !model.selectedAssetIDs.isEmpty || !model.selectedAlbumIDs.isEmpty
    }

    private var selectionSummary: String {
        var parts: [String] = []
        let photoCount = model.selectedAssetIDs.count
        let albumCount = model.selectedAlbumIDs.count
        if photoCount > 0 {
            parts.append("\(photoCount) photo\(photoCount == 1 ? "" : "s")")
        }
        if albumCount > 0 {
            parts.append("\(albumCount) album\(albumCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: " · ")
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
}

enum TransferPhotoDateGrouping: String, CaseIterable, Identifiable, Sendable {
    case day
    case month
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: "Day"
        case .month: "Month"
        case .year: "Year"
        }
    }

    fileprivate var calendarComponent: Calendar.Component {
        switch self {
        case .day: .day
        case .month: .month
        case .year: .year
        }
    }
}

struct TransferPhotoDateSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let assets: [PhotoAsset]

    private struct GroupKey: Hashable {
        let id: String
        let title: String
        let chronologicalDate: Date?
    }

    static func sections(
        for assets: [PhotoAsset],
        grouping: TransferPhotoDateGrouping,
        calendar: Calendar = .current
    ) -> [TransferPhotoDateSection] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.timeZone = calendar.timeZone
        switch grouping {
        case .day:
            formatter.dateStyle = .full
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
        }

        var assetsByGroup: [GroupKey: [PhotoAsset]] = [:]
        for asset in assets {
            let key: GroupKey
            if let creationDate = asset.creationDate,
               let interval = calendar.dateInterval(
                   of: grouping.calendarComponent,
                   for: creationDate
               ) {
                let start = interval.start
                key = GroupKey(
                    id: "\(grouping.rawValue)-\(Int(start.timeIntervalSinceReferenceDate))",
                    title: formatter.string(from: start),
                    chronologicalDate: start
                )
            } else {
                key = GroupKey(
                    id: "date-unknown",
                    title: "Date Unknown",
                    chronologicalDate: nil
                )
            }
            assetsByGroup[key, default: []].append(asset)
        }

        return assetsByGroup.keys.sorted { left, right in
            switch (left.chronologicalDate, right.chronologicalDate) {
            case let (.some(leftDate), .some(rightDate)):
                if leftDate == rightDate { return left.id < right.id }
                return leftDate > rightDate
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return left.id < right.id
            }
        }.map { key in
            TransferPhotoDateSection(
                id: key.id,
                title: key.title,
                assets: assetsByGroup[key] ?? []
            )
        }
    }
}

struct TransferSelectionSize: Equatable {
    let assetCount: Int
    let knownBytes: Int64
    let unknownAssetCount: Int

    static func calculate(
        selectedAssetIDs: Set<String>,
        selectedAlbumIDs: Set<String>,
        albums: [PhotoAlbum],
        knownByteCount: (String) -> Int64?
    ) -> TransferSelectionSize {
        var assetIDs = selectedAssetIDs
        for album in albums where selectedAlbumIDs.contains(album.id) {
            assetIDs.formUnion(album.assetIDs)
        }

        var knownBytes: Int64 = 0
        var unknownAssetCount = 0
        for assetID in assetIDs {
            guard let bytes = knownByteCount(assetID), bytes >= 0 else {
                unknownAssetCount += 1
                continue
            }
            let (sum, overflow) = knownBytes.addingReportingOverflow(bytes)
            knownBytes = overflow ? .max : sum
        }
        return TransferSelectionSize(
            assetCount: assetIDs.count,
            knownBytes: knownBytes,
            unknownAssetCount: unknownAssetCount
        )
    }
}

enum TransferSelectionSizePresentation {
    static func text(
        for size: TransferSelectionSize,
        byteCountFormatter: (Int64, ByteCountFormatter.CountStyle) -> String
    ) -> String {
        if size.unknownAssetCount == 0 {
            return "Total size: \(byteCountFormatter(size.knownBytes, .file))"
        }
        if size.knownBytes > 0 {
            let pending = size.unknownAssetCount
            return "Known size: \(byteCountFormatter(size.knownBytes, .file)) · "
                + "\(pending) item\(pending == 1 ? "" : "s") pending"
        }
        return "Total size: Calculating…"
    }
}

enum TransferPhotoDragIntent: Equatable {
    case undecided
    case selecting
    case scrolling

    static func resolve(_ translation: CGSize) -> TransferPhotoDragIntent {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)

        // Selection is deliberately harder to enter than scrolling. A short or
        // diagonal swipe remains available to the surrounding vertical scroll
        // view, while a clear cross-row swipe starts range selection.
        if horizontalDistance >= 24,
           horizontalDistance >= verticalDistance * 1.5 {
            return .selecting
        }
        if verticalDistance >= 10 {
            return .scrolling
        }
        return .undecided
    }
}

enum TransferPhotoBadge: Hashable {
    case livePhoto
    case video
    case edited

    static func badges(for asset: PhotoAsset) -> [TransferPhotoBadge] {
        var result: [TransferPhotoBadge] = []
        if asset.mediaSubtypes.contains(.livePhoto) { result.append(.livePhoto) }
        if asset.mediaKind == .video { result.append(.video) }
        if asset.isEdited { result.append(.edited) }
        return result
    }

    var title: String {
        switch self {
        case .livePhoto: "LIVE"
        case .video: "VIDEO"
        case .edited: "EDITED"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .livePhoto: "Live Photo"
        case .video: "Video"
        case .edited: "Edited"
        }
    }
}

struct TransferPhotoDragSession: Equatable {
    let isSelecting: Bool
    var lastLocation: CGPoint
    private(set) var visitedAssetIDs: Set<String> = []

    mutating func visit(_ assetID: String) -> Bool {
        visitedAssetIDs.insert(assetID).inserted
    }
}

private enum TransferPhotoGridCoordinateSpace {
    static let name = "transfer-photo-grid"
}

private struct TransferPhotoFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TransferPhotoCell: View {
    let catalog: PhotoKitCatalog
    let asset: PhotoAsset
    let isSelected: Bool
    let action: () -> Void
    @State private var image: UIImage?

    private var badges: [TransferPhotoBadge] {
        TransferPhotoBadge.badges(for: asset)
    }

    var body: some View {
        ZStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { ProgressView() }
                }
            }

            if isSelected {
                Color.accentColor.opacity(0.16)
            }

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.46))
                        .shadow(color: .black.opacity(0.30), radius: 1, y: 1)
                }
                Spacer()
                if !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(badges, id: \.self) { badge in
                            Text(badge.title)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(
                                    badge == .edited ? Color.orange.opacity(0.88) : Color.black.opacity(0.68),
                                    in: Capsule()
                                )
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(6)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Double tap to toggle selection. Drag across a row to select multiple items.")
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

    private var accessibilityLabel: String {
        var metadata = [asset.mediaKind == .video ? "Video" : "Photo"]
        if badges.contains(.livePhoto) { metadata[0] = "Live Photo" }
        if badges.contains(.edited) { metadata.append("Edited") }
        return metadata.joined(separator: ", ")
    }

    private static let thumbnailSize = CGSize(width: 160, height: 160)

    private var thumbnailTaskID: TransferThumbnailTaskID {
        let scale = UIScreen.main.scale
        return TransferThumbnailTaskID(
            assetID: asset.id,
            sourceRevision: asset.sourceRevision,
            pixelWidth: max(Int((Self.thumbnailSize.width * scale).rounded(.up)), 1),
            pixelHeight: max(Int((Self.thumbnailSize.height * scale).rounded(.up)), 1)
        )
    }
}

private struct TransferThumbnailTaskID: Hashable {
    let assetID: String
    let sourceRevision: String
    let pixelWidth: Int
    let pixelHeight: Int
}
