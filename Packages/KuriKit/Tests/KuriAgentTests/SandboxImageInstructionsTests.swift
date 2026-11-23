import Foundation
import KuriSandbox
import Testing
@testable import KuriAgent

@Suite struct SandboxImageInstructionsTests {
    /// With Kuri's image the model is told what it has, since it can't
    /// install anything; with another image it finds out for itself.
    @Test func kurisImageIsDescribed() {
        let kuri = Instructions.workspace([], image: SandboxSettings.kuriImage)
        #expect(kuri.contains("pdftotext") && kuri.contains("pandas") && kuri.contains("nothing else can be installed"))
        let python = Instructions.workspace([], image: SandboxSettings.pythonImage)
        #expect(!python.contains("pdftotext"))
    }
}
