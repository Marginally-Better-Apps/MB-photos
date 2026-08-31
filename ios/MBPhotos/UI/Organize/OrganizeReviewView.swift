import SwiftUI
import UIKit

struct OrganizeReviewZoomTransition {
    let sourceID: String
    let namespace: Namespace.ID
}

struct OrganizeReviewDeckView: View {
    @ObservedObject var model: OrganizeViewModel
    let recommendation: OrganizeRecommendationPresentation?
    let zoomTransition: OrganizeReviewZoomTransition?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var protectedAsset: OrganizeAssetPresentation?
    @State private var infoAsset: OrganizeAssetPresentation?
    @State private var actionFeedbackTrigger = 0
    @State private var warningFeedbackTrigger = 0
    @State private var completionFeedbackTrigger = 0
    @State private var showsCompletionMark = false
    @State private var isUndoingReviewChoice = false

    init(
        model: OrganizeViewModel,
        recommendation: OrganizeRecommendationPresentation?,
        zoomTransition: OrganizeReviewZoomTransition? = nil
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.recommendation = recommendation
        self.zoomTransition = zoomTransition
    }

    var body: some View {
        Group {
            if let session = model.activeReviewSession {
                if session.isComplete {
                    completionView(session)
                } else if let asset = model.currentReviewAsset() {
                    reviewView(session: session, asset: asset)
                } else {
                    ContentUnavailableView(
                        "Item Unavailable",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("The library changed while this review was open. Return to Organize and refresh.")
                    )
                }
            } else {
                ProgressView("Starting review…")
            }
        }
        .disabled(model.isMovingToRecentlyDeleted)
        .navigationTitle(model.activeReviewSession?.title ?? recommendation?.title ?? "Review")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .background {
            ShakeToUndoReader(isEnabled: canUndoReviewChoice) {
                undoLastReviewChoice()
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .organizeReviewZoomTransition(zoomTransition)
        .task(id: recommendation?.id) {
            if let recommendation { await model.beginReview(recommendation) }
        }
        .sheet(item: $infoAsset) { asset in
            OrganizeReviewInfoSheet(
                asset: asset,
                reason: model.activeReviewSession?.evidence(for: asset.id)
                    ?? recommendation?.evidence(for: asset.id)
                    ?? ""
            )
        }
        .sensoryFeedback(.selection, trigger: actionFeedbackTrigger)
        .sensoryFeedback(.warning, trigger: warningFeedbackTrigger)
        .sensoryFeedback(.success, trigger: completionFeedbackTrigger)
        .confirmationDialog(
            "Override Protection?",
            isPresented: Binding(
                get: { protectedAsset != nil },
                set: { if !$0 { protectedAsset = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Anyway", role: .destructive) {
                Task {
                    let accepted = await model.applyReviewChoice(
                        .queueForRecentlyDeleted,
                        allowProtected: true
                    )
                    protectedAsset = nil
                    if accepted { actionFeedbackTrigger += 1 }
                }
            }
            .disabled(model.isMovingToRecentlyDeleted)
            Button("Cancel", role: .cancel) {
                protectedAsset = nil
            }
        } message: {
            Text("\(protectedAsset?.protectionSummary ?? "This item") is protected by default. This override only adds it to the deletion queue.")
        }
    }

    private func reviewView(
        session: OrganizeReviewSessionPresentation,
        asset: OrganizeAssetPresentation
    ) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CARD \(session.completedCount + 1) OF \(session.assetIDs.count)")
                        .font(.caption2.weight(.heavy))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text("\(session.completedCount) reviewed")
                        .font(.headline.monospacedDigit())
                }
                ProgressView(
                    value: Double(session.completedCount),
                    total: Double(max(session.assetIDs.count, 1))
                )
                .tint(.indigo)
                Button {
                    undoLastReviewChoice()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.headline)
                        .frame(width: 38, height: 38)
                        .background(.background.secondary, in: Circle())
                }
                .accessibilityLabel("Undo")
                .accessibilityHint("Undoes the most recent review choice. You can also shake your device.")
                .disabled(!canUndoReviewChoice)
            }
            .padding(.horizontal)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.background.secondary)
                    .scaleEffect(0.92)
                    .offset(y: 14)
                    .opacity(0.45)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.background.secondary)
                    .scaleEffect(0.96)
                    .offset(y: 7)
                    .opacity(0.75)

                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.92)

                        OrganizeAssetPreviewView(model: model, asset: asset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if let protection = asset.protectionSummary {
                            Label(protection, systemImage: "lock.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.7), in: Capsule())
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(asset.originalFilename)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(session.evidence(for: asset.id))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            OrganizeAssetBadges(asset: asset)
                            Button {
                                infoAsset = asset
                            } label: {
                                Image(systemName: "info.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.indigo)
                                    .frame(width: 36, height: 36)
                                    .background(.indigo.opacity(0.1), in: Circle())
                            }
                            .accessibilityLabel("Photo information")
                        }

                        Divider()

                        OrganizeReviewItemDetailsView(asset: asset)
                    }
                    .padding(12)
                    .background(.background)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.separator.opacity(0.25), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
            }
            .padding(.horizontal, 10)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Keep") { choose(.keep, asset: asset) }
            .accessibilityAction(named: "Delete") { choose(.queueForRecentlyDeleted, asset: asset) }
            .accessibilityAction(named: "Review Later") { choose(.later, asset: asset) }

            HStack {
                OrganizeReviewActionButton(
                    title: "Delete",
                    systemImage: "trash.fill",
                    tint: .red,
                    accessibilityHint: "Adds this item to the deletion queue for final review",
                    action: { choose(.queueForRecentlyDeleted, asset: asset) }
                )

                Spacer()

                Button {
                    choose(.later, asset: asset)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "clock.fill")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.secondary.opacity(0.12), in: Circle())
                        Text("Later").font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Advances without marking the item reviewed")

                Spacer()

                OrganizeReviewActionButton(
                    title: "Keep",
                    systemImage: "checkmark",
                    tint: .green,
                    accessibilityHint: "Keeps this item and marks it reviewed",
                    action: { choose(.keep, asset: asset) }
                )
            }
            .padding(.horizontal, 34)

            Label("Delete only adds this item to the review queue.", systemImage: "shield.checkered")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)
        }
        .padding(.top, 8)
        .disabled(model.isMovingToRecentlyDeleted)
    }

    private func choose(_ choice: OrganizeReviewChoice, asset: OrganizeAssetPresentation) {
        guard !model.isMovingToRecentlyDeleted else { return }
        Task {
            let accepted = await model.applyReviewChoice(choice)
            if choice == .queueForRecentlyDeleted, !accepted, asset.isProtected {
                protectedAsset = asset
                warningFeedbackTrigger += 1
            } else if accepted {
                actionFeedbackTrigger += 1
            }
        }
    }

    private var canUndoReviewChoice: Bool {
        model.activeReviewSession?.undoStack.isEmpty == false
            && !model.isMovingToRecentlyDeleted
            && !isUndoingReviewChoice
            && infoAsset == nil
            && protectedAsset == nil
    }

    private func undoLastReviewChoice() {
        guard canUndoReviewChoice else { return }
        isUndoingReviewChoice = true
        Task { @MainActor in
            await model.undoLastReviewChoice()
            actionFeedbackTrigger += 1
            isUndoingReviewChoice = false
        }
    }

    private func completionView(_ session: OrganizeReviewSessionPresentation) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(.green.opacity(0.13))
                        .frame(width: 108, height: 108)
                    Image(systemName: "checkmark")
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .foregroundStyle(.green)
                }
                .scaleEffect(showsCompletionMark ? 1 : 0.72)
                .opacity(showsCompletionMark ? 1 : 0)

                Text("Stack Cleared!")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text("Nothing has left Apple Photos. Review the deletion queue before the final system confirmation.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                OrganizeSurface {
                    decisionCount("Keep", .keep, session: session, tint: .green)
                    Divider()
                    decisionCount("Delete", .queueForRecentlyDeleted, session: session, tint: .red)
                    Divider()
                    decisionCount("Later", .later, session: session, tint: .secondary)
                }
                if !model.queuedAssetIDs.isEmpty {
                    NavigationLink {
                        OrganizeQueueSummaryView(model: model)
                    } label: {
                        Label("Review Deletion Queue", systemImage: "trash.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding()
        }
        .onAppear {
            completionFeedbackTrigger += 1
            if reduceMotion {
                showsCompletionMark = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
                    showsCompletionMark = true
                }
            }
        }
    }

    private func decisionCount(
        _ title: String,
        _ choice: OrganizeReviewChoice,
        session: OrganizeReviewSessionPresentation,
        tint: Color
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(model.reviewDecisionCount(choice))")
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}

