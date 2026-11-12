import SwiftUI
import UIKit

/// Shared model for long scans: progress, ETA, hide/stop and background time.
final class ScanCoordinator: ObservableObject {
    @Published var isPresented = false
    @Published var isRunning = false
    @Published var title = ""
    @Published var message = ""
    @Published var completed: Int64 = 0
    @Published var total: Int64 = 0
    @Published var startedAt = Date()

    private(set) var token = ScanToken()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func begin(title: String, message: String, token: ScanToken = ScanToken()) {
        self.token = token
        self.title = title
        self.message = message
        completed = 0
        total = 0
        startedAt = Date()
        isRunning = true
        isPresented = true
        beginBackgroundTask()
    }

    func update(done: Int64, total: Int64) {
        guard isRunning else { return }
        completed = max(0, done)
        self.total = max(0, total)
    }

    func hide() {
        isPresented = false
    }

    func show() {
        guard isRunning else { return }
        isPresented = true
    }

    func stop() {
        token.cancel()
        finish()
    }

    func finish() {
        isRunning = false
        isPresented = false
        endBackgroundTask()
    }

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var etaSeconds: Int64? {
        guard total > completed, completed > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }
        let perItem = elapsed / Double(completed)
        return Int64(max(1, perItem * Double(total - completed)))
    }

    func statusText(_ language: AppLanguage) -> String {
        guard total > 0 else { return language.text("scan.preparing") }
        var text = language.text("scan.progress", completed, total)
        if let eta = etaSeconds {
            text += " · " + language.text("scan.eta", eta)
        }
        return text
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "3106 scan") { [weak self] in
            DispatchQueue.main.async {
                self?.finish()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

struct ScanProgressSheet: View {
    @EnvironmentObject private var scan: ScanCoordinator
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.accent)

            Text(scan.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(scan.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let fraction = scan.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(scan.statusText(language))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    scan.hide()
                } label: {
                    Label(language.text("scan.hide"), systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    scan.stop()
                } label: {
                    Label(language.text("scan.stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

struct ScanRunningBanner: View {
    @EnvironmentObject private var scan: ScanCoordinator
    @Environment(\.appLanguage) private var language

    var body: some View {
        Button {
            scan.show()
        } label: {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(language.text("scan.banner"))
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(uiColor: .separator).opacity(0.3)))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
    }
}