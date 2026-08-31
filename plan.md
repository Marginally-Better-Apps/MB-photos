# The product should be a **power layer over Apple Photos**

Trying to replace every part of Apple Photos immediately would make the project enormous. Apple already provides timeline browsing, people/place/object search, duplicate detection, editing, memories, sharing, and iCloud synchronization. ([App Store][1])

Your app’s clearer promise should be:

> **Review thousands of photos quickly, organize the keepers properly, and export a verified, portable copy to any computer—locally, privately, and without subscriptions or artificial limits.**

That combines the strongest parts of several app categories:

* Swipewipe provides month-by-month swipe review, bookmarks, screenshots/similar-photo cleanup, maps, and progress tracking. ([App Store][2])
* Slidebox adds one-tap album assignment, favorite gestures, comparison, and undo. ([App Store][3])
* HashPhotos demonstrates demand for smart albums, keywords, ratings, metadata filters, comparison tools, batch operations, and album-preserving export—but many capabilities are limited in its free tier. ([HashPhotos][4])
* Transfer apps demonstrate the need for Windows-compatible conversion, full-resolution local transfer, metadata preservation, and album/folder structures. ([App Store][5])

## Minimum useful release

### 1. Fast photo library and viewer

The app must first be pleasant enough to use as an everyday gallery.

| Functionality      | What it should do                                                                                                                                                                      |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Timeline grid      | Group by day, month, and year, with extremely fast scrolling and a date scrubber.                                                                                                      |
| Adjustable grid    | Pinch to change thumbnail size; compact, square, natural-aspect, and justified layouts.                                                                                                |
| Full-screen viewer | Smooth pinch zoom, double-tap zoom, video scrubbing, Live Photo playback, GIF support, and swipe navigation.                                                                           |
| Media support      | Photos, videos, screenshots, Live Photos, RAW/ProRAW, RAW+JPEG pairs, bursts, panoramas, portrait photos, HDR, slow-motion, and cinematic video.                                       |
| Thumbnail badges   | Show video duration, file size, RAW, Live, HDR, edited, favorite, cloud-only, screenshot, and album status.                                                                            |
| Information panel  | Filename, format, dimensions, file size, capture date, location, camera, lens, exposure settings, duration, album memberships, and whether an original must be downloaded from iCloud. |
| Sorting            | Newest, oldest, filename, size, duration, resolution, camera, and date added.                                                                                                          |
| Filtering          | Photos, videos, screenshots, RAW, Live Photos, favorites, hidden, edited, large files, and items not in an album.                                                                      |

A major differentiator would be letting users display useful metadata directly beneath thumbnails instead of repeatedly opening an information sheet.

---

### 2. Swipe-based review mode

This should be the flagship workflow.

#### Default gestures

* **Swipe right:** Keep and mark reviewed.
* **Swipe left:** Queue for deletion.
* **Swipe up:** Add to album.
* **Swipe down:** Favorite.
* **Tap:** Skip for now.
* **Long press:** Open metadata or comparison mode.

Gestures should be customizable because different cleanup apps train users differently.

#### Review session types

Users should be able to start a session from:

* A particular month, day, trip, album, or date range.
* Screenshots.
* Large videos.
* Bursts.
* Exact duplicates.
* Similar photos.
* Blurry or dark photos.
* Downloads and messaging images.
* Unorganized photos.
* Photos not previously reviewed.
* Photos not previously exported.
* “On this day.”
* A small daily batch such as 20 or 50 photos.

#### Session functionality

* Save progress and resume later.
* Show `143 of 624 reviewed`.
* Show estimated storage selected for deletion.
* Bookmark or mark “decide later.”
* Undo and redo every action.
* Jump backward without losing decisions.
* Protect favorites, hidden photos, edited photos, or selected albums.
* Let the user change decisions from a summary screen.
* Never delete immediately during swiping.

The last screen should divide everything into **Keep**, **Delete**, **Uncertain**, and **Organized**, with one final confirmation before PhotoKit receives the deletion request.

---

### 3. Strong deletion safety

A cleaner app is useless if users do not trust it.

Required protections:

* Maintain an app-level deletion queue before touching the system library.
* Clearly distinguish **Remove from Album** from **Delete from Library**.
* Warn when an item is in multiple albums.
* Warn when deleting RAW+JPEG pairs, Live Photos, or edited assets.
* Offer “protect this album from cleanup.”
* Never automatically delete something merely because an algorithm considers it blurry or duplicate.
* Keep an internal history of actions taken during each session.
* Show exactly how much storage is expected to be reclaimed.
* Support “export and verify before deleting.”

