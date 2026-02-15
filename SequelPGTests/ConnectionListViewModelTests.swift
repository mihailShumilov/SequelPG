import XCTest
@testable import SequelPG

// MARK: - Mock Keychain Service

/// In-memory keychain mock that records all interactions for verification.
private final class ConnectionListMockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    var storage: [String: String] = [:]
    var saveCalls: [(password: String, key: String)] = []
    var loadCalls: [String] = []
    var deleteCalls: [String] = []
    var shouldThrowOnSave = false
    var shouldThrowOnLoad = false
    var shouldThrowOnDelete = false

    func save(password: String, forKey key: String) throws {
        saveCalls.append((password: password, key: key))
        if shouldThrowOnSave {
            throw AppError.keychainError("Mock save error")
        }
        storage[key] = password
    }

    func load(forKey key: String) throws -> String? {
        loadCalls.append(key)
        if shouldThrowOnLoad {
            throw AppError.keychainError("Mock load error")
        }
        return storage[key]
    }

    func delete(forKey key: String) throws {
        deleteCalls.append(key)
        if shouldThrowOnDelete {
            throw AppError.keychainError("Mock delete error")
        }
        storage.removeValue(forKey: key)
    }
}

// MARK: - ConnectionListViewModel Tests

@MainActor
final class ConnectionListViewModelTests: XCTestCase {

