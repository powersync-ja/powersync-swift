# PowerSyncSwiftData

A SwiftData custom `DataStore` backed by PowerSync. Apps keep using `@Model`, `@Query` and
`ModelContext` as usual; underneath, PowerSync owns the SQLite database, captures local
writes into its upload queue (`ps_crud`), and downloaded changes update the UI live. The
store is multi-process: widgets and App Intents read **and write** the shared database,
and changes made anywhere — sync downloads, the app, an extension — update `@Query`
views live.

**Status: alpha.** Requires iOS 18 / macOS 15 / watchOS 11 / tvOS 18 (the first OS releases
with custom SwiftData stores).

## Quick start

```swift
import PowerSync
import PowerSyncSwiftData
import SwiftData

@Model
final class Note {
    var id: String        // required: maps to PowerSync's implicit id column
    var title: String
    var done: Bool
    init(id: String, title: String, done: Bool) {
        self.id = id
        self.title = title
        self.done = done
    }
}

// 1. The PowerSync schema is derived from the models - declare them once.
let database = PowerSyncDatabase(schema: try PowerSyncSchema(for: [Note.self]))
try await database.connect(connector: myConnector)

// 2. Build the ModelContainer on the PowerSync-backed store.
let configuration = PowerSyncDataStoreConfiguration(name: "powersync", database: database)
let container = try ModelContainer(
    for: SwiftData.Schema([Note.self]),
    configurations: [configuration]
)

// 3. Start the change observer so sync downloads update @Query live.
let observer = PowerSyncChangeObserver(container: container, configuration: configuration)
try await observer.start(observing: [Note.self])
```

Everything else is ordinary SwiftData: `context.insert(note)`, `try context.save()`,
`@Query var notes: [Note]`, `#Predicate`, `FetchDescriptor`, relationships, ...

## Requirements on models

- Every synced `@Model` must declare a `String` property named `id`; it maps to PowerSync's
  implicit `id` column. When you insert a model with an empty `id`, the store mints a UUID
  and writes it back into the model on save. The id of a saved model is immutable:
  mutating it fails the save (delete and insert instead).
- Model inheritance hierarchies are rejected; flatten them into separate models.
- Table names default to `snake_case` of the entity name (`TodoItem` → `todo_item`);
  override per store with `tableNameForEntity`.
- Column names default to the property name; override per property with the
  configuration's `columnNameForProperty` (also accepted by `PowerSyncSchema(for:)`), so
  camelCase Swift properties can map to snake_case backend columns. To-one relationships
  append `_id` to the override's result.

## Hardening for production: `@PowerSyncModel` (optional)

The optional `PowerSyncSwiftDataMacros` product ships an attached macro that generates a
`PredicateCodableKeyPathProviding` conformance for a model — its stored-property key
paths flow through **public Foundation API** instead of the reflection fallback the store
otherwise uses (see *How it works*). The expansion enumerates stored properties at
compile time, so adding a property never needs manual bookkeeping:

```swift
// Package.swift: add the product (it adds nothing to apps that skip it)
.product(name: "PowerSyncSwiftDataMacros", package: "powersync-swift")
```

```swift
import PowerSyncSwiftDataMacros

@Model
@PowerSyncModel   // applied ALONGSIDE @Model (macros cannot inject other macros)
final class Note {
    var id: String
    var title: String
}
```

Recommended for production apps: SwiftData ships with the OS, so the reflection fallback
could in principle break when *users* update iOS — not when you compile. Conforming
models close that vector for key paths (property names are still enumerated from
`schemaMetadata`, guarded by a runtime coverage check that fails descriptively). Skipped
`@Transient` and computed properties, replicated availability, and a full round trip with
reflection suppressed are pinned by tests.

## Supported attribute types

| Swift | PowerSync column |
|---|---|
| `String` | `text` |
| `Bool` | `integer` (0/1) |
| `Int`, `Int64`, `Int32` | `integer` |
| `Double`, `Float` | `real` |
| `Date` | `real` (seconds since 1970) |
| `UUID` | `text` (lowercase uuidString, matching backend rendering) |
| `Data` | `text` (base64; PowerSync has no blob column type) |
| `RawRepresentable` enums (String/Int/Int64/Int32/Double raw) | raw value's column |
| other `Codable` values | `text` (JSON, ISO 8601 dates, sorted keys) |
| `Optional` of any of the above | nullable column |

`@Attribute(.ephemeral)` attributes are honored: no column, never persisted or uploaded,
reset to their declared default on fetch. Transformable attributes
(`@Attribute(.transformable(by:))`) are rejected with an error; store a `Codable` value
instead.

## Relationships

- **To-one** is stored as a `{name}_id` `text` column holding the related row's id (indexed
  by the derived schema).
- **To-many** needs an inverse to-one on the destination and is resolved by querying it.
- **Many-to-many without a join model is rejected**: PowerSync syncs tables, so the join
  table must exist anyway. Declare the join as its own `@Model` with two to-one
  relationships.