Because actual system-library deletion is performed through PhotoKit, your app should stage decisions and then submit a controlled batch request rather than pretending it has unrestricted filesystem access. Apple exposes library creation, modification, and deletion through PhotoKit change requests. ([Apple Developer][6])

---

### 4. Much better organization

This is where the app can become more than another swipe cleaner.

#### Albums

* One-tap album bar beneath the viewer.
* Add one photo to multiple albums.
* Create a new album without leaving the current photo.
* Pin frequently used albums.
* Show recent destination albums.
* Batch-add selected photos.
* Rename, merge, reorder, and manage albums.
* Change album cover.
* Show album membership directly in the viewer.
* Temporary “tray” where users collect photos before applying an action.

#### “Unorganized” inbox

Create a computed collection containing photos that are not assigned to any user-created album.

Useful variations:

* Not in any album.
* Not tagged.
* Not reviewed.
* Not exported.
* Favorite but not organized.
* Recently imported but not organized.

HashPhotos includes a similar “Uncategorized Album,” which is a strong indication that this solves a genuine Apple Photos organizational gap. ([HashPhotos][4])

#### App-level organization

Support metadata that Apple does not conveniently expose to third-party apps:

* Keywords and tags.
* One-to-five-star ratings.
* Color labels or flags.
* Notes.
* Review status.
* Export status.
* Protected status.
* Project or collection membership.

#### Smart albums

Let users build rules such as:

* Screenshots older than 30 days.
* Videos larger than 500 MB.
* Photos from a particular camera.
* Favorites not assigned to an album.
* RAW photos taken in 2025.
* Photos within five miles of a location.
* Items tagged `work` but not `exported`.
* Photos with no location.
* Photos reviewed but not organized.
* Edited photos created this month.

Support `AND`, `OR`, and `NOT`, ranges, and saved reusable filters.

---

### 5. Comparison and duplicate handling

Deletion tools should not simply say “these look similar.”

#### Exact duplicates

* Compute file or resource hashes.
* Group byte-identical assets.
* Explain why they are considered duplicates.
* Show resolution, format, file size, edit status, album membership, and metadata differences.
* Let users choose the keeper manually.
* Offer a recommended keeper based on original quality.
* Preserve the union of album memberships, tags, ratings, and favorite status before deleting copies where possible.

#### Similar photos

* Perceptual similarity detection.
* Burst and rapid-shot grouping.
* Screenshot duplicates with different crops or compression.
* Cropped, resized, or recompressed versions of the same image.
* Repeated images saved from messaging apps.

#### Comparison interface

* Two-to-four photos side by side.
* Synchronized pan and zoom.
* Blink between two images.
* Show resolution, file size, sharpness, faces, and date.
* Full-resolution focus inspection.
* Select best, keep several, or delete all.
* Never hide the original from the recommendation.

Duplicate detection, visual similarity, comparison, and bulk deletion are among the power features limited in competing products, so making them unrestricted would be a meaningful FOSS advantage. ([HashPhotos][4])

---

### 6. Powerful search

Start with deterministic filters before attempting large AI features.

#### Initial search

* Date and date range.
* Album.
* Tag, rating, flag, and note.
* File type and media type.
* Filename.
* File size.
* Resolution and aspect ratio.
* Video duration.
* Camera and lens.
* Aperture, ISO, focal length, and exposure.
* Location and distance from a location.
* Favorite, hidden, edited, reviewed, organized, and exported.
* Album count or “not in album.”
* Multiple filters at once.
* Search within the current album.

#### Later search

* OCR text inside screenshots, documents, and signs.
* On-device object and scene recognition.
* Natural-language semantic search.
* People and face clustering.
* Search by visually similar image.

On-device OCR would be especially useful because screenshots and photographed documents are often hard to locate through normal metadata.

---

## Export and transfer should be a first-class feature

This may be your strongest differentiator because cleanup apps generally treat transfer as an afterthought, while transfer apps usually do not offer serious organization.

### 7. Export choices

For every export, make the choice explicit:

* **Unmodified original.**
* **Current edited version.**
* **Original and edited version.**
* **Compatibility copy.**

Special media should have appropriate options:

| Asset                 | Export options                                               |
| --------------------- | ------------------------------------------------------------ |
| Live Photo            | Original image plus MOV, still image only, or rendered video |
| RAW+JPEG              | RAW only, JPEG only, or both                                 |
| HEIC                  | Original HEIC or converted JPEG                              |
| HEVC video            | Original or H.264 MP4                                        |
| ProRes video          | Original or compatible transcoded copy                       |
| Slow-motion/Cinematic | Original resources or rendered playback version              |
| Edited photo          | Current rendered image plus optional untouched original      |

