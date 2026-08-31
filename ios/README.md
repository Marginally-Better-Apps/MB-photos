# MB Photos for iOS

The iOS 18+ client organizes the user's PhotoKit library, stages review decisions locally, moves only explicitly confirmed items to Apple Photos’ Recently Deleted collection, and sends exact original resources plus optional current JPEG renditions to the paired Windows receiver.

## Generate and build

```sh
cd ios
xcodegen generate
xcodebuild -project MBPhotos.xcodeproj -scheme MBPhotos \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Open `MBPhotos.xcodeproj` to run on an iPhone. A physical device is required for camera QR scanning, PhotoKit/iCloud behavior, and local-network transfer testing. The app also accepts a pasted pairing URL in debug/manual environments.

The durable local ledger uses GRDB 7 over SQLite with named, transactional migrations. Xcode resolves the pinned Swift package version when the project is first opened or built.

## Safety boundary

Review gestures never mutate PhotoKit. They only update a durable app-level queue. After a separate summary and final action, the app submits one `PHPhotoLibrary.performChanges` request; Apple Photos provides the confirmation and moves successful items to Recently Deleted. Third-party apps cannot browse, restore, permanently clear, or determine the current contents of that system collection.

The app keeps a permanent metadata audit of successful moves and a small private thumbnail for 30 days. If the process ends before PhotoKit's response can be journaled, the prepared snapshot is surfaced as Result Not Recorded instead of being hidden or called successful, and the user is directed to verify it in Apple Photos. Export staging remains separate and is removed after a verified receiver commit or explicit local job discard.

## Background work

Background execution is opportunistic, not a promise that analysis will run at a particular time. iOS chooses when scheduled work launches and may suspend or terminate the app. Every analysis item is therefore committed with its durable cursor before progress advances, and every task installs an expiration handler that cancels/checkpoints before reporting completion.

MB Photos uses each API for a narrow purpose:

- `BGAppRefreshTask` refreshes PhotoKit/library metadata only. Apple describes this as short work with up to about 30 seconds of runtime; it never hashes photo resources.
- `BGProcessingTask` resumes an already requested analysis or performs deferred local maintenance. Stable identifiers give each class one outstanding request because resubmitting an unexecuted request with the same identifier replaces it.
- On iOS 26+, `BGContinuedProcessingTask` is requested only from a direct user action (starting analysis or a verified export), using the fail-immediately strategy. Automatic maintenance never uses continued processing. On iOS 18–25, user analysis can resume through discretionary processing; export only uses finite cleanup time and pauses at a receiver-acknowledged chunk.

The power policy reflects the cost of reading and hashing every PhotoKit resource: for a large library this can produce substantial storage I/O, CPU use, heat, and—if the person explicitly includes iCloud items—network traffic.

- User-started analysis may run on battery under nominal or fair thermal conditions. It checkpoints and shows paused/waiting state in Low Power Mode or at serious/critical thermal state.
- Automatic analysis is local-only, requests external power, never requests network connectivity, and may run under nominal or fair thermal conditions. It defers in Low Power Mode or at serious/critical thermal state. An interrupted automatic request is resubmitted only while its durable cursor still has local work remaining; selecting changed/stale assets stays coordinator-owned when a fresh maintenance launch runs.
- The app observes power and thermal notifications while alive. A constraint transition cancels the active analyzer and waits for its durable pause checkpoint; scheduled/waiting work is never presented as running.

PhotoKit work always remains within the person's current full or limited authorization. Authorization is obtained in the foreground with a purpose string; a background handler does not prompt for broader access. Automatic work cannot download an iCloud-only original. Logical resource totals also should not be described as device disk usage because Optimized Storage can keep an original only in iCloud.

For App Review, keep the Background Modes declarations and review notes tied to these visible photo-organization features. Apple requires efficient power use (Guideline 2.4.2), background services used only for their intended purpose (2.5.4), and clear permission/data-use and retention disclosures for Photos data (5.1.1). Moving items to Recently Deleted remains foreground-only.

Primary Apple references: [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app), [using background tasks](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app), [`BGProcessingTaskRequest`](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest), [`requiresExternalPower`](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest/requiresexternalpower), [long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados), [responding to power notifications](https://developer.apple.com/documentation/xcode/responding-to-power-notifications), [PhotoKit privacy and authorization](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app), and the [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