- Models that reference each other can be inserted in the same save (including cycles);
  identifier remapping rewrites the references. PowerSync tables don't enforce foreign
  keys, so insert order never matters.

## Fetching, predicates and sorting

`#Predicate` trees are translated to SQL `WHERE` clauses: comparisons, `==`/`!=` (with
`IS NULL` semantics), boolean key paths, `&&`/`||`/`!`, `contains` over constant
collections (`IN`), ranges (`BETWEEN`), `starts(with:)` and `contains` on strings
(`LIKE` with escaping), and constants of every supported attribute type, persistent
identifiers and models (bound as the related row's id). Sort descriptors translate to
`ORDER BY`; `fetchLimit`/`fetchOffset` to `LIMIT`/`OFFSET`; `fetchCount` runs
`SELECT COUNT(*)` and `fetchIdentifiers` selects only ids.

SQL three-valued logic does not leak into results: `!=` and `!(...)` over optional
columns include NULL rows exactly like Swift's optional semantics (the translator emits
NULL-safe forms).

Optional-chained to-one traversals translate too: `$0.playlist?.id == x` compares the
foreign-key column directly, and `$0.playlist?.name == x` resolves through an
`IN (SELECT id ...)` subquery — both preserving Swift's optional-chain semantics (a nil
relationship makes `==` false and `!=` true, NULL-safe in SQL).

Anything the translator does not understand (locale-aware operators such as
`localizedStandardContains`, arithmetic, explicit subqueries, ...) throws
`DataStoreError.preferInMemoryFilter`/`.preferInMemorySort`. **SwiftData applies the
in-memory fallback to `fetch()` only**: results stay correct (performance degrades with
table size), but `fetchCount`, `fetchIdentifiers` and `delete(model:where:)` propagate the
error — use `fetch(...).count` / `fetch` + per-model delete as the workaround for
untranslatable predicates on those paths.

Known semantic approximations:

- String sorts use SQLite `COLLATE NOCASE` (ASCII case-insensitive), an approximation of
  `SortDescriptor`'s localized-standard comparator (diacritics order differs).
- `starts(with:)`/`contains` translate to `LIKE`, which is ASCII case-insensitive in
  SQLite, while the Swift operators are case-sensitive.

## Live updates (reactivity)

`PowerSyncChangeObserver` watches the PowerSync tables of the observed entities. When rows
change without going through this process's SwiftData — a sync download, or a write from
**another process** (a widget button, an App Intent) — it reconciles them into a private
background `ModelContext` and saves, which broadcasts `ModelContext.didSave` — the signal
`@Query` and other contexts react to. Those saves carry the configuration's `remoteAuthor`
and are echo-suppressed by the store: nothing is written back to PowerSync, so no loops can
form. Cross-process wake-ups ride on a Darwin notification the PowerSync pool posts after
every committed write (the same mechanism Core Data uses for remote changes).

Current limitations of the observer:

- Relationship changes arriving from sync (a changed `{name}_id` column) update the row but
  are not yet diffed onto registered models; attribute changes are.
- It keeps the models of observed entities registered in its context, so memory is
  proportional to the observed tables' row counts.

## Schema evolution (migrations)

PowerSync tables are views over JSON and the local database is a **cache of synced data**,
so schema evolution works differently from Core Data-style migrations — most changes are
absorbed structurally and the backend drives the rest:

- **Adding a model or property**: pass the new models to `PowerSyncSchema(for:)` and the
  views regenerate when the database opens; no data migration runs. Old rows read `NULL`
  for added columns: optional properties materialize as `nil`, and required properties use
  their **declared default** (`var rating: Int = 5`). A required property with no default
  and no stored value fails the fetch with a descriptive error instead of trapping — give
  added required properties a default.
- **Removing a model or property**: stale JSON keys and tables are simply ignored locally;
  clean up server-side via sync rules when convenient.
- **Renaming, changing types, splitting models**: coordinate on the backend and re-sync;
  the server is the source of truth. `@Attribute(originalName:)` is not honored locally
  (data under the old key reads as missing until re-synced).
- **`SchemaMigrationPlan`/`VersionedSchema`** are rejected with an error: there is no
  local-store migration step for them to run against.

## Widgets, App Intents and app extensions

Sharing works like standard SwiftData: put the database in an App Group container and
have **each process create its own database and container** over the same file, compiling
the same `@Model` types into every target. The `PowerSyncDatabase` factory accepts an
absolute path:

```swift
let url = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.example.app")!
    .appendingPathComponent("powersync.db")
let database = PowerSyncDatabase(schema: schema, dbFilename: url.path)
```

**Reads and writes both work from extension processes** — interactive widget buttons and
App Intents included, mirroring what Apple's own SwiftData samples do. Writes persist
immediately, are captured into the shared upload queue, and a cross-process change signal
wakes the app's `watch` queries: the change observer reconciles and `@Query` views update
live. Concurrent opens are safe (the pool retries while another process holds the file)
and concurrent writers serialize through SQLite's WAL.

