import PowerSyncKotlin

enum KotlinAdapter {
    struct Index {
        static func toKotlin(_ index: IndexProtocol) -> PowerSyncKotlin.Index {
            PowerSyncKotlin.Index(
                name: index.name,
                columns: index.columns.map { IndexedColumn.toKotlin($0) }
            )
        }
    }

    struct IndexedColumn {
        static func toKotlin(_ column: IndexedColumnProtocol) -> PowerSyncKotlin.IndexedColumn {
            return PowerSyncKotlin.IndexedColumn(
                column: column.column,
                ascending: column.ascending,
                columnDefinition: nil,
                type: nil
            )
        }
    }

    struct Table {
        static func toKotlin(_ table: TableProtocol) -> PowerSyncKotlin.Table {
            let trackPreviousKotlin: PowerSyncKotlin.TrackPreviousValuesOptions? = if let track = table.trackPreviousValues {
                PowerSyncKotlin.TrackPreviousValuesOptions(
                    columnFilter: track.columnFilter,
                    onlyWhenChanged: track.onlyWhenChanged
                )
            } else {
                nil
            }
            
            return PowerSyncKotlin.Table(
                name: table.name,
                columns: table.columns.map { Column.toKotlin($0) },
                indexes: table.indexes.map { Index.toKotlin($0) },
                localOnly: table.localOnly,
                insertOnly: table.insertOnly,
                viewNameOverride: table.viewNameOverride,
                trackMetadata: table.trackMetadata,
                trackPreviousValues: trackPreviousKotlin,
                ignoreEmptyUpdates: table.ignoreEmptyUpdates
            )
        }
        
        static func toKotlin(_ table: RawTable) -> PowerSyncKotlin.RawTable {
            return PowerSyncKotlin.RawTable(
                name: table.name,
                put: translateStatement(table.put),
                delete: translateStatement(table.delete),
            );
        }
        
        private static func translateStatement(_ stmt: PendingStatement) -> PowerSyncKotlin.PendingStatement {
            return PowerSyncKotlin.PendingStatement(
                sql: stmt.sql,
                parameters: stmt.parameters.map(translateParameter)
            )
        }
        
        private static func translateParameter(_ param: PendingStatementParameter) -> PowerSyncKotlin.PendingStatementParameter {
            switch param {
            case .id:
                return PowerSyncKotlin.PendingStatementParameterId.shared
            case .column(let name):
                return PowerSyncKotlin.PendingStatementParameterColumn(name: name)
            }
        }
    }

    struct Column {
        static func toKotlin(_ column: any ColumnProtocol) -> PowerSyncKotlin.Column {
            PowerSyncKotlin.Column(
                name: column.name,
                type: columnType(from: column.type)
            )
        }

        private static func columnType(from swiftType: ColumnData) -> PowerSyncKotlin.ColumnType {
            switch swiftType {
            case .text:
                return PowerSyncKotlin.ColumnType.text
            case .integer:
                return PowerSyncKotlin.ColumnType.integer
            case .real:
                return PowerSyncKotlin.ColumnType.real
            }
        }
    }

    struct Schema {
        static func toKotlin(_ schema: SchemaProtocol) -> PowerSyncKotlin.Schema {
            var mappedTables: [PowerSyncKotlin.BaseTable] = []
            mappedTables.append(contentsOf: schema.tables.map(Table.toKotlin))
            mappedTables.append(contentsOf: schema.rawTables.map(Table.toKotlin))
            
            return PowerSyncKotlin.Schema(
                tables: mappedTables
            )
        }
    }
}
