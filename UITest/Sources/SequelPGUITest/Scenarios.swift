import Foundation

enum Scenarios {
    static let standardProfiles: [SeedProfile] = [
        SeedProfile("PG18 scram"),
        SeedProfile("PG16 md5", server: "pg16", role: "md5"),
        SeedProfile("PG13 trust", server: "pg13", role: "trust"),
        SeedProfile.viaSSH("PG18 via SSH"),
    ]

    static var all: [Scenario] { connection + query + data + tools }
}
