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


    // MARK: - Editor font

    func testFontDefaultsToSystemMonoAtThirteenPoints() {
        let pref = EditorPreference(defaults: testDefaults)
        XCTAssertEqual(pref.fontFamily, .system)
        XCTAssertEqual(pref.fontSize, EditorPreference.defaultFontSize)
        XCTAssertEqual(pref.editorFont.pointSize, CGFloat(EditorPreference.defaultFontSize))
    }

    func testFontChoicesPersist() {
        let pref = EditorPreference(defaults: testDefaults)
        pref.fontFamily = .menlo
        pref.fontSize = 16

        let reloaded = EditorPreference(defaults: testDefaults)
        XCTAssertEqual(reloaded.fontFamily, .menlo)
        XCTAssertEqual(reloaded.fontSize, 16)
        XCTAssertEqual(reloaded.editorFont.pointSize, 16)
    }

    func testOutOfRangeStoredFontSizeFallsBackToDefault() {
        testDefaults.set(72, forKey: "com.sequelpg.editorFontSize")
        let pref = EditorPreference(defaults: testDefaults)
        XCTAssertEqual(pref.fontSize, EditorPreference.defaultFontSize)
    }

    func testUnknownStoredFontFamilyFallsBackToSystem() {
        testDefaults.set("comic-sans", forKey: "com.sequelpg.editorFontFamily")
        let pref = EditorPreference(defaults: testDefaults)
        XCTAssertEqual(pref.fontFamily, .system)
    }

    func testEveryFamilyResolvesToAFont() {
        for family in EditorFontFamily.allCases {
            XCTAssertEqual(family.nsFont(size: 14).pointSize, 14, "\(family) should resolve at the requested size")
        }
    }
}
