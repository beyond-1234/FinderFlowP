import Foundation

// MARK: - Measuring a transfer before it starts
//
// Every long operation wants a total up front so the progress bar can show a fraction.
// Computing that total means walking the whole source tree, which on a large folder
// takes long enough to freeze the window if done inline — the same mistake that used to
// make clicking Paste feel dead.
//
// `TransferEngine.totalSize` therefore never runs on the calling thread: the job starts
// indeterminate and gains a total when the measurement finishes.

enum TransferSizing {

    /// Measure `urls` off the main thread and hand the total to `job`.
    /// The job stays indeterminate until the value arrives.
    static func measureInBackground(_ urls: [URL], for job: OperationJob) {
        DispatchQueue.global(qos: .utility).async {
            let total = TransferEngine.totalSize(of: urls)
            guard total > 0 else { return }
            job.setTotal(total)
        }
    }
}