private struct ShakeToUndoReader: UIViewControllerRepresentable {
    let isEnabled: Bool
    let onShake: @MainActor () -> Void

    func makeUIViewController(context: Context) -> ShakeToUndoViewController {
        let controller = ShakeToUndoViewController()
        controller.isEnabled = isEnabled
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(
        _ controller: ShakeToUndoViewController,
        context: Context
    ) {
        controller.onShake = onShake
        controller.isEnabled = isEnabled
    }

    static func dismantleUIViewController(
        _ controller: ShakeToUndoViewController,
        coordinator: Void
    ) {
        controller.deactivate()
    }
}

@MainActor
final class ShakeToUndoViewController: UIViewController {
    var onShake: @MainActor () -> Void = {}
    var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            updateFirstResponderStatus()
        }
    }

    override var canBecomeFirstResponder: Bool { isEnabled }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateFirstResponderStatus()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        deactivate()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, isEnabled else {
            super.motionEnded(motion, with: event)
            return
        }
        onShake()
    }

    func deactivate() {
        if isFirstResponder {
            resignFirstResponder()
        }
    }

    private func updateFirstResponderStatus() {
        guard isViewLoaded, view.window != nil else { return }
        if isEnabled {
            becomeFirstResponder()
        } else {
            deactivate()
        }
    }
}

