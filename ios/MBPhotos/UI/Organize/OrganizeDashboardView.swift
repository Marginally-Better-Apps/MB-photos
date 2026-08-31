import SwiftUI

private struct OrganizeReviewStackPickerItem: Identifiable {
    enum Content {
        case primary(
            entry: OrganizePrimaryReviewEntry,
            recommendation: OrganizeRecommendationPresentation?
        )
        case recommendation(OrganizeRecommendationPresentation)
    }

    let id: String
    let content: Content
    let totalKnownBytes: Int64
    let remainingItemCount: Int
    let originalIndex: Int
}

struct OrganizeView: View {
    @ObservedObject var model: OrganizeViewModel
    @Namespace private var primaryReviewTransitionNamespace

    private let primaryReviewTransitionID = "organize-primary-review"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                switch model.authorization {
                case .authorized, .limited:
                    reviewStackPicker
                    OrganizeLibraryBreakdownSection(model: model)
                    if model.authorization == .limited {
                        limitedAccessIndicator
                    }
                    deletionQueueLink
                    browseAllLink
                case .notDetermined, .denied, .restricted:
                    permissionEntry
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    OrganizeSettingsView(model: model)
                } label: {
                    Label("Organize Settings", systemImage: "gearshape")
                }
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.cleanExpiredThumbnails() }
        .alert(item: $model.userMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var reviewStackPicker: some View {
        let entry = model.primaryReviewEntry
        let stacks = reviewStacks(for: entry)

        if !stacks.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(stacks) { stack in
                        reviewStackLink(stack)
                            .organizeReviewStackPickerWidth(hasMultipleStacks: stacks.count > 1)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        } else {
            OrganizePlayCard(
                eyebrow: "QUICK REVIEW",
                title: model.accessibleItemCount == 0 ? "No Photos Yet" : "You're All Caught Up",
                detail: model.accessibleItemCount == 0
                    ? "Accessible photos will appear here when they are available."
                    : "Every accessible item has been reviewed.",
                status: model.accessibleItemCount == 0 ? "" : "Nice work!",
                progress: 1,
                actionTitle: nil,
                systemImage: model.accessibleItemCount == 0 ? "photo.on.rectangle.angled" : "checkmark"
            )
        }
    }

    private func reviewStacks(
        for entry: OrganizePrimaryReviewEntry
    ) -> [OrganizeReviewStackPickerItem] {
        var stacks: [OrganizeReviewStackPickerItem] = []
        var originalIndex = 0

        switch entry {
        case let .resume(session):
            stacks.append(
                OrganizeReviewStackPickerItem(
                    id: "primary-\(session.id.uuidString)",
                    content: .primary(entry: entry, recommendation: nil),
                    totalKnownBytes: entry.remainingKnownBytes {
                        model.asset(id: $0)?.knownBytes
                    },
                    remainingItemCount: entry.remainingItemCount,
                    originalIndex: originalIndex
                )
            )
        case let .start(recommendation):
            stacks.append(
                OrganizeReviewStackPickerItem(
                    id: "primary-\(recommendation.id.rawValue)",
                    content: .primary(entry: entry, recommendation: recommendation),
                    totalKnownBytes: recommendation.knownBytes,
                    remainingItemCount: entry.remainingItemCount,
                    originalIndex: originalIndex
                )
            )
        case .complete:
            break
        }

        originalIndex += stacks.count
        for recommendation in additionalReviewStacks(for: entry) {
            stacks.append(
                OrganizeReviewStackPickerItem(
                    id: "recommendation-\(recommendation.id.rawValue)",
                    content: .recommendation(recommendation),
                    totalKnownBytes: recommendation.knownBytes,
                    remainingItemCount: remainingItemCount(for: recommendation),
                    originalIndex: originalIndex
                )
            )
            originalIndex += 1
        }

        return stacks.sorted {
            if $0.totalKnownBytes != $1.totalKnownBytes {
                return $0.totalKnownBytes < $1.totalKnownBytes
            }
            return $0.originalIndex < $1.originalIndex
        }
    }

    private func additionalReviewStacks(
        for entry: OrganizePrimaryReviewEntry
    ) -> [OrganizeRecommendationPresentation] {
        let excludedKind: OrganizeRecommendationCategory? = switch entry {
        case let .resume(session):
            session.recommendationKind
        case let .start(recommendation):
            recommendation.kind
        case .complete:
            nil
        }

        return model.reviewRecommendations.compactMap { recommendation in
            guard recommendation.kind != excludedKind else { return nil }
            return remainingRecommendationForDashboard(recommendation)
        }
    }

    private func remainingRecommendationForDashboard(
        _ recommendation: OrganizeRecommendationPresentation
    ) -> OrganizeRecommendationPresentation? {
        guard recommendation.destination == .duplicates else {
            return model.remainingReviewRecommendation(recommendation)
        }

        let pendingGroups = model.duplicateGroups.filter { group in
            group.assetIDs.allSatisfy { !model.queuedAssetIDs.contains($0) }
        }
        guard !pendingGroups.isEmpty else { return nil }

        var seenAssetIDs: Set<String> = []
        let remainingAssetIDs = pendingGroups.flatMap(\.assetIDs).filter {
            seenAssetIDs.insert($0).inserted
        }
        let remainingKnownBytes = pendingGroups.reduce(into: Int64(0)) { total, group in
            let (sum, overflow) = total.addingReportingOverflow(group.knownReclaimableBytes)
            total = overflow ? .max : sum
        }
        return OrganizeRecommendationPresentation(
            kind: recommendation.kind,
            title: recommendation.title,
            detail: recommendation.detail,
            systemImage: recommendation.systemImage,
            assetIDs: remainingAssetIDs,
            assetIDSet: Set(remainingAssetIDs),
            knownBytes: remainingKnownBytes,
            destination: recommendation.destination,
            evidenceByAssetID: recommendation.evidenceByAssetID
        )
    }

    private func remainingItemCount(
        for recommendation: OrganizeRecommendationPresentation
    ) -> Int {
        guard recommendation.destination == .duplicates else {
            return recommendation.itemCount
        }
        return model.duplicateGroups.lazy.filter { group in
            group.assetIDs.allSatisfy { !model.queuedAssetIDs.contains($0) }
        }.count
    }

    @ViewBuilder
    private func reviewStackLink(_ stack: OrganizeReviewStackPickerItem) -> some View {
        switch stack.content {
        case let .primary(entry, recommendation):
            switch entry {
            case let .resume(session):
                primaryReviewLink(
                    entry: entry,
                    recommendation: recommendation,
                    title: session.title,
                    totalKnownBytes: stack.totalKnownBytes,
                    remainingItemCount: stack.remainingItemCount,
                    progress: Double(session.completedCount) / Double(max(session.assetIDs.count, 1))
                )
            case let .start(recommendation):
                primaryReviewLink(
                    entry: entry,
                    recommendation: recommendation,
                    title: recommendation.title,
                    totalKnownBytes: stack.totalKnownBytes,
                    remainingItemCount: stack.remainingItemCount,
                    progress: nil
                )
            case .complete:
                EmptyView()
            }
        case let .recommendation(recommendation):
            recommendationLink(
                recommendation,
                totalKnownBytes: stack.totalKnownBytes,
                remainingItemCount: stack.remainingItemCount
            )
        }
    }

    private func primaryReviewLink(
        entry: OrganizePrimaryReviewEntry,
        recommendation: OrganizeRecommendationPresentation?,
        title: String,
        totalKnownBytes: Int64,
        remainingItemCount: Int,
        progress: Double?
    ) -> some View {
        NavigationLink {
            OrganizeReviewDeckView(
                model: model,
                recommendation: recommendation,
                zoomTransition: OrganizeReviewZoomTransition(
                    sourceID: primaryReviewTransitionID,
                    namespace: primaryReviewTransitionNamespace
                )
            )
        } label: {
            OrganizeQuickReviewStackCard(
                model: model,
                entry: entry,
                title: title,
                totalKnownBytes: totalKnownBytes,
                remainingItemCount: remainingItemCount,
                progress: progress,
                accessibilityHint: "Opens the review deck, where you can keep items or add them to the deletion queue"
            )
            .matchedTransitionSource(
                id: primaryReviewTransitionID,
                in: primaryReviewTransitionNamespace
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var permissionEntry: some View {
        switch model.authorization {
        case .notDetermined:
            OrganizePermissionCard(
                title: "Ready to Review?",
                detail: "Choose photo access, then review your library one card at a time.",
                systemImage: "photo.on.rectangle.angled",
                actionTitle: "Choose Photo Access"
            ) {
                Task { await model.requestAuthorization() }
            }
        case .denied, .restricted:
            OrganizePermissionCard(
                title: "Photo Access Needed",
                detail: "Allow access in Settings to start reviewing your library.",
                systemImage: "photo.badge.exclamationmark",
                actionTitle: "Open Settings"
            ) {
                model.openSettings()
            }
        case .authorized, .limited:
            EmptyView()
        }
    }

    private var limitedAccessIndicator: some View {
        HStack(spacing: 7) {
            Image(systemName: "photo.badge.checkmark")
            Text("Reviewing \(model.accessibleItemCount) selected item\(model.accessibleItemCount == 1 ? "" : "s")")
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var deletionQueueLink: some View {
        NavigationLink {
            OrganizeQueueSummaryView(model: model)
        } label: {
            OrganizeActionRow(
                systemImage: model.queuedAssetIDs.isEmpty ? "tray" : "trash.slash.fill",
                title: "Deletion Queue",
                detail: queueDetail,
                tint: model.queuedAssetIDs.isEmpty ? .gray : .orange
            )
        }
        .buttonStyle(.plain)
    }

    private var queueDetail: String {
        let count = model.queuedAssetIDs.count
        guard count > 0 else { return "Empty • Nothing leaves Photos without confirmation" }
        let size = model.queueKnownBytes > 0
            ? " • \(OrganizeViewModel.byteString(model.queueKnownBytes)) known"
            : ""
        return "\(count) item\(count == 1 ? "" : "s") waiting for review\(size)"
    }

    @ViewBuilder
    private func recommendationLink(
        _ recommendation: OrganizeRecommendationPresentation,
        totalKnownBytes: Int64,
        remainingItemCount: Int
    ) -> some View {
        switch recommendation.destination {
        case .review:
            NavigationLink {
                OrganizeReviewDeckView(model: model, recommendation: recommendation)
            } label: {
                quickReviewCard(
                    for: recommendation,
                    totalKnownBytes: totalKnownBytes,
                    remainingItemCount: remainingItemCount
                )
            }
            .buttonStyle(.plain)
        case .browse:
            NavigationLink {
                OrganizeBrowseView(
                    model: model,
                    title: recommendation.title,
                    scopeAssetIDs: recommendation.assetIDSet,
                    scopeKey: recommendation.id.rawValue,
                    recommendationKind: recommendation.kind
                )
            } label: {
                quickReviewCard(
                    for: recommendation,
                    totalKnownBytes: totalKnownBytes,
                    remainingItemCount: remainingItemCount
                )
            }
            .buttonStyle(.plain)
        case .duplicates:
            NavigationLink {
                OrganizeDuplicateGroupsView(model: model)
            } label: {
                quickReviewCard(
                    for: recommendation,
                    totalKnownBytes: totalKnownBytes,
                    remainingItemCount: remainingItemCount
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func quickReviewCard(
        for recommendation: OrganizeRecommendationPresentation,
        totalKnownBytes: Int64,
        remainingItemCount: Int
    ) -> some View {
        OrganizeQuickReviewStackCard(
            model: model,
            entry: .start(recommendation),
            title: recommendation.title,
            totalKnownBytes: totalKnownBytes,
            remainingItemCount: remainingItemCount,
            progress: nil,
            accessibilityHint: accessibilityHint(for: recommendation)
        )
    }

    private func accessibilityHint(for recommendation: OrganizeRecommendationPresentation) -> String {
        switch recommendation.destination {
        case .review:
            "Opens the review deck, where you can keep items or add them to the deletion queue"
        case .browse:
            "Opens this stack in the photo browser"
        case .duplicates:
            "Opens the duplicate review deck and advances after each deletion choice"
        }
    }

    private var browseAllLink: some View {
        NavigationLink {
            OrganizeBrowseView(model: model, title: "Browse All")
        } label: {
            OrganizeActionRow(
                systemImage: "square.grid.2x2",
                title: "Browse All",
                detail: "Find, filter, and select anything in your library",
                tint: .blue
            )
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    @ViewBuilder
    func organizeReviewStackPickerWidth(hasMultipleStacks: Bool) -> some View {
        if hasMultipleStacks {
            containerRelativeFrame(.horizontal, count: 10, span: 9, spacing: 12)
        } else {
            containerRelativeFrame(.horizontal)
        }
    }
}

private struct OrganizePermissionCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        OrganizeSurface {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.blue)
            Text(title)
                .font(.title2.bold())
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.top, 6)
    }
}

private struct OrganizeQuickReviewStackCard: View {
    @ObservedObject var model: OrganizeViewModel
    let entry: OrganizePrimaryReviewEntry
    let title: String
    let totalKnownBytes: Int64
    let remainingItemCount: Int
    let progress: Double?
    let accessibilityHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrganizePrimaryPhotoStack(model: model, assetIDs: previewAssetIDs)
            titleRow
            footer
        }
        .padding(18)
        .frame(height: 370, alignment: .top)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.separator.opacity(0.24), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.09), radius: 18, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(remainingLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(.indigo)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.indigo.opacity(0.11), in: Capsule())

            Spacer(minLength: 8)

            if let progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 120)
                    .tint(.indigo)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(totalSizeLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.indigo.gradient, in: Circle())
        }
    }

    private var previewAssetIDs: [String] {
        entry.previewAssetIDs { model.asset(id: $0) != nil }
    }

    private var remainingLabel: String {
        "\(remainingItemCount) left"
    }

    private var totalSizeLabel: String {
        "\(OrganizeViewModel.byteString(totalKnownBytes)) total"
    }

    private var accessibilityLabel: String {
        let count = remainingItemCount
        let items = "\(count) item\(count == 1 ? "" : "s") remaining"
        if let progress {
            return "\(title), \(items), \(totalSizeLabel), \(Int(progress * 100)) percent complete"
        }
        return "\(title), \(items), \(totalSizeLabel)"
    }
}

private struct OrganizePrimaryPhotoStack: View {
    @ObservedObject var model: OrganizeViewModel
    let assetIDs: [String]

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(max(proxy.size.width * 0.58, 156), 220)
            let cardHeight = min(cardWidth * 1.18, proxy.size.height - 12)
            let cardSize = CGSize(width: cardWidth, height: cardHeight)

            ZStack {
                if assetIDs.isEmpty {
                    unavailableCard(size: cardSize)
                } else {
                    ForEach(Array(assetIDs.enumerated()), id: \.element) { index, id in
                        if let asset = model.asset(id: id) {
                            OrganizeThumbnailView(
                                model: model,
                                asset: asset,
                                size: cardSize,
                                contentMode: .fill
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(.background, lineWidth: 3)
                            }
                            .shadow(color: .black.opacity(index == 0 ? 0.2 : 0.12), radius: 10, y: 6)
                            .rotationEffect(rotation(for: index))
                            .offset(offset(for: index))
                            .zIndex(Double(assetIDs.count - index))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 242)
        .accessibilityHidden(true)
    }

    private func rotation(for index: Int) -> Angle {
        switch index {
        case 1: .degrees(-6)
        case 2: .degrees(6)
        default: .zero
        }
    }

    private func offset(for index: Int) -> CGSize {
        switch index {
        case 0: CGSize(width: 0, height: 8)
        case 1: CGSize(width: -17, height: 1)
        case 2: CGSize(width: 17, height: -2)
        default: .zero
        }
    }

    private func unavailableCard(size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.quaternary)
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.background, lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
        .offset(y: 8)
    }
}

private struct OrganizePlayCard: View {
    let eyebrow: String
    let title: String
    let detail: String
    let status: String
    let progress: Double?
    let actionTitle: String?
    let systemImage: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.blue, .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 116, weight: .bold))
                .rotationEffect(.degrees(-10))
                .offset(x: 28, y: 30)
                .foregroundStyle(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 11) {
                Text(eyebrow)
                    .font(.caption2.weight(.heavy))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.75))

                Text(title)
                    .font(.system(.title, design: .rounded, weight: .bold))

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.84))

                if let progress {
                    ProgressView(value: progress)
                        .tint(.white)
                }

                ViewThatFits(in: .horizontal) {
                    HStack {
                        statusView
                        Spacer()
                        actionView
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        statusView
                        actionView
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .padding(22)
        }
        .foregroundStyle(.white)
        .frame(minHeight: 220)
        .shadow(color: .indigo.opacity(0.18), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusView: some View {
        if !status.isEmpty {
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if let actionTitle {
            Label(actionTitle, systemImage: systemImage)
                .font(.subheadline.weight(.bold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white, in: Capsule())
                .foregroundStyle(.indigo)
        } else {
            Image(systemName: systemImage)
                .font(.title2.bold())
                .foregroundStyle(.white)
        }
    }
}

enum OrganizeBreakdownPresentation {
    static func metricsByKnownSize(
        _ metrics: [OrganizeBreakdownMetric],
        omittingEmpty: Bool = false
    ) -> [OrganizeBreakdownMetric] {
        metrics.enumerated()
            .filter { !omittingEmpty || $0.element.itemCount > 0 }
            .sorted { lhs, rhs in
                if lhs.element.knownBytes != rhs.element.knownBytes {
                    return lhs.element.knownBytes > rhs.element.knownBytes
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

private struct OrganizeLibraryBreakdownSection: View {
    @ObservedObject var model: OrganizeViewModel
    @State private var showsMoreDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrganizeSectionTitle("Library Breakdown")

            OrganizeSurface {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(OrganizeViewModel.byteString(model.totalKnownBytes))
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 8)

                        if model.analysis.phase == .running {
                            HStack(spacing: 5) {
                                Text("Scanning")
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Scanning photo library")
                        }
                        else {
                            OrganizeAnalysisMetricIndicator(
                                isActive: false,
                                hasPendingAnalysis: false,
                                unavailableAssetCount: model.analysis.unavailableAssetCount,
                                failedAssetCount: model.analysis.failedAssetCount
                            )
                        }
                    }

                    Text("\(model.analysis.processedAssetCount) of \(analysisTotalAssetCount) processed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    ForEach(primaryMetricsByKnownSize) { metric in
                        OrganizeMetricRow(
                            metric: metric,
                            total: model.totalKnownBytes,
                            isAnalysisRunning: model.analysis.phase == .running
                        )
                    }
                }

                if !detailMetricsByKnownSize.isEmpty {
                    Divider()

                    DisclosureGroup(isExpanded: $showsMoreDetails) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("These categories can overlap with each other and with the library totals above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(detailMetricsByKnownSize) { metric in
                                OrganizeMetricRow(
                                    metric: metric,
                                    total: model.totalKnownBytes,
                                    isAnalysisRunning: model.analysis.phase == .running
                                )
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        Text("More Details")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityLabel("More Details")
                            .accessibilityValue(showsMoreDetails ? "Expanded" : "Collapsed")
                            .accessibilityHint("Shows overlapping Live Photo, RAW, favorite, edited, and album categories")
                    }
                }
            }

        }
    }

    private var analysisTotalAssetCount: Int {
        model.analysis.totalAssetCount > 0
            ? model.analysis.totalAssetCount
            : model.accessibleItemCount
    }

    private var primaryMetricsByKnownSize: [OrganizeBreakdownMetric] {
        OrganizeBreakdownPresentation.metricsByKnownSize(model.primaryBreakdown)
    }

    private var detailMetricsByKnownSize: [OrganizeBreakdownMetric] {
        OrganizeBreakdownPresentation.metricsByKnownSize(
            model.secondaryBreakdown,
            omittingEmpty: true
        )
    }

}

struct OrganizeSettingsView: View {
    @ObservedObject var model: OrganizeViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                photoAccessSection
                if model.authorization == .authorized || model.authorization == .limited {
                    analysisSection
                    libraryToolsSection
                }
                safetyAndHistorySection
            }
            .padding()
            .padding(.bottom, 20)
        }
        .navigationTitle("Organize Settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
    }

    private var photoAccessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            OrganizeSectionTitle("Photo Access")
            OrganizeSurface {
                switch model.authorization {
                case .notDetermined:
                    Label("Access has not been chosen", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                    Button("Choose Photo Access") {
                        Task { await model.requestAuthorization() }
                    }
                    .buttonStyle(.borderedProminent)
                case .denied, .restricted:
                    Label("Photo access is required", systemImage: "photo.badge.exclamationmark")
                        .font(.headline)
                    Button("Open System Settings") { model.openSettings() }
                        .buttonStyle(.borderedProminent)
                case .limited:
                    Label("\(model.accessibleItemCount) selected items", systemImage: "photo.badge.checkmark")
                        .font(.headline)
                    Text("Review suggestions and library totals include only the items currently shared with MB Photos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Choose More Photos") { model.presentLimitedPicker() }
                        .buttonStyle(.bordered)
                case .authorized:
                    HStack {
                        Label("\(model.accessibleItemCount) accessible items", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Spacer()
                        if model.isRefreshing { ProgressView() }
                    }
                }
            }
        }
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            OrganizeSectionTitle("Library Analysis")
            OrganizeSurface {
                Toggle(
                    "Auto Analyze Photos",
                    isOn: Binding(
                        get: { model.autoAnalyzeEnabled },
                        set: { model.setAutoAnalyzeEnabled($0) }
                    )
                )
                .font(.headline)

                Text("Automatically analyzes new or changed photos using originals available on this device. iCloud downloads still require your confirmation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: analysisIcon)
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(analysisTitle).font(.headline)
                        Text(model.analysis.statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.analysis.phase == .running {
                    ProgressView(value: model.analysis.fractionComplete)
                    Text("\(model.analysis.processedAssetCount) of \(model.analysis.totalAssetCount) processed • \(model.analysis.completedAssetCount) sized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                OrganizeAnalysisControls(model: model)
            }
        }
    }

    @ViewBuilder
    private var libraryToolsSection: some View {
        if let noAlbum = model.organizeRecommendations.first(where: { $0.kind == .noAlbum }) {
            VStack(alignment: .leading, spacing: 10) {
                OrganizeSectionTitle("Library Tools")
                NavigationLink {
                    OrganizeBrowseView(
                        model: model,
                        title: noAlbum.title,
                        scopeAssetIDs: noAlbum.assetIDSet,
                        scopeKey: noAlbum.id.rawValue,
                        recommendationKind: noAlbum.kind
                    )
                } label: {
                    OrganizeActionRow(
                        systemImage: noAlbum.systemImage,
                        title: noAlbum.title,
                        detail: "\(noAlbum.itemCount) item\(noAlbum.itemCount == 1 ? "" : "s") to organize",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var safetyAndHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            OrganizeSectionTitle("Safety & History")
            NavigationLink {
                OrganizeProtectedAlbumsView(model: model)
            } label: {
                OrganizeActionRow(
                    systemImage: "lock.rectangle.stack",
                    title: "Protected Albums",
                    detail: model.protectedAlbumIDs.isEmpty
                        ? "Choose albums that require an extra override"
                        : "\(model.protectedAlbumIDs.count) protected album\(model.protectedAlbumIDs.count == 1 ? "" : "s")",
                    tint: .orange
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                OrganizeDeletedItemsView(model: model)
            } label: {
                OrganizeActionRow(
                    systemImage: "clock.arrow.circlepath",
                    title: "Deleted Items",
                    detail: model.deletedBatches.isEmpty
                        ? "No items moved from this app yet"
                        : "\(model.deletedAuditRecordCount) permanent audit records",
                    tint: .gray
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var analysisIcon: String {
        switch model.analysis.phase {
        case .notStarted: "magnifyingglass"
        case .running: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .complete: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var analysisTitle: String {
        switch model.analysis.phase {
        case .notStarted: "Find sizes, duplicates, and smart review stacks"
        case .running: "Analyzing library"
        case .paused: "Analysis paused"
        case .complete: "Analysis complete"
        case .failed: "Analysis needs attention"
        }
    }

}

private struct OrganizeAnalysisControls: View {
    @ObservedObject var model: OrganizeViewModel
    @State private var showsICloudConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.analysis.phase {
            case .notStarted:
                localAnalysisButton("Analyze Library")
            case .paused:
                Button("Resume Analysis") {
                    Task {
                        await model.startAnalysis(
                            includeICloudItems: model.analysis.includesICloudItems
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            case .failed:
                if model.analysis.includesICloudItems {
                    iCloudAnalysisButton("Retry Failed Items")
                } else {
                    localAnalysisButton("Retry Failed Items")
                    if model.analysis.unavailableAssetCount > 0 {
                        iCloudAnalysisButton("Include iCloud Items", prominent: false)
                    }
                }
            case .complete:
                localAnalysisButton("Refresh Smart Stacks", prominent: false)
                if model.analysis.failedAssetCount > 0 {
                    if model.analysis.includesICloudItems {
                        iCloudAnalysisButton("Retry Failed Items")
                    } else {
                        localAnalysisButton("Retry Failed Items")
                    }
                }
                if !model.analysis.includesICloudItems,
                   model.analysis.unavailableAssetCount > 0 {
                    iCloudAnalysisButton("Include iCloud Items", prominent: false)
                }
            case .running:
                EmptyView()
            }
        }
        .confirmationDialog(
            "Analyze iCloud Originals?",
            isPresented: $showsICloudConfirmation,
            titleVisibility: .visible
        ) {
            Button("Analyze iCloud Originals") {
                Task { await model.startAnalysis(includeICloudItems: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MB Photos may download original photos and videos from iCloud and hash their contents. This can use significant network data and battery. Progress is saved so analysis can pause and resume.")
        }
    }

    @ViewBuilder
    private func localAnalysisButton(
        _ title: String,
        prominent: Bool = true
    ) -> some View {
        if prominent {
            localAnalysisAction(title)
                .buttonStyle(.borderedProminent)
        } else {
            localAnalysisAction(title)
                .buttonStyle(.bordered)
        }
    }

    private func localAnalysisAction(_ title: String) -> some View {
        Button(title) {
            Task { await model.startAnalysis(includeICloudItems: false) }
        }
        .disabled(model.accessibleItemCount == 0)
    }

    @ViewBuilder
    private func iCloudAnalysisButton(
        _ title: String,
        prominent: Bool = true
    ) -> some View {
        if prominent {
            Button(title) { showsICloudConfirmation = true }
                .buttonStyle(.borderedProminent)
        } else {
            Button(title) { showsICloudConfirmation = true }
                .buttonStyle(.bordered)
        }
    }
}

private struct OrganizeAnalysisMetricIndicator: View {
    let isActive: Bool
    let hasPendingAnalysis: Bool
    let unavailableAssetCount: Int
    let failedAssetCount: Int

    var body: some View {
        ZStack {
            if isActive && hasPendingAnalysis {
                ProgressView()
                    .controlSize(.mini)
            } else if unavailableAssetCount > 0 || failedAssetCount > 0 {
                HStack(spacing: 3) {
                    if failedAssetCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if unavailableAssetCount > 0 {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundStyle(.blue)
                    }
                }
                .font(.caption2)
            } else {
                Color.clear
            }
        }
        .frame(width: 28, height: 16)
        .accessibilityHidden(true)
    }
}

private struct OrganizeMetricRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let metric: OrganizeBreakdownMetric
    let total: Int64
    let isAnalysisRunning: Bool

    var body: some View {
        VStack(spacing: 7) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    metricIdentity
                    metricSizeSummary
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    metricIdentity
                    Spacer()
                    metricSizeSummary
                }
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(metric.tint.color.gradient)
                            .frame(width: proxy.size.width * fraction)
                    }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(accessibilityValue)
    }

    private var metricIdentity: some View {
        HStack(spacing: 5) {
            Label(metric.title, systemImage: metric.systemImage)
                .font(.subheadline.weight(.semibold))
            Text("\(metric.itemCount)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private var metricSizeSummary: some View {
        HStack(spacing: 5) {
            OrganizeAnalysisMetricIndicator(
                isActive: isAnalysisRunning,
                hasPendingAnalysis: metric.hasPendingAnalysis,
                unavailableAssetCount: metric.unavailableAssetCount,
                failedAssetCount: metric.failedAssetCount
            )
            Text(OrganizeViewModel.byteString(metric.knownBytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(metric.knownBytes) / Double(total), 0), 1)
    }

    private var accessibilityValue: String {
        var parts = [
            "\(metric.itemCount) item\(metric.itemCount == 1 ? "" : "s")",
            "\(OrganizeViewModel.byteString(metric.knownBytes)) known size",
            "\(metric.processedAssetCount) of \(metric.itemCount) processed",
            "\(metric.analyzedAssetCount) of \(metric.itemCount) items sized"
        ]
        if isAnalysisRunning && metric.hasPendingAnalysis {
            parts.append("analysis in progress")
        }
        if metric.unavailableAssetCount > 0 {
            parts.append("\(metric.unavailableAssetCount) require iCloud")
        }
        if metric.failedAssetCount > 0 {
            parts.append("\(metric.failedAssetCount) failed")
        }
        return parts.joined(separator: ", ")
    }
}

struct OrganizeSectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .accessibilityAddTraits(.isHeader)
    }
}

struct OrganizeSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.separator.opacity(0.25), lineWidth: 0.5)
            }
    }
}

struct OrganizeActionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension OrganizeMetricTint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .orange: .orange
        case .green: .green
        case .gray: .gray
        }
    }
}
