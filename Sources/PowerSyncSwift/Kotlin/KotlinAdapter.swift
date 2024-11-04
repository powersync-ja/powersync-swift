import PowerSync

internal struct KotlinAdapter {
    struct Index {
        static func toKotlin(_ index: IndexProtocol) -> PowerSync.Index {
            PowerSync.Index(
                name: index.name,
                columns: index.columns.map { IndexedColumn.toKotlin($0) }
            )
        }
    }
    
    struct IndexedColumn {
        static func toKotlin(_ column: IndexedColumnProtocol) -> PowerSync.IndexedColumn {
            return PowerSync.IndexedColumn(
                column: column.column,
                ascending: column.ascending,
                columnDefinition: nil,
                type: nil
            )
        }
    }
    
    struct Table {
        static func toKotlin(_ table: TableProtocol) -> PowerSync.Table {
            PowerSync.Table(
                name: table.name,
                columns: table.columns.map {Column.toKotlin($0)},
                indexes: table.indexes.map { Index.toKotlin($0) },
                localOnly: table.localOnly,
                insertOnly: table.insertOnly,
                viewNameOverride: table.viewNameOverride
            )
        }
    }
    
    struct Column {
        static func toKotlin(_ column: any ColumnProtocol) -> PowerSync.Column {
            PowerSync.Column(
                name: column.name,
                type: columnType(from: column.type)
            )
        }
        
        private static func columnType(from swiftType: ColumnData) -> PowerSync.ColumnType {
            switch swiftType {
            case .text:
                return PowerSync.ColumnType.text
            case .integer:
                return PowerSync.ColumnType.integer
            case .real:
                return PowerSync.ColumnType.real
            }
        }
    }
    
    struct Schema {
        static func toKotlin(_ schema: SchemaProtocol) -> PowerSync.Schema {
            PowerSync.Schema(
                tables: schema.tables.map { Table.toKotlin($0) }
            )
        }
    }
}