private struct OrganizeReviewActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let accessibilityHint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 64, height: 64)
                    .background(tint.opacity(0.13), in: Circle())
                Text(title)
                    .font(.subheadline.weight(.bold))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(accessibilityHint)
    }
}

private struct OrganizeReviewItemDetailsView: View {
    let asset: OrganizeAssetPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            detail(
                title: "Captured",
                value: asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown",
                systemImage: "calendar"
            )

            detailDivider

            detail(
                title: "Size",
                value: asset.knownBytes.map(OrganizeViewModel.byteString) ?? "Pending",
                systemImage: "internaldrive"
            )

            if asset.isVideo {
                detailDivider

                detail(
                    title: "Duration",
                    value: asset.durationMilliseconds.map(OrganizeViewModel.durationString) ?? "Unknown",
                    systemImage: "timer"
                )
            }
        }
    }

    private func detail(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var detailDivider: some View {
        Divider()
            .frame(height: 34)
            .padding(.horizontal, 8)
    }
}

private extension View {
    @ViewBuilder
    func organizeReviewZoomTransition(_ transition: OrganizeReviewZoomTransition?) -> some View {
        if let transition {
            navigationTransition(
                .zoom(sourceID: transition.sourceID, in: transition.namespace)
            )
        } else {
            self
        }
    }
}

