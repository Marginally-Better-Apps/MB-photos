import AVKit
@preconcurrency import Photos
import PhotosUI
import SwiftUI

struct OrganizeThumbnailView: View {
    @ObservedObject var model: OrganizeViewModel
    let asset: OrganizeAssetPresentation
    let size: CGSize
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var loadGeneration = UUID()

    var body: some View {
        ZStack {
            OrganizeMediaPlaceholder(mediaKind: asset.mediaKind)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: taskID) {
            let generation = UUID()
            loadGeneration = generation
            image = nil
            let loaded = await model.thumbnail(assetID: asset.id, size: size)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            image = loaded
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var taskID: MediaLoadKey {
        MediaLoadKey(assetID: asset.id, sourceRevision: asset.sourceRevision, size: size)
    }
    private var accessibilityLabel: String {
        var parts = [asset.mediaKind == .video ? "Video" : "Photo"]
        if let creationDate = asset.creationDate {
            parts.append(creationDate.formatted(date: .abbreviated, time: .omitted))
        }
        if asset.isFavorite { parts.append("Favorite") }
        if asset.isEdited { parts.append("Edited") }
        return parts.joined(separator: ", ")
    }
}

struct OrganizeAssetPreviewView: View {
    @ObservedObject var model: OrganizeViewModel
    let asset: OrganizeAssetPresentation
    var playsLivePhotos = false
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var livePhoto: PHLivePhoto?
    @State private var livePhotoPlaybackRequestID: UUID?
    @State private var attemptedVideoLoad = false
    @State private var loadGeneration = UUID()
    @State private var livePhotoLoadGeneration = UUID()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.94)
                if let player, asset.isVideo {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .onDisappear { player.pause() }
                } else if let livePhoto, asset.isLivePhoto, playsLivePhotos {
                    OrganizeLivePhotoPlaybackView(
                        livePhoto: livePhoto,
                        playbackRequestID: livePhotoPlaybackRequestID
                    )
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    OrganizeMediaPlaceholder(mediaKind: asset.mediaKind, dark: true)
                }

                if asset.isVideo, player == nil, attemptedVideoLoad {
                    VStack {
                        Spacer()
                        Label("Video preview unavailable", systemImage: "play.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding()
                    }
                }
            }
            .task(id: MediaLoadKey(assetID: asset.id, sourceRevision: asset.sourceRevision, size: proxy.size)) {
                let generation = UUID()
                loadGeneration = generation
                player?.pause()
                player = nil
                image = nil
                attemptedVideoLoad = false
                let loadedImage = await model.thumbnail(assetID: asset.id, size: proxy.size)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                image = loadedImage
                if asset.isVideo {
                    let loadedPlayer = await model.videoPlayer(assetID: asset.id)
                    guard !Task.isCancelled, generation == loadGeneration else {
                        loadedPlayer?.pause()
                        return
                    }
                    player = loadedPlayer
                    attemptedVideoLoad = true
                }
            }
            .task(id: MediaLoadKey(assetID: asset.id, sourceRevision: asset.sourceRevision, size: proxy.size)) {
                let generation = UUID()
                livePhotoLoadGeneration = generation
                livePhoto = nil
                livePhotoPlaybackRequestID = nil
                guard playsLivePhotos, asset.isLivePhoto else { return }

                let loadedLivePhoto = await model.livePhoto(assetID: asset.id, size: proxy.size)
                guard !Task.isCancelled, generation == livePhotoLoadGeneration else { return }
                livePhoto = loadedLivePhoto
                guard loadedLivePhoto != nil else { return }

                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !Task.isCancelled, generation == livePhotoLoadGeneration else { return }
                livePhotoPlaybackRequestID = UUID()
            }
        }
        .accessibilityLabel(asset.isVideo ? "Video preview" : asset.isLivePhoto ? "Live Photo preview" : "Photo preview")
        .accessibilityHint(asset.isLivePhoto && playsLivePhotos ? "Press and hold to replay the Live Photo" : "")
    }
}

