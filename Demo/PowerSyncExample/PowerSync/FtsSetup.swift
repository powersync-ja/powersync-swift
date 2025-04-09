//
//  FtsSetup.swift
//  PowerSyncExample
//
//  Created by Wade Morris on 4/9/25.
//

import Foundation
import PowerSync

/// Defines the type of JSON extract operation needed for generating SQL.
enum ExtractType {
    case columnOnly
    case columnInOperation
}

/// Generates SQL JSON extract expressions for FTS triggers.
///
/// - Parameters:
///   - type: The type of extraction needed (`columnOnly` or `columnInOperation`).
///   - sourceColumn: The JSON source column (e.g., `'data'`, `'NEW.data'`).
///   - columns: The list of column names to extract.
/// - Returns: A comma-separated string of SQL expressions.
func generateJsonExtracts(type: ExtractType, sourceColumn: String, columns: [String]) -> String {
    func createExtract(jsonSource: String, columnName: String) -> String {
        return "json_extract(\(jsonSource), '$.\"\(columnName)\"')"
    }

    func generateSingleColumnSql(columnName: String) -> String {
        switch type {
        case .columnOnly:
            return createExtract(jsonSource: sourceColumn, columnName: columnName)
        case .columnInOperation:
            return "\"\(columnName)\" = \(createExtract(jsonSource: sourceColumn, columnName: columnName))"
        }
    }

    return columns.map(generateSingleColumnSql).joined(separator: ", ")
}

/// Generates the SQL statements required to set up an FTS5 virtual table
/// and corresponding triggers for a given PowerSync table.
///
///
/// - Parameters:
///   - tableName: The public name of the table to index (e.g., "lists", "todos").
///   - columns: The list of column names within the table to include in the FTS index.
///   - schema: The PowerSync `Schema` object to find the internal table name.
///   - tokenizationMethod: The FTS5 tokenization method (e.g., "porter unicode61", "unicode61").
/// - Returns: An array of SQL statements to be executed, or `nil` if the table is not found in the schema.
func getFtsSetupSqlStatements(
    tableName: String,
    columns: [String],
    schema: Schema,
    tokenizationMethod: String = "unicode61"
) -> [String]? {

    guard let internalName = schema.tables.first(where: { $0.name == tableName })?.internalName else {
        print("Table '\(tableName)' not found in schema. Skipping FTS setup for this table.")
        return nil
    }

    let ftsTableName = "fts_\(tableName)"

    let stringColumnsForCreate = columns.map { "\"\($0)\"" }.joined(separator: ", ")
    
    let stringColumnsForInsertList = columns.map { "\"\($0)\"" }.joined(separator: ", ")

    var sqlStatements: [String] = []

    // 1. Create the FTS5 Virtual Table
    sqlStatements.append("""
        CREATE VIRTUAL TABLE IF NOT EXISTS \(ftsTableName)
        USING fts5(id UNINDEXED, \(stringColumnsForCreate), tokenize='\(tokenizationMethod)');
    """)

    // 2. Copy existing data from the main table to the FTS table
    sqlStatements.append("""
        INSERT INTO \(ftsTableName)(rowid, id, \(stringColumnsForInsertList))
        SELECT rowid, id, \(generateJsonExtracts(type: .columnOnly, sourceColumn: "data", columns: columns))
        FROM \(internalName);
    """)

    // 3. Create INSERT Trigger
    sqlStatements.append("""
        CREATE TRIGGER IF NOT EXISTS fts_insert_trigger_\(tableName) AFTER INSERT ON \(internalName)
        BEGIN
            INSERT INTO \(ftsTableName)(rowid, id, \(stringColumnsForInsertList))
            VALUES (
                NEW.rowid,
                NEW.id,
                \(generateJsonExtracts(type: .columnOnly, sourceColumn: "NEW.data", columns: columns))
            );
        END;
    """)

    // 4. Create UPDATE Trigger
    sqlStatements.append("""
        CREATE TRIGGER IF NOT EXISTS fts_update_trigger_\(tableName) AFTER UPDATE ON \(internalName)
        BEGIN
            UPDATE \(ftsTableName)
            SET \(generateJsonExtracts(type: .columnInOperation, sourceColumn: "NEW.data", columns: columns))
            WHERE rowid = NEW.rowid;
        END;
    """)

    // 5. Create DELETE Trigger
    sqlStatements.append("""
        CREATE TRIGGER IF NOT EXISTS fts_delete_trigger_\(tableName) AFTER DELETE ON \(internalName)
        BEGIN
            DELETE FROM \(ftsTableName) WHERE rowid = OLD.rowid;
        END;
    """)

    return sqlStatements
}


/// Configures Full-Text Search (FTS) tables and triggers for specified tables
/// within the PowerSync database. Call this function during database initialization.
///
/// Executes all generated SQL within a single transaction.
///
/// - Parameters:
///   - db: The initialized `PowerSyncDatabaseProtocol` instance.
///   - schema: The `Schema` instance matching the database.
/// - Throws: An error if the database transaction fails.
func configureFts(db: PowerSyncDatabaseProtocol, schema: Schema) async throws {
    print("[FTS] Starting FTS configuration...")
    var allSqlStatements: [String] = []

    // --- Define FTS configurations for each table ---

    // Configure FTS for the 'lists' table
    if let listStatements = getFtsSetupSqlStatements(
        tableName: LISTS_TABLE,
        columns: ["name"],
        schema: schema,
        tokenizationMethod: "porter unicode61"
    ) {
        print("[FTS] Generated \(listStatements.count) SQL statements for '\(LISTS_TABLE)' table.")
        allSqlStatements.append(contentsOf: listStatements)
    }

    // Configure FTS for the 'todos' table
    if let todoStatements = getFtsSetupSqlStatements(
        tableName: TODOS_TABLE,
        columns: ["description"],
        // columns: ["description", "list_id"], // If you need to search by list_id via FTS
        schema: schema
    ) {
        print("[FTS] Generated \(todoStatements.count) SQL statements for '\(TODOS_TABLE)' table.")
        allSqlStatements.append(contentsOf: todoStatements)
    }

    // --- Execute all generated SQL statements ---

    if !allSqlStatements.isEmpty {
        do {
            print("[FTS] Executing \(allSqlStatements.count) SQL statements in a transaction...")
            // Execute all setup statements within a single database transaction
            _ = try await db.writeTransaction { transaction in
                for sql in allSqlStatements {
                    print("[FTS] Executing SQL:\n\(sql)")
                    _ = try transaction.execute(sql: sql, parameters: [])
                }
            }
            print("[FTS] Configuration completed successfully.")
        } catch {
            print("[FTS] Error during FTS setup SQL execution: \(error.localizedDescription)")
            throw error
        }
    } else {
        print("[FTS] No FTS SQL statements were generated. Check table names and schema definition.")
    }
}