private struct OrganizeReviewInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let asset: OrganizeAssetPresentation
    let reason: String

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(asset.originalFilename)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        OrganizeAssetBadges(asset: asset)
                    }
                    .padding(.vertical, 4)
                }

                Section("Details") {
                    LabeledContent(
                        "Captured",
                        value: asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
                    )
                    LabeledContent("Dimensions", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                    LabeledContent(
                        "Known size",
                        value: asset.knownBytes.map(OrganizeViewModel.byteString) ?? "Pending analysis"
                    )
                    LabeledContent("Albums", value: "\(asset.albumCount)")
                    if let format = asset.fileFormat {
                        LabeledContent("Format", value: format)
                    }
                    LabeledContent("Review state", value: asset.isReviewed ? "Reviewed" : "Unreviewed")
                }

                if let duration = asset.durationMilliseconds {
                    Section("Video") {
                        LabeledContent("Duration", value: OrganizeViewModel.durationString(duration))
                    }
                }

                if !asset.albumNames.isEmpty {
                    Section("Albums") {
                        ForEach(asset.albumNames, id: \.self) { name in
                            Label(name, systemImage: "rectangle.stack")
                        }
                    }
                }

                if let protection = asset.protectionSummary {
                    Section("Protection") {
                        Label("Protected by default: \(protection)", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Photo Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct OrganizeQueueSummaryView: View {
    @ObservedObject var model: OrganizeViewModel
    @State private var confirmingMove = false
    @State private var shouldMoveQueueAfterConfirmation = false

    var body: some View {
        List {
            if let session = model.activeReviewSession {
                decisionSection("Keep", choice: .keep, session: session)
                decisionSection("Later", choice: .later, session: session)
            }

            Section {
                if model.queuedAssets.isEmpty {
                    ContentUnavailableView(
                        "Queue Empty",
                        systemImage: "trash.slash",
                        description: Text("Choose Delete in a review to stage items here.")
                    )
                } else {
                    ForEach(model.queuedAssets) { asset in
                        queueRow(asset)
                    }
                }
            } header: {
                Text("Move to Recently Deleted (\(model.queuedAssets.count))")
            } footer: {
                if !model.queuedAssets.isEmpty {
                    Text("Known media bytes: \(OrganizeViewModel.byteString(model.queueKnownBytes)). Actual device space is managed by Apple Photos and is not guaranteed.")
                }
            }

            if !model.queuedAssets.isEmpty {
                Section {
                    Button(role: .destructive) { confirmingMove = true } label: {
                        HStack {
                            Spacer()
                            if model.isMovingToRecentlyDeleted {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text("Move \(model.queuedAssets.count) Items to Recently Deleted")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(model.isMovingToRecentlyDeleted)
                } footer: {
                    Text("Afterward, permanently remove them yourself in Apple Photos › Utilities › Recently Deleted. This app cannot inspect, restore, or empty that system collection.")
                }
            }
        }
        .navigationTitle("Queue Summary")
        .fullScreenCover(isPresented: $confirmingMove, onDismiss: moveQueueAfterConfirmation) {
            OrganizeMoveConfirmationView(itemCount: model.queuedAssets.count) {
                shouldMoveQueueAfterConfirmation = true
                confirmingMove = false
            }
        }
        .alert(item: $model.userMessage) { message in
            Alert(title: Text(message.title), message: Text(message.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private func decisionSection(
        _ title: String,
        choice: OrganizeReviewChoice,
        session: OrganizeReviewSessionPresentation
    ) -> some View {
        let ids = model.reviewDecisionIDs(choice)
        if !ids.isEmpty {
            Section("\(title) (\(ids.count))") {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(ids, id: \.self) { id in
                            if let asset = model.asset(id: id) {
                                OrganizeThumbnailView(model: model, asset: asset, size: CGSize(width: 84, height: 84))
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func queueRow(_ asset: OrganizeAssetPresentation) -> some View {
        HStack(spacing: 12) {
            OrganizeThumbnailView(model: model, asset: asset, size: CGSize(width: 62, height: 62))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.originalFilename).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(asset.knownBytes.map(OrganizeViewModel.byteString) ?? "Size pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let protection = asset.protectionSummary {
                    Label(protection, systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Menu {
                Button("Keep and Mark Reviewed") {
                    Task { await model.keepQueuedAsset(asset.id) }
                }
                Button("Remove from Queue") {
                    Task { await model.removeFromQueue(asset.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("Edit \(asset.originalFilename)")
            .disabled(model.isMovingToRecentlyDeleted)
        }
    }

    private func moveQueueAfterConfirmation() {
        guard shouldMoveQueueAfterConfirmation else { return }
        shouldMoveQueueAfterConfirmation = false
        Task { await model.moveQueueToRecentlyDeleted() }
    }
}

private struct OrganizeMoveConfirmationView: View {
    let itemCount: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 88, height: 88)
                            .background(.red.opacity(0.12), in: Circle())

                        VStack(spacing: 10) {
                            Text("Move to Recently Deleted?")
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)
                            Text("You’re about to move \(itemCount) item\(itemCount == 1 ? "" : "s") from your library.")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        OrganizeSurface {
                            Text("The app will recheck every item, cache only a small 30-day audit thumbnail, and then ask Apple Photos to move the unchanged items to Recently Deleted.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
                }

                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    Text("Move \(itemCount) Item\(itemCount == 1 ? "" : "s")")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(itemCount == 0)
                .padding()
                .background(.bar)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Confirm Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }
}

struct OrganizeDuplicateGroupsView: View {
    @ObservedObject var model: OrganizeViewModel
    @State private var currentGroupIndex = 0
    @State private var reviewHistory: [OrganizeDuplicateReviewAction] = []
    @State private var didInitialize = false
    @State private var isUndoing = false

    var body: some View {
        Group {
            if model.duplicateGroups.isEmpty {
                ContentUnavailableView(
                    "No Exact Duplicates",
                    systemImage: "square.on.square",
                    description: Text("Complete library analysis to compare full resource manifests.")
                )
            } else if model.duplicateGroups.indices.contains(currentGroupIndex) {
                let group = model.duplicateGroups[currentGroupIndex]
                OrganizeDuplicateComparisonView(
                    model: model,
                    group: group,
                    groupNumber: currentGroupIndex + 1,
                    totalGroupCount: model.duplicateGroups.count,
                    canUndo: !reviewHistory.isEmpty && !isUndoing,
                    onQueued: { assetID in
                        reviewHistory.append(
                            OrganizeDuplicateReviewAction(groupID: group.id, assetID: assetID)
                        )
                        withAnimation(.snappy) {
                            currentGroupIndex = firstPendingGroupIndex(after: currentGroupIndex)
                        }
                    },
                    onUndo: undoLastChoice
                )
                .id(group.id)
            } else {
                duplicateReviewComplete
            }
        }
        .navigationTitle("Exact Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            currentGroupIndex = firstPendingGroupIndex(after: -1)
        }
    }

    private var duplicateReviewComplete: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 74, weight: .semibold))
                .foregroundStyle(.green)
            Text("Duplicates Reviewed")
                .font(.title2.weight(.bold))
            Text("Your choices are in the deletion queue for final review.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !reviewHistory.isEmpty {
                Button {
                    undoLastChoice()
                } label: {
                    Label("Undo Last Delete", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(isUndoing)
            }
        }
        .padding()
    }

    private func undoLastChoice() {
        guard !isUndoing, let action = reviewHistory.popLast() else { return }
        isUndoing = true
        Task {
            await model.removeFromQueue(action.assetID)
            if let restoredIndex = model.duplicateGroups.firstIndex(where: { $0.id == action.groupID }) {
                withAnimation(.snappy) {
                    currentGroupIndex = restoredIndex
                }
            }
            isUndoing = false
        }
    }

    private func firstPendingGroupIndex(after index: Int) -> Int {
        model.duplicateGroups.indices.first { candidateIndex in
            guard candidateIndex > index else { return false }
            return model.duplicateGroups[candidateIndex].assetIDs.allSatisfy {
                !model.queuedAssetIDs.contains($0)
            }
        } ?? model.duplicateGroups.count
    }
}

private struct OrganizeDuplicateReviewAction: Hashable {
    let groupID: String
    let assetID: String
}

private struct OrganizeDuplicateComparisonView: View {
    @ObservedObject var model: OrganizeViewModel
    let group: OrganizeDuplicateGroupPresentation
    let groupNumber: Int
    let totalGroupCount: Int
    let canUndo: Bool
    let onQueued: (String) -> Void
    let onUndo: () -> Void
    @State private var protectedAsset: OrganizeAssetPresentation?
    @State private var infoAsset: OrganizeAssetPresentation?
    private let comparisonColumns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                duplicateProgressHeader

                LazyVGrid(columns: comparisonColumns, alignment: .leading, spacing: 12) {
                    ForEach(Array(group.assetIDs.enumerated()), id: \.element) { index, id in
                        if let asset = model.asset(id: id) {
                            duplicateAssetCard(asset, copyNumber: index + 1)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .sheet(item: $infoAsset) { asset in
            OrganizeReviewInfoSheet(
                asset: asset,
                reason: "This Photos-library item has byte-identical media in this duplicate group."
            )
        }
        .confirmationDialog(
            "Override Protection?",
            isPresented: Binding(
                get: { protectedAsset != nil },
                set: { if !$0 { protectedAsset = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Queue Anyway", role: .destructive) {
                if let protectedAsset {
                    let assetID = protectedAsset.id
                    Task {
                        _ = await model.queueAssets(
                            [assetID],
                            allowProtected: true,
                            recommendationKind: .exactDuplicates
                        )
                        if model.queuedAssetIDs.contains(assetID) {
                            onQueued(assetID)
                        }
                    }
                }
                protectedAsset = nil
            }
            .disabled(model.isMovingToRecentlyDeleted)
            Button("Cancel", role: .cancel) { protectedAsset = nil }
        } message: {
            Text("This copy has protected library metadata. Adding it to the deletion queue still requires a separate final confirmation.")
        }
    }

    private var duplicateProgressHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GROUP \(groupNumber) OF \(totalGroupCount)")
                    .font(.caption2.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text("\(groupNumber - 1) reviewed")
                    .font(.headline.monospacedDigit())
            }

            ProgressView(
                value: Double(groupNumber - 1),
                total: Double(max(totalGroupCount, 1))
            )
            .tint(.indigo)

            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .background(.background.secondary, in: Circle())
            }
            .accessibilityLabel("Undo")
            .accessibilityHint("Returns to the previous duplicate group and removes its copy from the deletion queue")
            .disabled(!canUndo || infoAsset != nil || protectedAsset != nil)
        }
    }

    private func duplicateAssetCard(
        _ asset: OrganizeAssetPresentation,
        copyNumber: Int
    ) -> some View {
        let isQueued = model.queuedAssetIDs.contains(asset.id)

        return VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.background.secondary)
                    .scaleEffect(0.92)
                    .offset(y: 10)
                    .opacity(0.45)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.background.secondary)
                    .scaleEffect(0.96)
                    .offset(y: 5)
                    .opacity(0.75)

                VStack(spacing: 0) {
                    duplicateMedia(asset)

                    VStack(spacing: 9) {
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("COPY \(copyNumber)")
                                    .font(.caption2.weight(.heavy))
                                    .tracking(0.6)
                                    .foregroundStyle(.secondary)
                                Text(asset.originalFilename)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 2)

                            Button {
                                infoAsset = asset
                            } label: {
                                Image(systemName: "info.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(.indigo)
                                    .frame(width: 30, height: 30)
                                    .background(.indigo.opacity(0.1), in: Circle())
                            }
                            .accessibilityLabel("Photo information")
                        }

                        OrganizeAssetBadges(asset: asset, showsLivePhoto: false)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)

                        Divider()

                        duplicateDetails(asset)
                    }
                    .padding(10)
                    .background(.background)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    if isQueued {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.red, lineWidth: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.separator.opacity(0.25), lineWidth: 0.5)
                    }
                }
                .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
            }

            deletionChoiceButton(for: asset, isQueued: isQueued)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Copy \(copyNumber), \(asset.originalFilename)")
    }

    private func duplicateMedia(_ asset: OrganizeAssetPresentation) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.92)

            GeometryReader { proxy in
                OrganizeThumbnailView(
                    model: model,
                    asset: asset,
                    size: proxy.size,
                    contentMode: .fit
                )
            }

            if let protection = asset.protectionSummary {
                Label(protection, systemImage: "lock.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(7)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if asset.isLivePhoto {
                Image(systemName: "livephoto")
                    .accessibilityLabel("Live Photo")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.68), in: Circle())
                    .padding(7)
            } else if asset.isVideo {
                Image(systemName: "play.fill")
                    .accessibilityLabel("Video")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.68), in: Circle())
                    .padding(7)
            }
        }
    }

    private func duplicateDetails(_ asset: OrganizeAssetPresentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Date unknown",
                systemImage: "calendar"
            )
            Label(
                "\(asset.albumCount) album\(asset.albumCount == 1 ? "" : "s")",
                systemImage: "rectangle.stack"
            )
            Label(
                asset.knownBytes.map(OrganizeViewModel.byteString) ?? "Size pending",
                systemImage: "internaldrive"
            )
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func deletionChoiceButton(
        for asset: OrganizeAssetPresentation,
        isQueued: Bool
    ) -> some View {
        if isQueued {
            OrganizeReviewActionButton(
                title: "Undo",
                systemImage: "arrow.uturn.backward",
                tint: .red,
                accessibilityHint: "Removes this copy from the deletion queue",
                action: { Task { await model.removeFromQueue(asset.id) } }
            )
            .frame(maxWidth: .infinity)
            .disabled(model.isMovingToRecentlyDeleted)
        } else {
            OrganizeReviewActionButton(
                title: "Delete",
                systemImage: "trash.fill",
                tint: .red,
                accessibilityHint: canQueueAnotherCopy
                    ? "Adds this copy to the deletion queue for final review"
                    : "At least one copy must remain outside the deletion queue",
                action: {
                    Task {
                        let protected = await model.queueAssets(
                            [asset.id],
                            recommendationKind: .exactDuplicates
                        )
                        if !protected.isEmpty {
                            protectedAsset = asset
                        } else if model.queuedAssetIDs.contains(asset.id) {
                            onQueued(asset.id)
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity)
            .disabled(model.isMovingToRecentlyDeleted || !canQueueAnotherCopy)
        }
    }

    private var canQueueAnotherCopy: Bool {
        group.assetIDs.lazy.filter { !model.queuedAssetIDs.contains($0) }.count > 1
    }
}
