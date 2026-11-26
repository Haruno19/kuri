import Foundation
import KuriCore
import Testing
@testable import KuriConfig

@Suite struct HomeLockTests {
    private func makeHome() throws -> KuriHome {
        let home = KuriHome(root: FileManager.default.temporaryDirectory.appending(path: "kuri-lock-\(UUID().uuidString)"))
        try home.prepare()
        return home
    }

    @Test func secondLockNamesTheHolder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let first = try HomeLock.acquire(home, holder: "kuri (process 4242)", pid: 4242)

        #expect {
            try HomeLock.acquire(home, holder: "Kuri (process 812)", pid: 812)
        } throws: { error in
            guard case .homeInUse(_, let holder, let pid) = error as? KuriError else { return false }
            return holder == "kuri (process 4242)" && pid == 4242
        }
        first.release()
    }

    @Test func releasingLetsTheNextOneIn() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let first = try HomeLock.acquire(home)
        first.release()
        first.release()  // twice is harmless
        let second = try HomeLock.acquire(home, holder: "kuri (process 1)", pid: 1)
        #expect(try String(contentsOf: home.lockFile, encoding: .utf8) == "kuri (process 1)\n1\n")
        second.release()
    }

    @Test func droppingTheLockReleasesIt() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        do { _ = try HomeLock.acquire(home) }
        try HomeLock.acquire(home).release()
    }

    @Test func aLockWithoutAnIdStillNamesItsHolder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let first = try HomeLock.acquire(home)
        // As a 0.1 build wrote it.
        try "Kuri (process 812)\n".write(to: home.lockFile, atomically: false, encoding: .utf8)
        #expect {
            try HomeLock.acquire(home)
        } throws: { error in
            guard case .homeInUse(_, let holder, let pid) = error as? KuriError else { return false }
            return holder == "Kuri (process 812)" && pid == nil
        }
        first.release()
    }

    @Test func findsAProcessProgram() {
        #expect(HomeLock.executable(of: ProcessInfo.processInfo.processIdentifier) != nil)
        #expect(HomeLock.executable(of: -1) == nil)
    }

    @Test func messageSaysWhoToQuit() {
        let error = KuriError.homeInUse(home: "~/.config/kuri", holder: "kuri (process 4242)")
        #expect(error.localizedDescription == "kuri (process 4242) is already using ~/.config/kuri. Quit it, then try again.")
        #expect(KuriError.homeInUse(home: "~/k", holder: nil).localizedDescription
                == "Another process is already using ~/k. Quit it, then try again.")
    }
}
