import SwiftUI
import UIKit

struct DiagnosticLogPreview: Equatable, Sendable {
    static let maximumCharacterCount = 8_192
    private static let omissionMarker = "[Earlier diagnostics omitted from this preview]\n"

    let text: String
    let isTruncated: Bool

    static func make(
        from fullText: String,
        maximumCharacterCount: Int = DiagnosticLogPreview.maximumCharacterCount
    ) -> DiagnosticLogPreview {
        let limit = max(maximumCharacterCount, 0)
        guard fullText.count > limit else {
            return DiagnosticLogPreview(text: fullText, isTruncated: false)
        }

        let suffix = fullText.suffix(limit)
        let visibleSuffix: Substring
        if let firstNewline = suffix.firstIndex(of: "\n") {
            visibleSuffix = suffix[suffix.index(after: firstNewline)...]
        } else {
            visibleSuffix = suffix
        }
        return DiagnosticLogPreview(
            text: omissionMarker + visibleSuffix,
            isTruncated: true
        )
    }
}

struct DiagnosticsView: View {
    @ObservedObject var store: CrashLogStore

    @State private var completeLogText = ""
    @State private var logPreview = DiagnosticLogPreview(text: "", isTruncated: false)
    @State private var storedByteCount = 0
    @State private var persistenceError: String?
    @State private var showingCopiedConfirmation = false
    @State private var showingClearConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Crash and debug log", systemImage: "stethoscope")
                            .font(.headline)
                        Text("Includes recent app events, errors, environment details, and Apple crash diagnostics when iOS delivers them. Crash reports can arrive on a later launch.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("The log stays on this device and is capped at 1 MB. Pairing secrets and photo contents are not intentionally recorded.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button {
                                copyLatestLog()
                            } label: {
                                Label("Copy Log", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderedProminent)

                            ShareLink(
                                item: completeLogText,
                                subject: Text("MB Photos diagnostics"),
                                message: Text("MB Photos crash and debug log")
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .disabled(completeLogText.isEmpty)
                        }

                        LabeledContent(
                            "Stored events",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(storedByteCount),
                                countStyle: .file
                            )
                        )
                        .font(.caption)
                    }
                }

                if let persistenceError {
                    Label(
                        "The saved log could not be read: \(persistenceError)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                if logPreview.isTruncated {
                    Label(
                        "Showing the newest log entries. Copy or Share includes the complete log.",
                        systemImage: "text.badge.ellipsis"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(logPreview.text.isEmpty ? "Loading diagnostics…" : logPreview.text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Diagnostic log")
            }
            .padding()
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear Log", systemImage: "trash")
                }
            }
        }
        .task(id: store.revision) {
            await reload()
        }
        .alert("Log copied", isPresented: $showingCopiedConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The complete diagnostics log is on the clipboard.")
        }
        .confirmationDialog(
            "Clear the diagnostic log?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Log", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing events and delivered crash reports will be removed from this device.")
        }
    }

    private func reload() async {
        let snapshot = await store.snapshot()
        guard !Task.isCancelled else { return }
        apply(snapshot)
    }

    private func copyLatestLog() {
        Task {
            let snapshot = await store.snapshot()
            guard !Task.isCancelled else { return }
            apply(snapshot)
            UIPasteboard.general.string = snapshot.text
            showingCopiedConfirmation = true
        }
    }

    private func apply(_ snapshot: CrashLogSnapshot) {
        completeLogText = snapshot.text
        logPreview = DiagnosticLogPreview.make(from: snapshot.text)
        storedByteCount = snapshot.storedByteCount
        persistenceError = snapshot.persistenceError
    }
}