private struct OrganizeLivePhotoPlaybackView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let playbackRequestID: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.livePhoto = livePhoto
        view.contentMode = .scaleAspectFit
        view.isMuted = false

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.replay(_:))
        )
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 20
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
        }
        guard let playbackRequestID,
              context.coordinator.lastPlaybackRequestID != playbackRequestID else { return }
        context.coordinator.lastPlaybackRequestID = playbackRequestID
        view.stopPlayback()
        view.startPlayback(with: .full)
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        view.livePhoto = nil
    }

    final class Coordinator: NSObject {
        var lastPlaybackRequestID: UUID?

        @MainActor @objc func replay(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view as? PHLivePhotoView else { return }
            switch gesture.state {
            case .began:
                view.stopPlayback()
                view.startPlayback(with: .full)
            case .ended, .cancelled, .failed:
                view.stopPlayback()
            default:
                break
            }
        }
    }
}

struct OrganizeDeletedThumbnailView: View {
    @ObservedObject var model: OrganizeViewModel
    let record: OrganizeDeletedItemPresentation
    let size: CGSize
    @State private var image: UIImage?
    @State private var loadGeneration = UUID()

    var body: some View {
        ZStack {
            OrganizeMediaPlaceholder(mediaKind: record.mediaKind)
            if record.hasLiveThumbnail, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: taskID) {
            let generation = UUID()
            loadGeneration = generation
            image = nil
            guard record.hasLiveThumbnail else {
                return
            }
            let loaded = await model.deletedThumbnail(recordID: record.id, size: size)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            image = loaded
        }
        .accessibilityLabel(record.hasLiveThumbnail ? "Cached audit thumbnail" : "Thumbnail expired")
    }

    private var taskID: DeletedMediaLoadKey {
        DeletedMediaLoadKey(
            recordID: record.id,
            sourceRevision: record.sourceRevision,
            thumbnailExpiresAt: record.thumbnailExpiresAt,
            size: size
        )
    }
}

private struct MediaLoadKey: Hashable {
    let assetID: String
    let sourceRevision: String
    let size: CGSize
}

private struct DeletedMediaLoadKey: Hashable {
    let recordID: UUID
    let sourceRevision: String
    let thumbnailExpiresAt: Date?
    let size: CGSize
}

struct OrganizeMediaPlaceholder: View {
    let mediaKind: MediaKind
    var dark = false

    var body: some View {
        ZStack {
            Rectangle().fill(dark ? Color.white.opacity(0.08) : Color.secondary.opacity(0.12))
            Image(systemName: mediaKind == .video ? "video.fill" : "photo.fill")
                .font(.title2)
                .foregroundStyle(dark ? Color.white.opacity(0.55) : Color.secondary.opacity(0.65))
        }
    }
}

struct OrganizeAssetBadges: View {
    let asset: OrganizeAssetPresentation
    var showsLivePhoto = true

    var body: some View {
        HStack(spacing: 4) {
            if asset.isVideo { badge("video.fill", text: nil) }
            if asset.isLivePhoto, showsLivePhoto { badge("livephoto", text: nil) }
            if asset.isRAW { badge("camera.aperture", text: "RAW") }
            if asset.isFavorite { badge("heart.fill", text: nil) }
            if asset.isEdited { badge("slider.horizontal.3", text: nil) }
            if asset.isHidden { badge("eye.slash.fill", text: nil) }
        }
        .accessibilityElement(children: .combine)
    }

    private func badge(_ systemImage: String, text: String?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            if let text { Text(text) }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(0.62), in: Capsule())
    }
}

extension OrganizeSortDirection {
    var organizeLabel: String { self == .ascending ? "Ascending" : "Descending" }
    var organizeSystemImage: String { self == .ascending ? "arrow.up" : "arrow.down" }
}