    private var store: ConnectionStore!
    private var keychain: ConnectionListMockKeychainService!
    private var testDefaults: UserDefaults!
    private var sut: ConnectionListViewModel!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.sequelpg.vmtests.\(UUID().uuidString)")!
        store = ConnectionStore(defaults: testDefaults)
        keychain = ConnectionListMockKeychainService()
        sut = ConnectionListViewModel(store: store, keychainService: keychain)
    }

    override func tearDown() {
        sut = nil
        keychain = nil
        store = nil
        testDefaults.removePersistentDomain(forName: testDefaults.volatileDomainNames.first ?? "")
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeProfile(
        id: UUID = UUID(),
        name: String = "Test DB",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "testdb",
        username: String = "testuser",
        sslMode: SSLMode = .prefer
    ) -> ConnectionProfile {
        ConnectionProfile(
            id: id,
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            sslMode: sslMode
        )
    }

    // MARK: - init

    func testInitLoadsProfilesFromStore() {
        // The default sut is initialized with an empty store
        XCTAssertEqual(sut.profiles.count, 0)
    }

    func testInitLoadsExistingProfilesFromStore() {
        let profile = makeProfile(name: "Pre-existing")
        store.add(profile)

        // Create a new view model that should pick up the pre-existing data
        let vm = ConnectionListViewModel(store: store, keychainService: keychain)

        XCTAssertEqual(vm.profiles.count, 1)
        XCTAssertEqual(vm.profiles.first?.name, "Pre-existing")
    }

    func testInitSetsDefaultPublishedProperties() {
        XCTAssertFalse(sut.showAddForm)
        XCTAssertNil(sut.editingProfile)
        XCTAssertNil(sut.deleteTarget)
        XCTAssertTrue(sut.connectionStatuses.isEmpty)
    }

    // MARK: - reload

    func testReloadRefreshesProfilesFromStore() {
        // Add a profile directly to the store (bypassing the VM)
        let profile = makeProfile(name: "Sneaky")
        store.add(profile)

        XCTAssertEqual(sut.profiles.count, 0, "VM should not yet know about the new profile")

        sut.reload()

        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(sut.profiles.first?.name, "Sneaky")
    }

    func testReloadReflectsDeletedProfiles() {
        let profile = makeProfile(name: "WillBeDeleted")
        sut.addProfile(profile, password: nil)
        XCTAssertEqual(sut.profiles.count, 1)

        // Delete directly in the store
        store.delete(id: profile.id)
        sut.reload()

        XCTAssertEqual(sut.profiles.count, 0)
    }

    // MARK: - addProfile

    func testAddProfileWithPasswordSavesToStoreAndKeychain() {
        let profile = makeProfile(name: "New DB")

        sut.addProfile(profile, password: "secret123")

        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(sut.profiles.first?.name, "New DB")
        XCTAssertEqual(keychain.saveCalls.count, 1)
        XCTAssertEqual(keychain.saveCalls.first?.password, "secret123")
        XCTAssertEqual(keychain.saveCalls.first?.key, profile.keychainKey)
    }

    func testAddProfileWithNilPasswordDoesNotSaveToKeychain() {
        let profile = makeProfile(name: "No Password")

        sut.addProfile(profile, password: nil)

        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(keychain.saveCalls.count, 0)
    }

    func testAddProfileWithEmptyPasswordDoesNotSaveToKeychain() {
        let profile = makeProfile(name: "Empty Password")

        sut.addProfile(profile, password: "")

        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(keychain.saveCalls.count, 0)
    }

    func testAddProfilePersistsToStore() {
        let profile = makeProfile(name: "Persisted")

        sut.addProfile(profile, password: nil)

        // Verify it was actually persisted by loading directly from the store
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, profile.id)
    }

    func testAddMultipleProfiles() {
        sut.addProfile(makeProfile(name: "DB1"), password: "p1")
        sut.addProfile(makeProfile(name: "DB2"), password: "p2")
        sut.addProfile(makeProfile(name: "DB3"), password: nil)

        XCTAssertEqual(sut.profiles.count, 3)
        XCTAssertEqual(keychain.saveCalls.count, 2)
    }

    func testAddProfileWhenKeychainThrowsStillAddsProfile() {
        keychain.shouldThrowOnSave = true
        let profile = makeProfile(name: "Keychain Fails")

        // The VM uses try? so it should not throw
        sut.addProfile(profile, password: "secret")

        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(sut.profiles.first?.name, "Keychain Fails")
    }

    // MARK: - updateProfile

    func testUpdateProfileUpdatesStoreAndReloads() {
        var profile = makeProfile(name: "Original")
        sut.addProfile(profile, password: nil)

        profile.name = "Updated"
        sut.updateProfile(profile, password: nil)

        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(sut.profiles.first?.name, "Updated")
    }

    func testUpdateProfileWithPasswordSavesToKeychain() {
        let profile = makeProfile(name: "Update Me")
        sut.addProfile(profile, password: nil)

        sut.updateProfile(profile, password: "newpassword")

        XCTAssertEqual(keychain.saveCalls.count, 1)
        XCTAssertEqual(keychain.saveCalls.first?.password, "newpassword")
        XCTAssertEqual(keychain.saveCalls.first?.key, profile.keychainKey)
    }

    func testUpdateProfileWithEmptyPasswordDeletesFromKeychain() {
        let profile = makeProfile(name: "Clear Password")
        sut.addProfile(profile, password: "oldpassword")
        keychain.deleteCalls.removeAll() // Reset after addProfile

        sut.updateProfile(profile, password: "")

        XCTAssertEqual(keychain.deleteCalls.count, 1)
        XCTAssertEqual(keychain.deleteCalls.first, profile.keychainKey)
        // Should not have saved a new password
        XCTAssertEqual(keychain.saveCalls.count, 1) // Only the original addProfile save
    }

    func testUpdateProfileWithNilPasswordDoesNotTouchKeychain() {
        let profile = makeProfile(name: "Nil Password")
        sut.addProfile(profile, password: "existing")
        keychain.saveCalls.removeAll()
        keychain.deleteCalls.removeAll()

        sut.updateProfile(profile, password: nil)

        XCTAssertEqual(keychain.saveCalls.count, 0)
        XCTAssertEqual(keychain.deleteCalls.count, 0)
    }

    func testUpdateProfileWithNonEmptyPasswordSavesNotDeletes() {
        let profile = makeProfile(name: "New Pass")
        sut.addProfile(profile, password: nil)
        keychain.saveCalls.removeAll()
        keychain.deleteCalls.removeAll()

        sut.updateProfile(profile, password: "fresh")

        XCTAssertEqual(keychain.saveCalls.count, 1)
        XCTAssertEqual(keychain.saveCalls.first?.password, "fresh")
        XCTAssertEqual(keychain.deleteCalls.count, 0)
    }

    func testUpdateProfileWhenKeychainSaveThrowsStillUpdatesProfile() {
        var profile = makeProfile(name: "Before")
        sut.addProfile(profile, password: nil)
        keychain.shouldThrowOnSave = true

        profile.name = "After"
        sut.updateProfile(profile, password: "failsave")

        XCTAssertEqual(sut.profiles.first?.name, "After")
    }

    func testUpdateProfileWhenKeychainDeleteThrowsStillUpdatesProfile() {
        var profile = makeProfile(name: "Before")
        sut.addProfile(profile, password: "old")
        keychain.shouldThrowOnDelete = true

        profile.name = "After"
        sut.updateProfile(profile, password: "")

        XCTAssertEqual(sut.profiles.first?.name, "After")
    }

    // MARK: - deleteProfile

    func testDeleteProfileRemovesFromStoreAndReloads() {
        let profile = makeProfile(name: "Delete Me")
        sut.addProfile(profile, password: nil)
        XCTAssertEqual(sut.profiles.count, 1)

        sut.deleteProfile(profile)

        XCTAssertEqual(sut.profiles.count, 0)
    }

    func testDeleteProfileRemovesPasswordFromKeychain() {
        let profile = makeProfile(name: "Has Password")
        sut.addProfile(profile, password: "topsecret")
        keychain.deleteCalls.removeAll()

        sut.deleteProfile(profile)

        XCTAssertEqual(keychain.deleteCalls.count, 1)
        XCTAssertEqual(keychain.deleteCalls.first, profile.keychainKey)
    }

    func testDeleteProfileRemovesConnectionStatus() {
        let profile = makeProfile(name: "Connected DB")
        sut.addProfile(profile, password: nil)
        sut.setConnected(profileId: profile.id)
        XCTAssertEqual(sut.connectionStatuses[profile.id], .connected)

        sut.deleteProfile(profile)

        XCTAssertNil(sut.connectionStatuses[profile.id])
    }

    func testDeleteProfileDoesNotAffectOtherProfiles() {
        let profile1 = makeProfile(name: "Keep Me")
        let profile2 = makeProfile(name: "Delete Me")
        sut.addProfile(profile1, password: nil)
        sut.addProfile(profile2, password: nil)

        sut.deleteProfile(profile2)

        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(sut.profiles.first?.name, "Keep Me")
    }

    func testDeleteProfileWhenKeychainThrowsStillRemovesProfile() {
        let profile = makeProfile(name: "Keychain Fail Delete")
        sut.addProfile(profile, password: "pw")
        keychain.shouldThrowOnDelete = true

        sut.deleteProfile(profile)

        XCTAssertEqual(sut.profiles.count, 0)
    }

    // MARK: - loadPasswordForProfile

    func testLoadPasswordForProfileReturnsStoredPassword() {
        let profile = makeProfile(name: "Has Password")
        keychain.storage[profile.keychainKey] = "mysecret"

        let password = sut.loadPasswordForProfile(profile)

        XCTAssertEqual(password, "mysecret")
    }

    func testLoadPasswordForProfileReturnsEmptyStringWhenNoPassword() {
        let profile = makeProfile(name: "No Password")

        let password = sut.loadPasswordForProfile(profile)

        XCTAssertEqual(password, "")
    }

    func testLoadPasswordForProfileReturnsEmptyStringWhenKeychainThrows() {
        let profile = makeProfile(name: "Error Profile")
        keychain.shouldThrowOnLoad = true

        let password = sut.loadPasswordForProfile(profile)

        XCTAssertEqual(password, "")
    }

    func testLoadPasswordForProfileCallsKeychainWithCorrectKey() {
        let profile = makeProfile(name: "Key Check")

        _ = sut.loadPasswordForProfile(profile)

        XCTAssertEqual(keychain.loadCalls.count, 1)
        XCTAssertEqual(keychain.loadCalls.first, profile.keychainKey)
    }

    // MARK: - setConnected

    func testSetConnectedSetsProfileToConnected() {
        let profileId = UUID()

        sut.setConnected(profileId: profileId)

        XCTAssertEqual(sut.connectionStatuses[profileId], .connected)
    }

    func testSetConnectedDisconnectsAllOtherProfiles() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        sut.setConnected(profileId: id1)
        sut.setError(profileId: id2)
        sut.connectionStatuses[id3] = .disconnected

        sut.setConnected(profileId: id2)

        XCTAssertEqual(sut.connectionStatuses[id1], .disconnected)
        XCTAssertEqual(sut.connectionStatuses[id2], .connected)
        XCTAssertEqual(sut.connectionStatuses[id3], .disconnected)
    }

    func testSetConnectedOnAlreadyConnectedProfileKeepsItConnected() {
        let id = UUID()
        sut.setConnected(profileId: id)

        sut.setConnected(profileId: id)

        XCTAssertEqual(sut.connectionStatuses[id], .connected)
    }

    func testSetConnectedWithNoExistingStatusesWorks() {
        XCTAssertTrue(sut.connectionStatuses.isEmpty)

        let id = UUID()
        sut.setConnected(profileId: id)

        XCTAssertEqual(sut.connectionStatuses.count, 1)
        XCTAssertEqual(sut.connectionStatuses[id], .connected)
    }

    // MARK: - setError

    func testSetErrorSetsProfileToError() {
        let profileId = UUID()

        sut.setError(profileId: profileId)

        XCTAssertEqual(sut.connectionStatuses[profileId], .error)
    }

    func testSetErrorDoesNotAffectOtherProfileStatuses() {
        let id1 = UUID()
        let id2 = UUID()
        sut.setConnected(profileId: id1)

        sut.setError(profileId: id2)

        XCTAssertEqual(sut.connectionStatuses[id1], .connected)
        XCTAssertEqual(sut.connectionStatuses[id2], .error)
    }

    func testSetErrorOverwritesPreviousStatus() {
        let id = UUID()
        sut.setConnected(profileId: id)
        // setConnected makes this profile .connected
        // Now all others are .disconnected, but id is still .connected
        XCTAssertEqual(sut.connectionStatuses[id], .connected)

        sut.setError(profileId: id)

        XCTAssertEqual(sut.connectionStatuses[id], .error)
    }

    // MARK: - clearConnectionState

    func testClearConnectionStateRemovesAllStatuses() {
        let id1 = UUID()
        let id2 = UUID()
        sut.setConnected(profileId: id1)
        sut.setError(profileId: id2)

        sut.clearConnectionState()

        XCTAssertTrue(sut.connectionStatuses.isEmpty)
    }

    func testClearConnectionStateOnEmptyDictionaryIsHarmless() {
        XCTAssertTrue(sut.connectionStatuses.isEmpty)

        sut.clearConnectionState()

        XCTAssertTrue(sut.connectionStatuses.isEmpty)
    }

    // MARK: - statusColor

    func testStatusColorReturnsGreenForConnected() {
        let id = UUID()
        sut.connectionStatuses[id] = .connected

        XCTAssertEqual(sut.statusColor(for: id), "green")
    }

    func testStatusColorReturnsRedForError() {
        let id = UUID()
        sut.connectionStatuses[id] = .error

        XCTAssertEqual(sut.statusColor(for: id), "red")
    }

    func testStatusColorReturnsGrayForDisconnected() {
        let id = UUID()
        sut.connectionStatuses[id] = .disconnected

        XCTAssertEqual(sut.statusColor(for: id), "gray")
    }

    func testStatusColorReturnsGrayForUnknownProfile() {
        let unknownId = UUID()

        XCTAssertEqual(sut.statusColor(for: unknownId), "gray")
    }

    // MARK: - @Published properties behavior

    func testShowAddFormDefaultsToFalse() {
        XCTAssertFalse(sut.showAddForm)
    }

    func testShowAddFormCanBeToggled() {
        sut.showAddForm = true
        XCTAssertTrue(sut.showAddForm)

        sut.showAddForm = false
        XCTAssertFalse(sut.showAddForm)
    }

    func testEditingProfileDefaultsToNil() {
        XCTAssertNil(sut.editingProfile)
    }

    func testEditingProfileCanBeSet() {
        let profile = makeProfile(name: "Edit Target")
        sut.editingProfile = profile

        XCTAssertEqual(sut.editingProfile?.name, "Edit Target")
        XCTAssertEqual(sut.editingProfile?.id, profile.id)
    }

    func testEditingProfileCanBeCleared() {
        let profile = makeProfile(name: "Edit Target")
        sut.editingProfile = profile

        sut.editingProfile = nil

        XCTAssertNil(sut.editingProfile)
    }

    func testDeleteTargetDefaultsToNil() {
        XCTAssertNil(sut.deleteTarget)
    }

    func testDeleteTargetCanBeSet() {
        let profile = makeProfile(name: "Delete Target")
        sut.deleteTarget = profile

        XCTAssertEqual(sut.deleteTarget?.name, "Delete Target")
        XCTAssertEqual(sut.deleteTarget?.id, profile.id)
    }

    func testDeleteTargetCanBeCleared() {
        let profile = makeProfile(name: "Delete Target")
        sut.deleteTarget = profile

        sut.deleteTarget = nil

        XCTAssertNil(sut.deleteTarget)
    }

    // MARK: - Integration / Combined behavior

    func testAddThenUpdateThenDeleteLifecycle() {
        var profile = makeProfile(name: "Lifecycle")

        // Add
        sut.addProfile(profile, password: "initial")
        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(keychain.storage[profile.keychainKey], "initial")

        // Update name and password
        profile.name = "Lifecycle Updated"
        sut.updateProfile(profile, password: "updated")
        XCTAssertEqual(sut.profiles.count, 1)
        XCTAssertEqual(sut.profiles.first?.name, "Lifecycle Updated")
        XCTAssertEqual(keychain.storage[profile.keychainKey], "updated")

        // Set connection status
        sut.setConnected(profileId: profile.id)
        XCTAssertEqual(sut.connectionStatuses[profile.id], .connected)

        // Delete
        sut.deleteProfile(profile)
        XCTAssertEqual(sut.profiles.count, 0)
        XCTAssertNil(sut.connectionStatuses[profile.id])
        XCTAssertNil(keychain.storage[profile.keychainKey])
    }

    func testUpdatePasswordThenClearPassword() {
        let profile = makeProfile(name: "Password Lifecycle")
        sut.addProfile(profile, password: "first")
        XCTAssertEqual(keychain.storage[profile.keychainKey], "first")

        // Clear the password by passing empty string
        sut.updateProfile(profile, password: "")
        XCTAssertNil(keychain.storage[profile.keychainKey])
    }

    func testSetConnectedThenErrorThenClear() {
        let id = UUID()

        sut.setConnected(profileId: id)
        XCTAssertEqual(sut.statusColor(for: id), "green")

        sut.setError(profileId: id)
        XCTAssertEqual(sut.statusColor(for: id), "red")

        sut.clearConnectionState()
        XCTAssertEqual(sut.statusColor(for: id), "gray")
    }

    func testMultipleProfilesWithMixedStatuses() {
        let p1 = makeProfile(name: "DB1")
        let p2 = makeProfile(name: "DB2")
        let p3 = makeProfile(name: "DB3")
        sut.addProfile(p1, password: nil)
        sut.addProfile(p2, password: nil)
        sut.addProfile(p3, password: nil)

        sut.setConnected(profileId: p1.id)
        sut.setError(profileId: p2.id)
        // p3 has no status

        XCTAssertEqual(sut.statusColor(for: p1.id), "green")
        XCTAssertEqual(sut.statusColor(for: p2.id), "red")
        XCTAssertEqual(sut.statusColor(for: p3.id), "gray")
    }
}
