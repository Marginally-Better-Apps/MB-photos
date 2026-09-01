# Privacy

MB Photos is designed to work without an account, analytics, advertising, or a cloud service.

## iOS app

The iOS app requests Photo Library read/write access to list, organize, export, and—only after an app summary and Apple’s system confirmation—move selected assets to Apple Photos’ Recently Deleted collection. Review gestures and recommendations never delete automatically. The app supports the system limited-library mode. It requests camera access only to scan a receiver QR code and local-network access only to contact the paired Windows receiver.

The local database stores export jobs, source revision identifiers, destination identifiers, retry state, verification receipts, review decisions, analysis fingerprints, and a permanent audit of assets successfully moved to Recently Deleted. If the app closes before PhotoKit's result can be durably recorded, the staged metadata is retained as a clearly labeled “Result Not Recorded” audit entry and is never presented as a confirmed move. The audit is not a live copy of that system collection. A small app-private thumbnail may be retained for 30 days, is excluded from backup, and is then removed while the metadata record remains. Temporary export media is staged only as needed for transfer and is removed after verified commit or explicit job discard.

## Windows receiver

The receiver accesses only a library root and export destinations selected by the user. Current media is stored below `Master`; original resources, Live Photo motion, portable catalogs, thumbnails, completion reports, and resumable state are stored below `MB Photos Data`. Application diagnostics are stored locally and exclude photo filenames, album names, GPS data, and pairing credentials.

## Network use

Media transfer occurs directly between the two devices on the local network. No media, metadata, or diagnostics are sent to the project maintainers or another service.

Exact PhotoKit resources retain their embedded metadata, including location. MB Photos does not rewrite Master or archived resources to remove location because doing so would violate the byte-preservation guarantee.
