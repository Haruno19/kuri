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
        let first = try HomeLock.acquire(home, holder: "kuri (process 4242)")

        #expect {
            try HomeLock.acquire(home, holder: "Kuri (process 812)")
        } throws: { error in
            guard case .homeInUse(_, let holder) = error as? KuriError else { return false }
            return holder == "kuri (process 4242)"
        }
        first.release()
    }

    @Test func releasingLetsTheNextOneIn() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let first = try HomeLock.acquire(home)
        first.release()
        first.release()  // twice is harmless
        let second = try HomeLock.acquire(home, holder: "kuri (process 1)")
        #expect(try String(contentsOf: home.lockFile, encoding: .utf8) == "kuri (process 1)\n")
        second.release()
    }

    @Test func droppingTheLockReleasesIt() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        do { _ = try HomeLock.acquire(home) }
        try HomeLock.acquire(home).release()
    }

    @Test func messageSaysWhoToQuit() {
        let error = KuriError.homeInUse(home: "~/.config/kuri", holder: "kuri (process 4242)")
        #expect(error.localizedDescription == "kuri (process 4242) is already using ~/.config/kuri. Quit it, then try again.")
        #expect(KuriError.homeInUse(home: "~/k", holder: nil).localizedDescription
                == "Another process is already using ~/k. Quit it, then try again.")
    }
}
