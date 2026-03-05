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
            return PowerSyncKotlin.Table(
                name: table.name,
                columns: table.columns.map { Column.toKotlin($0) },
                indexes: table.indexes.map { Index.toKotlin($0) },
                options: translateTableOptions(table),
                viewNameOverride: table.viewNameOverride,
            )
        }
        
        static func toKotlin(_ table: RawTable) -> PowerSyncKotlin.RawTable {
            let translatedPut = table.put.map(translateStatement)
            let translatedDelete = table.delete.map(translateStatement)
            
            if let schema = table.schema {
                return PowerSyncKotlin.RawTable(
                    name: table.name,
                    schema: translateRawTableSchema(schema),
                    put: translatedPut,
                    delete: translatedDelete,
                    clear: table.clear,
                )
            }
            
            // If we have no schema, put and delete are required. The constructor overloads on RawTable
            // should ensure that, but it's better to be defensive here.
            guard let put = translatedPut, let delete = translatedDelete else {
                fatalError("RawTable '\(table.name)' has no schema and must provide both put and delete statements")
            }

            return PowerSyncKotlin.RawTable(
                name: table.name,
                put: put,
                delete: delete,
                clear: table.clear
            );
        }
        
        private static func translateTableOptions(_ options: TableOptionsProtocol) -> PowerSyncKotlin.TableOptions {
            return PowerSyncKotlin.TableOptions(
                localOnly: options.localOnly,
                insertOnly: options.insertOnly,
                trackMetadata: options.trackMetadata,
                trackPreviousValues: options.trackPreviousValues.map {
                    PowerSyncKotlin.TrackPreviousValuesOptions(
                        columnFilter: $0.columnFilter,
                        onlyWhenChanged: $0.onlyWhenChanged
                    )
                },
                ignoreEmptyUpdates: options.ignoreEmptyUpdates,
            )
        }
        
        private static func translateRawTableSchema(_ schema: RawTableSchema) -> PowerSyncKotlin.RawTableSchema {
            return PowerSyncKotlin.RawTableSchema.init(
                tableName: schema.tableName,
                syncedColumns: schema.syncedColumns,
                options: translateTableOptions(schema.options)
            )
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
            case .rest:
                return PowerSyncKotlin.PendingStatementParameterRest.shared
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
