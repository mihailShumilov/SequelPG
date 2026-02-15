import XCTest
@testable import SequelPG

final class ConnectionStoreTests: XCTestCase {

    private var store: ConnectionStore!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.sequelpg.tests.\(UUID().uuidString)")!
        store = ConnectionStore(defaults: testDefaults)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: testDefaults.volatileDomainNames.first ?? "")
        testDefaults = nil
        store = nil
        super.tearDown()
    }

    func testLoadAllReturnsEmptyByDefault() {
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func testAddAndLoadProfile() {
        let profile = makeProfile(name: "Test DB")
        store.add(profile)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Test DB")
        XCTAssertEqual(loaded.first?.id, profile.id)
    }

    func testUpdateProfile() {
        var profile = makeProfile(name: "Original")
        store.add(profile)

        profile.name = "Updated"
        store.update(profile)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Updated")
    }

    func testDeleteProfile() {
        let profile = makeProfile(name: "ToDelete")
        store.add(profile)
        XCTAssertEqual(store.loadAll().count, 1)

        store.delete(id: profile.id)
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func testMultipleProfiles() {
        store.add(makeProfile(name: "DB1"))
        store.add(makeProfile(name: "DB2"))
        store.add(makeProfile(name: "DB3"))

        XCTAssertEqual(store.loadAll().count, 3)
    }

    func testDeleteNonExistentIdIsHarmless() {
        store.add(makeProfile(name: "Existing"))
        store.delete(id: UUID())
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func testProfileValidation() {
        let valid = makeProfile(name: "Valid")
        XCTAssertTrue(valid.validate().isEmpty)

        let invalid = ConnectionProfile(
            name: "",
            host: "",
            port: 0,
            database: "",
            username: ""
        )
        let errors = invalid.validate()
        XCTAssertEqual(errors.count, 5)
    }

    func testKeychainKey() {
        let id = UUID()
        let profile = ConnectionProfile(
            id: id,
            name: "Test",
            host: "localhost",
            database: "testdb",
            username: "user"
        )
        XCTAssertEqual(profile.keychainKey, "SequelPG:\(id.uuidString)")
    }

    // MARK: - Helpers

    private func makeProfile(name: String) -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            host: "localhost",
            port: 5432,
            database: "testdb",
            username: "testuser"
        )
    }
}
