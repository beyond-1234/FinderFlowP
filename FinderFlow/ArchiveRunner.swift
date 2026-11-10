import Foundation
import AppKit

// MARK: - Archive runner
//
// Turns (tool, format, level, selection, destination) into a concrete command.
// The built-in path uses /usr/bin/zip; 7-Zip uses `7zz`; GUI-only archivers
// (Keka, BetterZip, Archiver) are driven through their own CLI when they ship one,
// otherwise the app is asked to open with the selection.

enum ArchiveRunner {

    enum RunError: LocalizedError {
        case unsupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let tool):
                return "\(tool) can't be driven automatically. Choose another tool."
            case .failed(let message):
                return message
            }
        }
    }

    static func run(tool: ArchiveTool,
                    format: ArchiveFormat,
                    level: ArchiveLevel?,
                    urls: [URL],
                    destination: URL,
                    job: OperationJob) throws {
        switch tool.id {
        case "builtin":
            try runZip(urls: urls, destination: destination, level: level, job: job)
        case "tool.sevenzip":
            try run7zip(urls: urls, destination: destination, format: format, level: level, job: job)
        default:
            // GUI archiver: hand the selection to the app and let its own dialog
            // take over (this is what "use the tool's right-click menu" means).
            try openInApp(tool: tool, urls: urls)
            job.finish(message: "Opened in \(tool.name)")
        }
    }

    // MARK: Built-in zip

    private static func runZip(urls: [URL],
                               destination: URL,
                               level: ArchiveLevel?,
                               job: OperationJob) throws {
        let base = urls.first?.deletingLastPathComponent() ?? destination.deletingLastPathComponent()
        let names = urls.map(\.lastPathComponent)

        var args: [String] = ["-r", "-q"]
        switch level?.id {
        case "store": args.append("-0")
        case "fast":  args.append("-1")
        case "best":  args.append("-9")
        default:      args.append("-6")
        }
        args.append(contentsOf: ["--", destination.path])
        args.append(contentsOf: names)

        try runSampling("/usr/bin/zip", args,
                        currentDirectory: base,
                        outputFile: destination,
                        job: job)
    }

    // MARK: 7-Zip

    private static func run7zip(urls: [URL],
                                destination: URL,
                                format: ArchiveFormat,
                                level: ArchiveLevel?,
                                job: OperationJob) throws {
        guard let cli = IntegrationStore.resolveCLI("7zz",
                                                    shellPath: IntegrationStore.loginShellPATH())
                ?? IntegrationStore.resolveCLI("7z",
                                                shellPath: IntegrationStore.loginShellPATH()) else {
            throw RunError.unsupported("7-Zip")
        }

        var args: [String] = ["a"]
        args.append("-t" + format.id)
        switch level?.id {
        case "store": args.append("-mx0")
        case "fast":  args.append("-mx1")
        case "best":  args.append("-mx9")
        default:      args.append("-mx5")
        }
        args.append("-y")
        args.append(destination.path)
        args.append(contentsOf: urls.map(\.path))

        let base = urls.first?.deletingLastPathComponent() ?? destination.deletingLastPathComponent()
        try runSampling(cli, args,
                        currentDirectory: base,
                        outputFile: destination,
                        job: job)
    }

    // MARK: GUI archivers

    private static func openInApp(tool: ArchiveTool, urls: [URL]) throws {
        guard let appURL = appURL(for: tool) else {
            throw RunError.unsupported(tool.name)
        }
        NSWorkspace.shared.open(urls,
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private static func appURL(for tool: ArchiveTool) -> URL? {
        for bid in tool.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        for path in tool.appPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: Process with progress sampling

    private static func runSampling(_ launchPath: String,
                                    _ arguments: [String],
                                    currentDirectory: URL,
                                    outputFile: URL,
                                    job: OperationJob) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try process.run()

        var last: Int64 = 0
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.25)
            if job.isCancelled {
                process.terminate()
                break
            }
            if let size = fileSize(outputFile), size > last {
                job.setReportedOutput(size)
                last = size
            }
        }
        process.waitUntilExit()

        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if job.isCancelled {
            try? FileManager.default.removeItem(at: outputFile)
            throw RunError.failed("Cancelled")
        }
        guard process.terminationStatus == 0 else {
            throw RunError.failed(errorText.isEmpty
                ? "The archive tool exited with code \(process.terminationStatus)."
                : errorText)
        }
        if let size = fileSize(outputFile) { job.setReportedOutput(size) }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }
}
