import ContainerizationArchive
import Foundation
import KuriCore

/// Gets a Linux kernel for the sandbox's VMs.
///
/// Kata Containers publishes a container-tuned kernel only inside its full
/// release tarball (hundreds of MB, zstd-compressed). Kuri downloads it
/// once, keeps the one file it needs, and deletes the rest.
enum KernelInstaller {
    /// Where Kata keeps its kernels inside the tarball, and the link that
    /// names the default one.
    static let kernelDirectory = "opt/kata/share/kata-containers/"
    static let defaultLink = "vmlinux.container"

    static func install(
        from tarball: URL, to destination: URL, downloads: URL,
        progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let archive = downloads.appending(path: tarball.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: archive) }

        progress("Downloading the Linux kernel", 0)
        try await download(tarball, to: archive) { fraction in progress("Downloading the Linux kernel", fraction) }

        progress("Unpacking the Linux kernel", nil)
        let data = try await Task.detached(priority: .userInitiated) { try extractKernel(from: archive) }.value
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    /// Two passes over the archive: the first finds which file the default
    /// link points at (archives are read forward only), the second reads it.
    static func extractKernel(from archive: URL) throws -> Data {
        var entries: [KernelEntry] = []
        let reader = try ArchiveReader(file: archive)
        for (entry, _) in reader.makeStreamingIterator() {
            guard let path = entry.path, trimmed(path).hasPrefix(kernelDirectory) else { continue }
            entries.append(KernelEntry(path: trimmed(path), isSymlink: entry.fileType == .symbolicLink,
                                       symlinkTarget: entry.symlinkTarget))
        }
        try reader.throwIfStreamFailed()
        guard let path = kernelPath(in: entries) else {
            throw KuriError.provider("No kernel found in \(archive.lastPathComponent).")
        }
        let (_, data) = try ArchiveReader(file: archive).extractFile(path: path)
        guard data.count > 1_000_000 else { throw KuriError.provider("The kernel in the archive looks truncated.") }
        return data
    }

    struct KernelEntry: Equatable {
        var path: String
        var isSymlink: Bool
        var symlinkTarget: String? = nil
    }

    /// The file `vmlinux.container` resolves to, following links.
    static func kernelPath(in entries: [KernelEntry]) -> String? {
        var current = kernelDirectory + defaultLink
        for _ in 0..<8 {
            guard let entry = entries.first(where: { $0.path == current }) else { return nil }
            guard entry.isSymlink, let target = entry.symlinkTarget else { return current }
            current = target.hasPrefix("/") ? trimmed(target) : kernelDirectory + target
        }
        return nil
    }

    private static func trimmed(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    // MARK: Download

    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        try? FileManager.default.removeItem(at: destination)
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: destination)
            progress(1)
            return
        }
        let delegate = DownloadProgress(progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KuriError.http(status: http.statusCode, body: url.absoluteString)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
        let report: @Sendable (Double?) -> Void

        init(_ report: @escaping @Sendable (Double?) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