PhotoKit represents an asset as potentially having several underlying resources, including original and edited components, so the export model should be resource-aware rather than treating every photo as one JPEG. ([Apple Developer][7])

Never silently convert, recompress, strip metadata, or replace an original.

---

### 8. Export destinations

The initial release should support:

* Files app destinations.
* External SSD or USB storage exposed through Files.
* Share sheet.
* Local Wi-Fi browser transfer.
* ZIP archive for smaller selections.

The local Wi-Fi interface could let the user open a one-time address or QR code on Windows, macOS, or Linux and download albums without installing software.

Later targets:

* SMB shares and Windows folders.
* NAS devices.
* WebDAV.
* SFTP.
* Self-hosted Immich or PhotoPrism.
* Ente.
* S3-compatible storage.
* Optional open-source desktop receiver.

Existing apps show that local Wi-Fi transfer, Windows-compatible HEIC/HEVC conversion, full-resolution metadata-preserving export, and album preservation are valuable enough to be sold separately. ([App Store][5])

---

### 9. Export structure and naming

Users should be able to configure folder templates:

```text
Photos/
  2026/
    2026-08/
      2026-08-23/
```

Or:

```text
Albums/
  Kitten/
  Work/
  Trips/
    Chicago/
```

Naming templates should support:

```text
{capture-date}_{capture-time}_{original-name}
{year}-{month}-{day}_{sequence}
{album}_{date}_{sequence}
```

Additional controls:

* Preserve original filename.
* Sanitize invalid Windows characters.
* Select time zone behavior.
* Keep album hierarchy.
* Put assets belonging to multiple albums into each folder, use links where supported, or export once with a manifest.
* Skip, rename, overwrite, or compare conflicts.
* Preserve capture timestamps.
* Include or remove location metadata.
* Write app keywords and ratings into IPTC/XMP sidecars.
* Produce CSV or JSON manifests.

---

### 10. Incremental and verified backup

A serious export feature needs more than a progress bar.

* Track which assets were previously exported.
* Detect newly added, edited, or deleted assets.
* Export only new or changed items.
* Save export profiles such as “Windows PC backup” or “NAS originals.”
* Resume interrupted transfers.
* Retry failed files individually.
* Verify file size and cryptographic checksum.
* Produce a completion report.
* Record destination, filename, checksum, export date, and export format.
* Mark a backup complete only after verification.
* Offer deletion from the iPhone only after successful verification.
* Reconcile changes made while the app was closed.

Apple’s PhotoKit change-history API can report asset, album, and folder insertions, modifications, and deletions across launches, which is ideal for incremental indexing and export. ([Apple Developer][8])

---

## Useful second-release features

Once the core workflow is reliable, add:

| Area              | Features                                                                                                 |
| ----------------- | -------------------------------------------------------------------------------------------------------- |
| Storage dashboard | Photos versus videos versus RAW, largest items, screenshots, duplicates, and estimated reclaimable space |
| Calendar and map  | Browse an entire library or album by date and location                                                   |
| Batch metadata    | Adjust capture date, time zone, location, title, rating, tags, and privacy metadata                      |
| Import            | Import from Files or a computer while preserving date, location, filenames, and album destination        |
| Format tools      | Resize, convert, compress, extract video frames, and convert Live Photos                                 |
| Shortcuts         | Start a cleanup session, export new photos, open unorganized items, or transfer a specific album         |
| Share extension   | Add a photo to an album, tag it, or send it through an export profile from another app                   |
| iPad support      | Keyboard shortcuts, drag and drop, multi-column layout, and external-display viewer                      |
| Accessibility     | VoiceOver, Dynamic Type, haptic controls, gesture alternatives, and color-independent status indicators  |

Compression should remain optional and separate from cleanup. The app should never replace an original with a smaller copy without a clear export or backup step.

---

## Later features—not MVP requirements

These could eventually make the app a broader FOSS Photos platform:

* On-device OCR indexing.
* Local semantic search with an open Core ML model.
* Optional local face recognition and people clustering.
* Best-shot recommendations using blur, eyes-open, exposure, and composition signals.
* Cross-device synchronization of tags and review state.
* Windows, macOS, and Linux desktop applications.
* Self-hosted encrypted backup server.
* Public or password-protected album sharing.
* Collaborative albums.
* Private vault.
* Full photo and video editor.
* Memories, slideshows, and widgets.
* Plugin architecture for backup destinations.

