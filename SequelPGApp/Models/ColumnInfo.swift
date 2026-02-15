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

    init(
        name: String,
        ordinalPosition: Int,
        dataType: String,
        isNullable: Bool,
        columnDefault: String?,
        characterMaximumLength: Int?,
        isPrimaryKey: Bool = false
    ) {
        self.id = "\(ordinalPosition)_\(name)"
        self.name = name
        self.ordinalPosition = ordinalPosition
        self.dataType = dataType
        self.isNullable = isNullable
        self.columnDefault = columnDefault
        self.characterMaximumLength = characterMaximumLength
        self.isPrimaryKey = isPrimaryKey
    }
}
