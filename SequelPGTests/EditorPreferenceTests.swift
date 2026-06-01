import XCTest
@testable import SequelPG

@MainActor
final class EditorPreferenceTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.sequelpg.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToOnWhenNothingStored() {
        let pref = EditorPreference(defaults: testDefaults)
        XCTAssertTrue(pref.autocompleteWhileTyping, "Should default to enabled to preserve prior behaviour")
    }

    func testTogglingPersistsToDefaults() {
        let pref = EditorPreference(defaults: testDefaults)
        pref.autocompleteWhileTyping = false

        // A fresh instance over the same suite should observe the stored value.
        let reloaded = EditorPreference(defaults: testDefaults)
        XCTAssertFalse(reloaded.autocompleteWhileTyping)
    }

    func testReadsStoredFalse() {
        testDefaults.set(false, forKey: "com.sequelpg.autocompleteWhileTyping")
        let pref = EditorPreference(defaults: testDefaults)
        XCTAssertFalse(pref.autocompleteWhileTyping)
    }

    func testReadsStoredTrue() {
        testDefaults.set(true, forKey: "com.sequelpg.autocompleteWhileTyping")
        let pref = EditorPreference(defaults: testDefaults)
        XCTAssertTrue(pref.autocompleteWhileTyping)
    }

    func testReEnablingPersists() {
        testDefaults.set(false, forKey: "com.sequelpg.autocompleteWhileTyping")
        let pref = EditorPreference(defaults: testDefaults)
        XCTAssertFalse(pref.autocompleteWhileTyping)

        pref.autocompleteWhileTyping = true
        let reloaded = EditorPreference(defaults: testDefaults)
        XCTAssertTrue(reloaded.autocompleteWhileTyping)
    }
}
