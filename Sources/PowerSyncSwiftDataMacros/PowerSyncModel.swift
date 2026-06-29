import Foundation

/// Generates a `PredicateCodableKeyPathProviding` conformance for a `@Model`, exposing its
/// stored properties' key paths through **public Foundation API** so the PowerSync store
/// never needs to reflect SwiftData internals for this model.
///
/// Apply it alongside `@Model`:
///
/// ```swift
/// import PowerSyncSwiftDataMacros
///
/// @Model
/// @PowerSyncModel
/// final class Note {
///     var id: String
///     var title: String
///     init(id: String, title: String) { ... }
/// }
/// ```
///
/// The expansion enumerates the type's stored properties at compile time (skipping
/// `@Transient` and computed properties), so adding a property never requires manual
/// bookkeeping. Publicly provided key paths take precedence over reflection in
/// `PowerSyncSwiftData`, removing its dependency on the private `schemaMetadata` layout
/// for conforming models.
@attached(extension, conformances: PredicateCodableKeyPathProviding, names: named(predicateCodableKeyPaths))
public macro PowerSyncModel() = #externalMacro(
    module: "PowerSyncSwiftDataMacrosPlugin",
    type: "PowerSyncModelMacro"
)
