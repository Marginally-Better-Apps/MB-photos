import SwiftUI

struct OrganizeDeletedItemsView: View {
    @ObservedObject var model: OrganizeViewModel
    @State private var searchText = ""
    @State private var filteredBatches: [OrganizeDeletedBatchPresentation] = []
    @State private var completedQuery: OrganizeDeletedHistoryQuery?

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Audit history—not a live album")
                            .font(.subheadline.weight(.semibold))
                        Text("Confirmed moves are listed alongside any request whose result could not be recorded after an interruption. This app cannot see whether an item was restored or permanently cleared from Apple Photos’ Recently Deleted collection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                }
            }

            if filteredBatches.isEmpty, completedQuery == query {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Deleted Items" : "No Matching Records",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(searchText.isEmpty
                        ? "Confirmed moves to Recently Deleted and interrupted-result audit records will appear here."
                        : "Try a filename, media type, or recommendation name.")
                )
            } else {
                ForEach(filteredBatches) { batch in
                    Section {
                        ForEach(batch.records) { record in
                            NavigationLink {
                                OrganizeDeletedItemDetailView(model: model, record: record, batch: batch)
                            } label: {
                                deletedItemRow(record)
                            }
                        }
                    } header: {
                        HStack {
                            Text(batch.deletedAt.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text("\(batch.records.count) item\(batch.records.count == 1 ? "" : "s")")
                        }
                    } footer: {
                        Text(batch.photoKitResult)
                    }
                }
            }
        }
        .navigationTitle("Deleted Items")
        .searchable(text: $searchText, prompt: "Filename or recommendation")
        .task { await model.cleanExpiredThumbnails() }
        .task(id: query) {
            guard let next = await model.deletedBatches(for: query) else { return }
            filteredBatches = next
            completedQuery = query
        }
    }

    private var query: OrganizeDeletedHistoryQuery {
        model.deletedHistoryQuery(searchText: searchText)
    }

    private func deletedItemRow(_ record: OrganizeDeletedItemPresentation) -> some View {
        HStack(spacing: 12) {
            OrganizeDeletedThumbnailView(model: model, record: record, size: CGSize(width: 62, height: 62))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.originalFilename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(record.recommendationSource)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(record.status.label, systemImage: statusIcon(record.status))
                    .font(.caption2)
                    .foregroundStyle(record.status == .movedToRecentlyDeleted ? Color.green : Color.orange)
            }
            Spacer()
            if !record.hasLiveThumbnail {
                Image(systemName: "photo.badge.clock")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Thumbnail expired")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func statusIcon(_ status: OrganizeDeletedRecordStatus) -> String {
        status == .movedToRecentlyDeleted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
}

private struct OrganizeDeletedItemDetailView: View {
    @ObservedObject var model: OrganizeViewModel
    let record: OrganizeDeletedItemPresentation
    let batch: OrganizeDeletedBatchPresentation

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    OrganizeDeletedThumbnailView(model: model, record: record, size: CGSize(width: 220, height: 220))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    Spacer()
                }
                if record.hasLiveThumbnail, let expiration = record.thumbnailExpiresAt {
                    Text("The small audit thumbnail expires \(expiration.formatted(date: .abbreviated, time: .omitted)). Original media is never cached here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The 30-day audit thumbnail has expired. Permanent metadata remains below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Audit Result") {
                LabeledContent("Status", value: record.status.label)
                LabeledContent(
                    record.status == .movedToRecentlyDeleted ? "Moved" : "Requested",
                    value: record.deletedAt.formatted(date: .abbreviated, time: .shortened)
                )
                LabeledContent("Recommendation", value: record.recommendationSource)
                LabeledContent("Batch result", value: batch.photoKitResult)
            }

            Section("Original Item") {
                LabeledContent("Filename", value: record.originalFilename)
                LabeledContent("Media", value: record.mediaKind == .video ? "Video" : "Photo")
                LabeledContent("Captured", value: record.captureDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                LabeledContent("Dimensions", value: "\(record.pixelWidth) × \(record.pixelHeight)")
                if let duration = record.durationMilliseconds {
                    LabeledContent("Duration", value: OrganizeViewModel.durationString(duration))
                }
                LabeledContent("Known size", value: record.knownBytes.map(OrganizeViewModel.byteString) ?? "Unknown")
                if record.isLivePhoto { LabeledContent("Live Photo", value: "Yes") }
                if record.isRAW { LabeledContent("RAW", value: "Yes") }
                if record.isFavorite { LabeledContent("Favorite", value: "Yes") }
                if record.isHidden { LabeledContent("Hidden", value: "Yes") }
                if record.isEdited { LabeledContent("Edited", value: "Yes") }
            }

            Section("Source Audit Identifiers") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Local identifier").font(.caption).foregroundStyle(.secondary)
                    Text(record.sourceAssetID).font(.caption.monospaced()).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Source revision").font(.caption).foregroundStyle(.secondary)
                    Text(record.sourceRevision).font(.caption.monospaced()).textSelection(.enabled)
                }
            }

            Section {
                Text(record.status == .movedToRecentlyDeleted
                    ? "This record does not prove that the item is still in Recently Deleted. To restore or permanently remove it, use Apple Photos."
                    : "The app closed before it durably recorded Apple Photos’ response. This record does not claim the item moved. Check Apple Photos to verify the result.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Audit Record")
        .navigationBarTitleDisplayMode(.inline)
    }
}
