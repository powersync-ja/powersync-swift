import Foundation

public protocol ConnectionContext {
    /**
     Executes a SQL statement with optional parameters.
     
     - Parameters:
        - sql: The SQL statement to execute
        - parameters: Optional list of parameters for the SQL statement
     
     - Returns: A value indicating the number of rows affected
     
     - Throws: PowerSyncError if execution fails
     */
    @discardableResult
    func execute(sql: String, parameters: [Any?]?) throws -> Int64
    
    /**
     Retrieves an optional value from the database using the provided SQL query.
     
     - Parameters:
        - sql: The SQL query to execute
        - parameters: Optional list of parameters for the SQL query
        - mapper: A closure that maps the SQL cursor result to the desired type
     
     - Returns: An optional value of type RowType or nil if no result
     
     - Throws: PowerSyncError if the query fails
     */
    func getOptional<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) throws -> RowType?
    
    /**
     Retrieves all matching rows from the database using the provided SQL query.
     
     - Parameters:
        - sql: The SQL query to execute
        - parameters: Optional list of parameters for the SQL query
        - mapper: A closure that maps each SQL cursor result to the desired type
     
     - Returns: An array of RowType objects
     
     - Throws: PowerSyncError if the query fails
     */
    func getAll<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping (SqlCursor) throws -> RowType
    ) throws -> [RowType]
    
    /**
     Retrieves a single value from the database using the provided SQL query.
     
     - Parameters:
        - sql: The SQL query to execute
        - parameters: Optional list of parameters for the SQL query
        - mapper: A closure that maps the SQL cursor result to the desired type
     
     - Returns: A value of type RowType
     
     - Throws: PowerSyncError if the query fails or no result is found
     */
    func get<RowType>(
        sql: String,
        parameters: [Any?]?,
        mapper: @escaping  (SqlCursor) throws -> RowType
    ) throws -> RowType
}
