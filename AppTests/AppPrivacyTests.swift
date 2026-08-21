import SwiftUI
import Testing
@testable import WinnowApp

@Suite("App privacy cover")
struct AppPrivacyTests {
    @Test("only an active scene may expose wallet content")
    func scenePolicy() {
        #expect(!shouldObscureWallet(for: .active))
        #expect(shouldObscureWallet(for: .inactive))
        #expect(shouldObscureWallet(for: .background))
    }
}
