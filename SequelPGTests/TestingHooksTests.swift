import XCTest
@testable import SequelPG

/// Automated runs must never touch the developer's Keychain (no system
/// password prompts) or their saved profiles and preferences.
final class TestingHooksTests: XCTestCase {
    func testTestHostIsDetected() {
        XCTAssertTrue(TestingHooks.isTestHost)
        XCTAssertTrue(TestingHooks.isAutomatedTestRun)
    }

    func testKeychainIsInMemoryUnderTests() {
        XCTAssertTrue(TestingHooks.keychainService is InMemoryKeychainService)
    }

    func testDefaultsAreIsolatedUnderTests() {
        XCTAssertFalse(TestingHooks.userDefaults === UserDefaults.standard)
    }

    func testApplicationSupportIsThrowawayUnderTests() {
        let dir = TestingHooks.applicationSupportDirectory()
        XCTAssertTrue(dir.path.hasPrefix(FileManager.default.temporaryDirectory.path), dir.path)
    }

    func testInMemoryKeychainRoundTrip() throws {
        let keychain = InMemoryKeychainService()
        try keychain.save(password: "secret", forKey: "k")
        XCTAssertEqual(try keychain.load(forKey: "k"), "secret")
        try keychain.delete(forKey: "k")
        XCTAssertNil(try keychain.load(forKey: "k"))
    }
}
