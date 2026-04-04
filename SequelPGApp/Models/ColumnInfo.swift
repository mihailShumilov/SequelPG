import Foundation

/// Column metadata from information_schema.columns.
struct ColumnInfo: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let ordinalPosition: Int
    let dataType: String
    let isNullable: Bool
    let columnDefault: String?
    let characterMaximumLength: Int?
    let isPrimaryKey: Bool
    let udtName: String?
    let numericPrecision: Int?
    let numericScale: Int?
    let isIdentity: Bool
    let identityGeneration: String?

    init(
        name: String,
        ordinalPosition: Int,
        dataType: String,
        isNullable: Bool,
        columnDefault: String?,
        characterMaximumLength: Int?,
        isPrimaryKey: Bool = false,
        udtName: String? = nil,
        numericPrecision: Int? = nil,
        numericScale: Int? = nil,
        isIdentity: Bool = false,
        identityGeneration: String? = nil
    ) {
        self.id = "\(ordinalPosition)_\(name)"
        self.name = name
        self.ordinalPosition = ordinalPosition
        self.dataType = dataType
        self.isNullable = isNullable
        self.columnDefault = columnDefault
        self.characterMaximumLength = characterMaximumLength
        self.isPrimaryKey = isPrimaryKey
        self.udtName = udtName
        self.numericPrecision = numericPrecision
        self.numericScale = numericScale
        self.isIdentity = isIdentity
        self.identityGeneration = identityGeneration
    }
}
