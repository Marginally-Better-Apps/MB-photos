import SwiftUI

struct OrganizeProtectedAlbumsView: View {
    @ObservedObject var model: OrganizeViewModel

    var body: some View {
        List {
            Section {
                Text("Items in a protected album cannot be queued without an explicit per-item override. Changing this setting never changes the album in Apple Photos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Albums") {
                if model.albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums Available",
                        systemImage: "rectangle.stack",
                        description: Text("User-created albums visible to this app will appear here.")
                    )
                } else {
                    ForEach(model.albums) { album in
                        Toggle(
                            isOn: Binding(
                                get: { model.protectedAlbumIDs.contains(album.id) },
                                set: { isProtected in
                                    Task {
                                        await model.setAlbumProtected(
                                            album.id,
                                            isProtected: isProtected
                                        )
                                    }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title)
                                Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(model.isMovingToRecentlyDeleted)
                    }
                }
            }
        }
        .navigationTitle("Protected Albums")
        .navigationBarTitleDisplayMode(.inline)
    }
}