Face recognition, cloud synchronization, and a full editor should wait. They are large projects and are not necessary to make the initial app genuinely valuable.

## Important iOS limitations to design around

### Apple Photos remains the source of truth

Use PhotoKit to display and modify the system library. Do not copy every original into your app’s sandbox unless the user deliberately creates a private local library.

### Full versus limited access

The app must gracefully support limited-library permission, but complete organization and cleanup requires read/write PhotoKit access. Apple separately defines add-only and read/write access levels. ([Apple Developer][9])

### Custom metadata needs its own catalog

Tags, ratings, notes, review state, smart-album definitions, and export history should live in an app database. HashPhotos similarly stores keywords, memos, and other management information locally and writes keywords into IPTC metadata during export because Apple restricts third-party access to parts of its keyword system. ([HashPhotos][10])

Therefore:

* Make the catalog exportable as JSON, CSV, and XMP.
* Back it up automatically or let users choose a location.
* Do not lock metadata inside an opaque database.
* Do not rely solely on the PhotoKit local identifier; maintain fingerprints and recovery matching because identifiers can change after assets are re-imported or re-downloaded. ([HashPhotos][10])

### Some Apple collections are unavailable

Existing third-party implementations document that iOS does not expose the system Recently Deleted collection or Apple’s People & Pets album to them. Your app may need its own face analysis later, and its deletion queue must exist before system deletion rather than trying to manage Recently Deleted afterward. ([HashPhotos][10])

## Recommended app structure

A clean four-tab interface would cover nearly everything:

1. **Library** — timeline, viewer, search, maps, and metadata.
2. **Review** — swipe sessions, duplicates, screenshots, large files, and cleanup progress.
3. **Organize** — albums, tags, ratings, smart albums, unorganized inbox, and tray.
4. **Transfer** — exports, saved backup profiles, history, verification, and imports.

Search can remain globally accessible from the Library rather than becoming a fifth tab.

## Best initial build order

1. PhotoKit indexing and a high-performance timeline.
2. Full-screen viewer and metadata panel.
3. Swipe review with persistent state, undo, and final confirmation.
4. One-tap album assignment and unorganized-photo view.
5. Bulk actions and deterministic filters.
6. Original export to Files.
7. Local browser transfer to Windows/macOS/Linux.
8. Folder and filename templates.
9. Incremental export with checksums and resumability.
10. Exact duplicates, similar-photo comparison, and storage analysis.
11. Tags, ratings, smart albums, and metadata sidecars.
12. OCR and other on-device intelligence.

A genuinely useful first public release should let someone with 20,000 photos select a month, rapidly review it, safely delete unwanted items, assign the keepers to albums, and export all new originals to a Windows PC in a predictable folder structure—with preserved metadata, resume support, and verification. That alone would combine the most valuable parts of several paid apps into one focused FOSS tool.

[1]: https://apps.apple.com/us/app/photos/id1584215428 "‎Photos App - App Store"
[2]: https://apps.apple.com/us/app/swipewipe-photo-cleaner/id1583884012 "‎Swipewipe: Photo Cleaner App - App Store"
[3]: https://apps.apple.com/us/app/slidebox-photo-cleaner-app/id984305203 "‎Slidebox: Photo Cleaner App App - App Store"
[4]: https://www.hashphotos.app/features/free_vs_pro/ "HashPhotos Free vs Pro Features Comparison"
[5]: https://apps.apple.com/us/app/simple-transfer-photo-video/id420821506 "‎Simple Transfer - Photo+Video App - App Store"
[6]: https://developer.apple.com/documentation/photos/phassetchangerequest/deleteassets%28_%3A%29?utm_source=chatgpt.com "deleteAssets(_:) | Apple Developer Documentation"
[7]: https://developer.apple.com/documentation/photos/phassetresourcemanager?utm_source=chatgpt.com "PHAssetResourceManager | Apple Developer Documentation"
[8]: https://developer.apple.com/videos/play/wwdc2022/10132/ "Discover PhotoKit change history - WWDC22 - Videos - Apple Developer"
[9]: https://developer.apple.com/documentation/PhotoKit/delivering-an-enhanced-privacy-experience-in-your-photos-app?language=objc&utm_source=chatgpt.com "Delivering an Enhanced Privacy Experience in Your Photos App"
[10]: https://www.hashphotos.app/faq/ "FAQ - HashPhotos"