Rules and notes:

- **Only the app calls `connect()`** — sync has a single owner. Extension writes upload
  the next time the app's sync client runs (immediately, if the app is running: the
  signal nudges it).
- **App Intents in the app target** run in the app's process: full read-write against the
  app's own container, nothing special needed. **Widget-button intents** run in the
  widget extension's process: create the container there and write normally.
- Keep extension saves small (each save is one short transaction, typically
  milliseconds), so process suspension cannot catch a long write in flight.
- `readOnly: true` remains available as hardening for display-only widgets: fetching
  works and every write throws `DataStoreError.unsupportedFeature`.

See `Demos/SwiftDataDemo` for a complete widget setup including an interactive button
that writes from the widget process.

## How it works (and what it relies on)

- Container creation validates every mapped table and column against the actual database
  (`pragma_table_xinfo`), rejects table-name collisions and model inheritance, and fails if
  another store in the process registered the same entity with a different mapping —
  configuration mistakes fail fast and descriptively instead of as SQL errors mid-fetch.
- SwiftData materializes models from snapshots **by property name** through the snapshot's
  `Codable` representation (`DataStoreSnapshotCodingKey.modeledProperty`). A mismatched
  name traps inside SwiftData; the test suite pins this behavior with an exit test
  (macOS, where Swift Testing exit tests are available).
- `fetch`/`save` are synchronous while PowerSync is async; the store bridges with a
  semaphore plus a dedicated `TaskExecutor` on a private GCD queue, so neither the bridged
  work nor its continuations ever need a cooperative-pool thread. This is stress-tested
  with the pool saturated by blocked callers. The bridged work never hops back to the
  caller, so calling from the main thread (`mainContext`) is safe and behaves like the
  default store's synchronous I/O.
- Two private SwiftData surfaces are used, with defense in depth so SDK drift can never
  corrupt data:
  1. Attribute key paths come from reflecting `PersistentModel.schemaMetadata`
     (`Schema.Attribute` exposes no key path, unlike `Schema.Relationship`). Coverage is
     validated **at runtime on first use**: drift fails the first fetch/save with a
     descriptive error instead of materializing or persisting garbage. Models can source
     their **key paths** through Foundation's public `PredicateCodableKeyPathProviding`
     (keys = property names), which takes precedence over reflection — generated
     automatically by the `@PowerSyncModel` macro (see the hardening section above).
  2. The PowerSync id of a `PersistentIdentifier` is served by an in-process mint cache
     (every identifier the store creates remembers its id); the identifier's private
     `Codable` envelope is only a fallback, self-checked once per store at startup.
  Both surfaces are additionally pinned by drift-guard tests, including simulated-drift
  tests that exercise the runtime failure paths.
- Multi-process support rests on two PowerSync-core mechanisms (public, not SwiftData
  internals): the connection pool retries opening while another process holds the file
  (the WAL transition reports `SQLITE_BUSY` without consulting the busy handler), and a
  Darwin notification posted after every committed write re-emits `tableUpdates` with a
  marker that `watch` queries and the upload client treat as "unknown tables changed".
- `SqlCursor` rows are fully read inside the mapper closure; cursors never escape.

## Operational notes

- Do not reuse the configuration's `remoteAuthor` (default `"powersync-remote"`) as your
  own `ModelContext.author`: saves authored that way are echo-suppressed and never reach
  PowerSync.
- `PowerSyncDatabase.updateSchema(...)` with a live `ModelContainer` is not supported: the
  store's mapping is built at container creation. Rebuild the container after schema
  changes.
- On first launch, `@Query` is empty until the first sync completes; gate your UI with
  `database.waitForFirstSync()` (or `currentStatus`) as in any PowerSync app.
- After `disconnectAndClear()`, registered models in live contexts still hold deleted
  rows. With the change observer running it notices the cleared tables and deletes the
  registered models (the demo relies on this); otherwise tear down or refresh contexts.
- Widgets are snapshot-based and do not live-refresh: reload their timelines after
  relevant app writes (`WidgetCenter.shared.reloadTimelines(ofKind:)`); the system reloads
  a widget automatically after its own interactive intents run.

## Not supported (yet)

- `ModelContainer.erase()` — resetting local PowerSync data is `disconnectAndClear()`'s
  job; erasing through the store would upload a DELETE for every row.
- Model inheritance (rejected with a descriptive error).
- Transformable attributes.
- Composite unique constraints / `@Attribute(.unique)` upsert semantics.
- `@Attribute(.externalStorage)` (values are stored inline).
- Schema migrations beyond additive changes managed by PowerSync views.
- Connecting to the PowerSync service from more than one process (sync has a single owner:
  the app); extension reads and writes are fully supported.
