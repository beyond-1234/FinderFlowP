import SwiftUI
import AppKit

// MARK: - Background operation progress
//
// Copy / move / compress are long-running: a 20 GB move between disks, or a zip of a
// photo library, can take minutes. Until now they ran with no feedback at all, so the
// app looked frozen and there was no way to cancel.
//
// Every long operation registers a Job here. The window shows a progress panel listing
// active jobs with a byte counter, a speed estimate, a progress bar and Cancel.

final class OperationProgressStore: ObservableObject {
    static let shared = OperationProgressStore()

    @Published private(set) var jobs: [OperationJob] = []

    private init() {}

    var hasActiveJobs: Bool { jobs.contains { !$0.isFinished } }

    func add(_ job: OperationJob) {
        jobs.append(job)
    }

    func remove(_ job: OperationJob) {
        jobs.removeAll { $0 === job }
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }
}

final class OperationJob: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let detail: String

    /// Total bytes to process, when known. 0 means indeterminate.
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var doneBytes: Int64 = 0
    @Published private(set) var isFinished = false
    @Published private(set) var failed = false
    @Published private(set) var message: String?

    private var started = Date()
    private(set) var isCancelled = false

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }

    var isCancellable: Bool { !isFinished }

    /// Bytes per second, averaged since the job started.
    var speed: Double? {
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 0.4, doneBytes > 0 else { return nil }
        return Double(doneBytes) / elapsed
    }

    var remaining: TimeInterval? {
        guard let speed, speed > 0, totalBytes > doneBytes else { return nil }
        return Double(totalBytes - doneBytes) / speed
    }

    var progressText: String {
        if totalBytes > 0 {
            return "\(ByteCountFormatter.string(fromByteCount: doneBytes, countStyle: .file))"
                + " / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        }
        return ByteCountFormatter.string(fromByteCount: doneBytes, countStyle: .file)
    }

    var speedText: String? {
        guard let speed else { return nil }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
        guard let remaining, remaining > 1 else { return rate }
        return rate + " · " + Self.formatRemaining(remaining) + " left"
    }

    private static func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    // MARK: Mutation

    func setTotal(_ bytes: Int64) {
        DispatchQueue.main.async { self.totalBytes = bytes }
    }

    func advance(_ bytes: Int64) {
        DispatchQueue.main.async { self.doneBytes += bytes }
    }

    func setMessage(_ text: String?) {
        DispatchQueue.main.async { self.message = text }
    }

    /// Archivers do not report input bytes; they grow their output file instead.
    /// Map the written archive size onto the input total so the bar still fills.
    func setReportedOutput(_ written: Int64) {
        DispatchQueue.main.async {
            self.doneBytes = max(self.doneBytes, written)
        }
    }

    func finish(failed: Bool = false, message: String? = nil) {
        DispatchQueue.main.async {
            self.failed = failed
            self.message = message ?? self.message
            self.isFinished = true
        }
    }

    func cancel() {
        isCancelled = true
        setMessage("Cancelling…")
    }
}

// MARK: - Progress panel

struct OperationProgressPanel: View {
    @ObservedObject private var store = OperationProgressStore.shared

    var body: some View {
        if !store.jobs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Transfers")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        if !store.hasActiveJobs {
                            Button("Clear") { store.clearFinished() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10))
                        }
                    }
                    ForEach(store.jobs) { job in
                        OperationJobRow(job: job, store: store)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct OperationJobRow: View {
    @ObservedObject var job: OperationJob
    let store: OperationProgressStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(job.failed ? Color.red : (job.isFinished ? Color.green : Color.accentColor))
                Text(job.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
                Text(job.progressText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if job.isCancellable {
                    Button {
                        job.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .fastTooltip("Cancel")
                }
            }

            if let fraction = job.fraction, !job.isFinished {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else if !job.isFinished {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 6) {
                if let speed = job.speedText, !job.isFinished {
                    Text(speed)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if let message = job.message {
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(job.failed ? Color.red : Color.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if job.failed { return "exclamationmark.triangle.fill" }
        if job.isFinished { return "checkmark.circle.fill" }
        return "arrow.left.arrow.right"
    }
}
