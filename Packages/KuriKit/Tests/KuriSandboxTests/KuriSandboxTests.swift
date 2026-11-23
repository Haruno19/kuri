import Foundation
import Synchronization
import KuriConfig
import KuriStore
import Testing
@testable import KuriSandbox

@Suite struct SandboxMountTests {
    let scratch = URL(filePath: "/tmp/scratch/abc")

    @Test func scratchWhenNoFolderIsAttached() {
        let mounts = SandboxMounts.plan(folders: [], scratch: scratch)
        #expect(mounts == [SandboxMount(hostPath: "/tmp/scratch/abc", guestPath: "/work", readOnly: false, isScratch: true)])
    }

    @Test func oneFolderIsWork() {
        let mounts = SandboxMounts.plan(folders: [ConversationFolder(path: "/Users/me/Kuri", readOnly: true)], scratch: scratch)
        #expect(mounts.map(\.guestPath) == ["/work"])
        #expect(mounts.first?.readOnly == true)
    }

    @Test func severalFoldersGetUniqueNames() {
        let mounts = SandboxMounts.plan(folders: [
            ConversationFolder(path: "/a/src"), ConversationFolder(path: "/b/src"), ConversationFolder(path: "/c/docs"),
        ], scratch: scratch)
        #expect(mounts.map(\.guestPath) == ["/work/src", "/work/src-2", "/work/docs"])
    }
}

@Suite struct KernelInstallerTests {
    typealias Entry = KernelInstaller.KernelEntry
    let dir = KernelInstaller.kernelDirectory

    @Test func followsTheDefaultLink() {
        let entries = [
            Entry(path: dir + "vmlinux-6.18.56-208", isSymlink: false),
            Entry(path: dir + "vmlinux.container", isSymlink: true, symlinkTarget: "vmlinux-6.18.56-208"),
            Entry(path: dir + "vmlinux-nvidia-gpu.container", isSymlink: true, symlinkTarget: "vmlinux-nvidia"),
        ]
        #expect(KernelInstaller.kernelPath(in: entries) == dir + "vmlinux-6.18.56-208")
    }

    @Test func givesUpOnMissingOrLoopingLinks() {
        #expect(KernelInstaller.kernelPath(in: []) == nil)
        let loop = [Entry(path: dir + "vmlinux.container", isSymlink: true, symlinkTarget: "vmlinux.container")]
        #expect(KernelInstaller.kernelPath(in: loop) == nil)
    }
}

@Suite struct ShellOutputTests {
    @Test func reportsExitCodeAndTimeouts() {
        let ok = ShellTool.output(for: CommandResult(exitCode: 1, output: "no match", timedOut: false), timeout: 120)
        #expect(ok.text == "Exit code 1.\nno match")
        #expect(!ok.isError)  // a non-zero exit is information, not a failure of the tool
        let slow = ShellTool.output(for: CommandResult(exitCode: nil, output: "", timedOut: true), timeout: 5)
        #expect(slow.text == "Timed out after 5 s; the command was stopped.\n(no output)")
        #expect(slow.isError)
    }

    @Test func longOutputKeepsStartAndEnd() {
        let output = "START" + String(repeating: "x", count: 50_000) + "END"
        let trimmed = ShellTool.trimmed(output)
        #expect(trimmed.hasPrefix("START") && trimmed.hasSuffix("END"))
        #expect(trimmed.count < 30_000)
    }

    @Test func outputBufferDropsTheMiddle() throws {
        let buffer = OutputBuffer(limit: 10)
        try buffer.write(Data("abcde".utf8))
        try buffer.write(Data("fghijklmnop".utf8))
        #expect(buffer.text == "abcde\n[… 6 bytes …]\nlmnop")
    }

    @Test func outputBufferStreamsWholeCharacters() throws {
        let seen = Mutex<[String]>([])
        let buffer = OutputBuffer(limit: 1_000) { text in seen.withLock { $0.append(text) } }
        let bytes = Array("ok ✔ done".utf8)  // ✔ is three bytes
        let split = bytes.firstIndex(of: 0xE2)! + 1
        try buffer.write(Data(bytes[..<split]))
        try buffer.write(Data(bytes[split...]))
        #expect(seen.withLock { $0 } == ["ok ", "✔ done"])
        #expect(buffer.text == "ok ✔ done")
    }
}

@Suite struct SandboxImageTests {
    /// The image Kuri pulls by default is the one the workflow publishes:
    /// its tag is Sandbox/VERSION, and the Dockerfile says where it's from.
    @Test func defaultIsKurisImageAtTheCurrentVersion() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../Sandbox")
        let version = try String(contentsOf: root.appending(path: "VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(SandboxSettings.defaultImage == SandboxSettings.kuriImage)
        #expect(SandboxSettings.kuriImage == "ghcr.io/haruno19/kuri-sandbox:\(version)")
        let workflow = try String(contentsOf: root.appending(path: "../.github/workflows/sandbox-image.yml"), encoding: .utf8)
        #expect(workflow.contains("IMAGE: ghcr.io/haruno19/kuri-sandbox"))
        #expect(SandboxSettings.presets.map(\.image) == [SandboxSettings.kuriImage, SandboxSettings.pythonImage])
    }
}

@Suite struct SandboxSettingsTests {
    @Test func defaultsAndOverrides() {
        let defaults = SandboxSettings()
        #expect(defaults.image == SandboxSettings.defaultImage)
        #expect(defaults.kernel == .tarball(SandboxSettings.defaultKernelTarball))
        let custom = SandboxSettings(SandboxConfig(image: "alpine:3", cpus: 2, kernel: "/opt/vmlinux"))
        #expect(custom.image == "alpine:3")
        #expect(custom.cpus == 2)
        #expect(custom.kernel == .file(URL(filePath: "/opt/vmlinux")))
    }

    @Test func notInstalledUntilSetUp() async {
        let home = KuriHome(root: FileManager.default.temporaryDirectory.appending(path: "kuri-sandbox-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sandbox = Sandbox(home: home, settings: SandboxSettings())
        #expect(await sandbox.refreshStatus() == .notInstalled)
        await #expect(throws: Error.self) {
            try await sandbox.run("true", conversationID: UUID(), mounts: [], timeout: .seconds(1))
        }
    }
}
