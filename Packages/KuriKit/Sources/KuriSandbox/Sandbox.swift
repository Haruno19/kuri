import Containerization
import ContainerizationOCI
import Foundation
import KuriConfig
import KuriCore
import KuriStore
import Synchronization

public enum SandboxStatus: Sendable, Hashable {
    /// The kernel or images aren't there yet: `install()` fetches them.
    case notInstalled
    case installing(step: String, fraction: Double?)
    case ready
    case failed(String)
}

/// What a command printed, and how it ended.
public struct CommandResult: Sendable, Hashable {
    /// `nil` when the command didn't finish (timed out or cancelled).
    public var exitCode: Int32?
    /// stdout and stderr, interleaved as they came.
    public var output: String
    public var timedOut: Bool
}

/// Linux containers for conversations, on Apple's Containerization.
///
/// One container per conversation, each in its own lightweight VM (run by
/// Virtualization.framework in a separate system process). Started on the
/// first command, stopped after a while without one, and recreated when the
/// conversation's folders change. The container is disposable; the mounted
/// folders are what persist.
public actor Sandbox {
    private struct Running {
        let id: String
        let container: LinuxContainer
        let mounts: [SandboxMount]
        var lastUsed: ContinuousClock.Instant
        var idleCheck: Task<Void, Never>?
    }

    public let layout: SandboxLayout
    public private(set) var settings: SandboxSettings
    public private(set) var status: SandboxStatus = .notInstalled
    private let onStatus: @Sendable (SandboxStatus) -> Void
    /// A conversation's container started (true) or stopped (false).
    private let onContainer: @Sendable (UUID, Bool) -> Void
    private var manager: ContainerManager?
    private var running: [UUID: Running] = [:]
    private var starting: [UUID: Task<Running, any Error>] = [:]
    private var commandCount = 0

    /// Output kept per command; more than this is cut from the middle.
    static let maxOutputBytes = 1_000_000

    public init(home: KuriHome, settings: SandboxSettings,
                onStatus: @escaping @Sendable (SandboxStatus) -> Void = { _ in },
                onContainer: @escaping @Sendable (UUID, Bool) -> Void = { _, _ in }) {
        self.layout = SandboxLayout(home: home)
        self.settings = settings
        self.onStatus = onStatus
        self.onContainer = onContainer
    }

    // MARK: Installation

    private var kernelFile: URL {
        if case .file(let url) = settings.kernel { return url }
        return layout.kernel
    }

    /// Checks what's on disk, without touching the network.
    @discardableResult
    public func refreshStatus() async -> SandboxStatus {
        if case .installing = status { return status }
        var ready = FileManager.default.fileExists(atPath: kernelFile.path(percentEncoded: false))
        if ready, let store = try? ImageStore(path: layout.images) {
            let image = try? await store.get(reference: settings.image)
            let initImage = try? await store.get(reference: settings.initImage)
            ready = image != nil && initImage != nil
        } else {
            ready = false
        }
        setStatus(ready ? .ready : .notInstalled)
        return status
    }

    /// Fetches whatever is missing: the kernel, Apple's init image and the
    /// container image. After that the sandbox works offline.
    public func install() async throws {
        if case .installing = status { return }
        do {
            if !FileManager.default.fileExists(atPath: kernelFile.path(percentEncoded: false)) {
                guard case .tarball(let url) = settings.kernel else {
                    throw KuriError.invalidConfig(file: "config.json", reason: "sandbox.kernel: no file at \(kernelFile.path)")
                }
                try await KernelInstaller.install(from: url, to: layout.kernel, downloads: layout.downloads) { step, fraction in
                    Task { await self.setStatus(.installing(step: step, fraction: fraction)) }
                }
            }
            setStatus(.installing(step: "Fetching the init image", fraction: nil))
            var manager = try await makeManager()
            setStatus(.installing(step: "Fetching \(settings.image)", fraction: nil))
            let image = try await manager.imageStore.get(reference: settings.image, pull: true)
            setStatus(.installing(step: "Preparing \(settings.image)", fraction: nil))
            // A throwaway create unpacks the image into a snapshot, so the
            // first real command doesn't wait for it.
            let probe = "kuri-setup"
            try? manager.delete(probe)
            _ = try await manager.create(probe, image: image, networking: false, vm: resources) { _ in }
            try? manager.delete(probe)
            self.manager = manager
            setStatus(.ready)
        } catch {
            setStatus(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Applies new settings. Running containers stop if they would change.
    public func update(_ settings: SandboxSettings) async {
        guard settings != self.settings else { return }
        let restart = settings.image != self.settings.image || settings.cpus != self.settings.cpus
            || settings.memoryMiB != self.settings.memoryMiB || settings.kernel != self.settings.kernel
        self.settings = settings
        if restart {
            await stopAll()
            manager = nil
            await refreshStatus()
        }
    }

    private func setStatus(_ status: SandboxStatus) {
        self.status = status
        onStatus(status)
    }

    private var resources: VMResources {
        VMResources(cpus: settings.cpus, memoryInBytes: UInt64(settings.memoryMiB).mib() + VMResources.guestMemoryOverhead)
    }

    private func makeManager() async throws -> ContainerManager {
        if let manager { return manager }
        try FileManager.default.createDirectory(at: layout.images, withIntermediateDirectories: true)
        let manager = try await ContainerManager(
            kernel: Kernel(path: kernelFile, platform: .linuxArm),
            initfsReference: settings.initImage,
            imageStore: try ImageStore(path: layout.images),
            network: nil,
            snapshots: try SnapshotManager(path: layout.snapshots))
        self.manager = manager
        return manager
    }

    // MARK: Commands

    /// Runs `command` with `/bin/sh -lc` in the conversation's container,
    /// starting it if needed, from `/work`. `onOutput` sees the output as it
    /// comes, in whole characters.
    public func run(_ command: String, conversationID: UUID, mounts: [SandboxMount],
                    timeout: Duration, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        guard status == .ready else { throw KuriError.provider("The sandbox isn't set up yet.") }
        let container = try await container(for: conversationID, mounts: mounts)

        commandCount += 1
        let output = OutputBuffer(limit: Self.maxOutputBytes, onText: onOutput)
        let process = try await container.exec("cmd-\(commandCount)") { configuration in
            configuration.arguments = ["/bin/sh", "-lc", command]
            configuration.workingDirectory = SandboxMounts.workdir
            configuration.environmentVariables = [
                "PATH=\(LinuxProcessConfiguration.defaultPath)", "HOME=/root", "TERM=dumb", "LANG=C.UTF-8",
            ]
            configuration.stdout = output
            configuration.stderr = output
        }
        defer { touch(conversationID) }

        try await process.start()
        let seconds = max(1, Int64(timeout.components.seconds))
        let status: ExitStatus? = try await withTaskCancellationHandler {
            do {
                return try await process.wait(timeoutInSeconds: seconds)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                return nil  // timed out
            }
        } onCancel: {
            Task { try? await process.kill(.kill) }
        }
        if status == nil { try? await process.kill(.kill) }
        try? await process.delete()
        return CommandResult(exitCode: status?.exitCode, output: output.text, timedOut: status == nil)
    }

    /// The conversation's container, started (or restarted, if its folders
    /// changed) as needed. Concurrent callers share one start.
    private func container(for conversationID: UUID, mounts: [SandboxMount]) async throws -> LinuxContainer {
        if let existing = running[conversationID] {
            if existing.mounts == mounts { return existing.container }
            await stop(conversationID)
        }
        if let pending = starting[conversationID] { return try await pending.value.container }

        let task = Task { try await self.start(conversationID, mounts: mounts) }
        starting[conversationID] = task
        defer { starting[conversationID] = nil }
        let started = try await task.value
        running[conversationID] = started
        touch(conversationID)
        onContainer(conversationID, true)
        return started.container
    }

    private func start(_ conversationID: UUID, mounts: [SandboxMount]) async throws -> Running {
        var manager = try await makeManager()
        let id = "kuri-" + conversationID.uuidString.lowercased().prefix(13)
        try? manager.delete(id)  // left over from a crash
        for mount in mounts {
            try FileManager.default.createDirectory(atPath: mount.hostPath, withIntermediateDirectories: true)
        }
        let image = try await manager.imageStore.get(reference: settings.image)
        let settings = settings
        let container = try await manager.create(id, image: image, networking: false, vm: resources) { configuration in
            configuration.cpus = settings.cpus
            configuration.memoryInBytes = UInt64(settings.memoryMiB).mib()
            configuration.hostname = "kuri"
            // The container's own process just keeps it alive; commands are exec'd.
            configuration.process.arguments = ["/bin/sh", "-c", "trap 'exit 0' TERM; while :; do sleep 3600 & wait; done"]
            configuration.process.workingDirectory = SandboxMounts.workdir
            for mount in mounts {
                configuration.mounts.append(.share(source: mount.hostPath, destination: mount.guestPath,
                                                   options: mount.readOnly ? ["ro"] : []))
            }
        }
        self.manager = manager
        do {
            try await container.create()
            try await container.start()
        } catch {
            try? await container.stop()
            try? self.manager?.delete(id)
            throw error
        }
        return Running(id: id, container: container, mounts: mounts, lastUsed: .now)
    }

    private func touch(_ conversationID: UUID) {
        guard running[conversationID] != nil else { return }
        running[conversationID]?.lastUsed = .now
        running[conversationID]?.idleCheck?.cancel()
        let idle = Duration.seconds(settings.idleMinutes * 60)
        running[conversationID]?.idleCheck = Task {
            try? await Task.sleep(for: idle)
            guard !Task.isCancelled else { return }
            await self.stopIfIdle(conversationID, idle: idle)
        }
    }

    private func stopIfIdle(_ conversationID: UUID, idle: Duration) async {
        guard let entry = running[conversationID], ContinuousClock.now - entry.lastUsed >= idle else { return }
        await stop(conversationID)
    }

    public func isRunning(_ conversationID: UUID) -> Bool {
        running[conversationID] != nil
    }

    /// Stops and deletes a conversation's container. Its folders stay.
    public func stop(_ conversationID: UUID) async {
        guard let entry = running.removeValue(forKey: conversationID) else { return }
        entry.idleCheck?.cancel()
        onContainer(conversationID, false)
        try? await entry.container.stop()
        try? manager?.delete(entry.id)
    }

    public func stopAll() async {
        for id in running.keys { await stop(id) }
    }
}

/// Collects a process's output. Keeps the start and the end when it's too
/// long: errors tend to be at the end.
final class OutputBuffer: Writer, Sendable {
    private let state = Mutex<(head: Data, tail: Data, dropped: Int)>((Data(), Data(), 0))
    private let limit: Int
    private let onText: (@Sendable (String) -> Void)?
    /// Bytes of a character split across writes, held for the next one.
    private let pending = Mutex(Data())

    init(limit: Int, onText: (@Sendable (String) -> Void)? = nil) {
        self.limit = limit
        self.onText = onText
    }

    func write(_ data: Data) throws {
        if let onText {
            let text = pending.withLock { pending -> String in
                pending.append(data)
                let complete = Self.completePrefix(of: pending)
                let text = String(decoding: pending.prefix(complete), as: UTF8.self)
                pending.removeFirst(complete)
                return text
            }
            if !text.isEmpty { onText(text) }
        }
        state.withLock { state in
            if state.head.count < limit / 2 {
                let room = limit / 2 - state.head.count
                state.head.append(data.prefix(room))
                if data.count > room { appendTail(data.dropFirst(room), to: &state) }
            } else {
                appendTail(data, to: &state)
            }
        }
    }

    private func appendTail(_ data: Data, to state: inout (head: Data, tail: Data, dropped: Int)) {
        state.tail.append(data)
        let excess = state.tail.count - limit / 2
        if excess > 0 {
            state.tail.removeFirst(excess)
            state.dropped += excess
        }
    }

    func close() throws {}

    /// How many leading bytes end on a character boundary: an incomplete
    /// UTF-8 sequence at the end (at most three bytes) waits.
    static func completePrefix(of data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        for (offset, byte) in bytes.enumerated().reversed() {
            let fromEnd = bytes.count - offset
            if byte & 0b1100_0000 == 0b1000_0000 { continue }  // continuation byte
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return length > fromEnd ? data.count - fromEnd : data.count
        }
        return data.count
    }

    var text: String {
        state.withLock { state in
            let head = String(decoding: state.head, as: UTF8.self)
            let tail = String(decoding: state.tail, as: UTF8.self)
            return state.dropped > 0 ? "\(head)\n[… \(state.dropped) bytes …]\n\(tail)" : head + tail
        }
    }
}
