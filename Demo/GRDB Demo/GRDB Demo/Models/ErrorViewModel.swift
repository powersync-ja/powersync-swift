import GRDB
import SwiftUI

func presentError(_ error: Error) -> String {
    if let grdbError = error as? DatabaseError {
        return grdbError.message ?? "Unknown GRDB error"
    } else {
        return error.localizedDescription
    }
}

/// A small view model which allows reporting errors to an observable state.
/// This state can be used by a shared view as an alert service.
@Observable
class ErrorViewModel {
    var errorMessage: String?

    func report(_ message: String) {
        errorMessage = message
    }

    /// Runs a callback and presents ant error if thrown
    @discardableResult
    func withReporting<R>(
        _ message: String? = nil,
        _ callback: () throws -> R
    ) rethrows -> R {
        do {
            return try callback()
        } catch {
            errorMessage = message ?? ": " + presentError(error)
            throw error
        }
    }

    @discardableResult
    func withReportingAsync<R>(
        _ message: String? = nil,
        _ callback: @escaping () async throws -> R
    ) async throws -> R {
        do {
            return try await callback()
        } catch {
            errorMessage = message ?? ": " + presentError(error)
            throw error
        }
    }

    func clear() {
        errorMessage = nil
    }
}
