import Foundation
import KuriConfig

/// The sandbox's settings, resolved from `config.json` with defaults.
public struct SandboxSettings: Sendable, Hashable {
    /// OCI image for conversation containers.
    public var image: String
    public var cpus: Int
    public var memoryMiB: Int
    /// Minutes without a command before a conversation's container stops.
    public var idleMinutes: Int
    /// Where the Linux kernel comes from: a release tarball, or a local
    /// `vmlinux` to use as is.
    public var kernel: KernelSource
    /// Apple's init filesystem for Containerization, matching the package version.
    public var initImage: String

    public enum KernelSource: Sendable, Hashable {
        /// A Kata Containers release tarball; the kernel inside is extracted.
        case tarball(URL)
        /// A kernel binary already on disk.
        case file(URL)
    }

    /// Kuri's own image (`Sandbox/Dockerfile`): Python with tools and
    /// libraries for documents and data. The tag is `Sandbox/VERSION`.
    public static let kuriImage = "ghcr.io/haruno19/kuri-sandbox:1"
    /// What `kuriImage` adds to Python, for the model's instructions.
    public static let kuriImageContents = """
        Python 3 with pypdf, pdfplumber, pandas, openpyxl, python-docx, Pillow and matplotlib (Agg backend), \
        and the tools pdftotext, pdftoppm and pdfinfo (poppler), pandoc, ImageMagick, ripgrep, jq, git and sqlite3
        """
    /// The official Python image, Debian slim: Python and basic Unix tools.
    public static let pythonImage = "docker.io/library/python:3-slim"
    /// The images Settings offers; any other reference works in config.json.
    public static let presets: [(name: String, image: String)] = [("Kuri", kuriImage), ("Python (slim)", pythonImage)]
    public static let defaultImage = kuriImage
    public static let defaultKernelTarball = URL(string:
        "https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst")!
    /// Keep in step with the Containerization version in Package.swift.
    public static let defaultInitImage = "ghcr.io/apple/containerization/vminit:0.57.0"

    public init(_ config: SandboxConfig? = nil) {
        image = config?.image ?? Self.defaultImage
        cpus = config?.cpus ?? 4
        memoryMiB = config?.memoryMiB ?? 2048
        idleMinutes = config?.idleMinutes ?? 10
        if let path = config?.kernel {
            kernel = .file(URL(filePath: (path as NSString).expandingTildeInPath))
        } else {
            kernel = .tarball(config?.kernelURL ?? Self.defaultKernelTarball)
        }
        initImage = Self.defaultInitImage
    }
}

/// The sandbox's files, under `~/.config/kuri/sandbox`.
public struct SandboxLayout: Sendable {
    public let root: URL

    public init(home: KuriHome) {
        root = home.root.appending(path: "sandbox", directoryHint: .isDirectory)
    }

    public var kernel: URL { root.appending(path: "kernel/vmlinux") }
    /// OCI content, image references and per-container state.
    public var images: URL { root.appending(path: "images", directoryHint: .isDirectory) }
    /// Each image unpacked once, cloned per container.
    public var snapshots: URL { root.appending(path: "snapshots", directoryHint: .isDirectory) }
    public var downloads: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
}
