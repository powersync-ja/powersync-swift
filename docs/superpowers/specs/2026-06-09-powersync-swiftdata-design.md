# PowerSyncSwiftData — Diseño (custom DataStore de SwiftData sobre PowerSync)

- **Fecha:** 2026-06-09
- **Estado:** Diseño aprobado (pendiente de validación del spec por el autor)
- **Rama:** `feature/swiftdata-integration`
- **Objetivo:** nuevo producto `PowerSyncSwiftData` en `powersync-swift` que expone un **custom `DataStore` de SwiftData respaldado por PowerSync**, de modo que una app use `@Model` / `@Query` / `ModelContext` con normalidad y, por debajo, el almacenamiento y la sincronización los gestione PowerSync.
- **Destino:** PR a `powersync-ja/powersync-swift` como propuesta de solución al [issue #126](https://github.com/powersync-ja/powersync-swift/issues/126), una vez **terminado y battle-tested**.

---

## 1. Resumen ejecutivo

SwiftData (iOS 18+) permite stores personalizados mediante los protocolos `DataStore`, `DataStoreConfiguration` y `DataStoreSnapshot`. Construimos un store que traduce las operaciones de SwiftData a la API nativa de PowerSync (`getAll`/`execute`/`writeTransaction`/`watch`), reutilizando el SQLite que PowerSync ya gestiona y su cola de subida `ps_crud`. **No** dependemos de GRDB ni de DataStoreKit; **aprendemos** de DataStoreKit (librería propia del autor, Apache-2.0) reimplementando sus técnicas en código propio.

**Arquitectura elegida ("C"):** un `DataStore` nativo y delgado sobre la API async de PowerSync. PowerSync **es** el motor SQLite (single source of truth) — no abrimos una segunda conexión, evitando contención de locks y crashes `0xDEAD10CC`. El coste es un puente síncrono→asíncrono acotado y centralizado.

---

## 2. Contexto y decisiones

| Decisión | Resultado | Motivo |
|---|---|---|
| Topología | **C** (DataStore nativo sobre la API de PowerSync) | Sin segunda conexión, single source of truth, PR-friendly. "A" exigiría reimplementar un motor SQLite que PowerSync ya da. |
| DataStoreKit | **Referencia, no dependencia ni copia** | El autor quiere una solución propia y limpia para el PR. |
| GRDB | **No usar como dependencia** | Preferencia del autor; PowerSync nativo basta. |
| Alcance | **Read-write + reactividad live** | Requisito del autor. |
| Modo dual | **iOS 18 base + iOS 27 mejora** vía `@available` | Requisito del autor (no targets separados). |
| `HistoryObserver` | **NO-GO** | La subida ya es automática vía `ps_crud`; implementar `HistoryProviding` sería un substrato paralelo especulativo sin beneficio. |
| Listón de entrega | **Producto completo, battle-tested, listo para lanzar** | Requisito del autor. El "PoC" es solo la Fase 1 de des-risking. |

---

## 3. Hechos verificados (restricciones que moldean el diseño)

- **`fetch(_:)`/`save(_:)` son SÍNCRONOS + throwing** y **WWDC 2026 (iOS 27) NO añadió DataStores async**. PowerSync es 100% async ⇒ **puente async→sync bloqueante inevitable**.
- **`DefaultSnapshot` es opaco** (sin accesores por propiedad) ⇒ usamos un **snapshot custom** (`PowerSyncSnapshot`).
- **El acceso por propiedad vive en `BackingData`** vía `KeyPath<Model,Value>` tipado, entregado solo dentro de `DataStoreSnapshot.init(from:relatedBackingDatas:)`.
- **`ModelContext` materializa el modelo desde el snapshot por NOMBRE de propiedad** (confirmado WWDC24; "by-name vs Codable-order" es inferido → se valida en Fase 1). `fetch` debe devolver en `fetchedSnapshots` solo snapshots de la entidad pedida (`persistentIdentifier.entityName == String(describing: T.self)`) y los relacionados en `relatedSnapshots`, o `ModelContext` aborta con *"Failed to materialize"*.
- **PowerSync:** API `async throws` (`getAll`/`get`/`execute`/`writeTransaction`/`readTransaction`); `watch` devuelve `AsyncThrowingStream`; `SqlCursor` solo válido **dentro del mapper**; tablas como vistas sobre `ps_data__*` (JSON), `id` TEXT UUID implícito (no personalizable), tipos de columna `text`/`integer`/`real`; las escrituras vía `execute` se **capturan automáticamente a `ps_crud`**.
- **Convenciones del repo:** `swift-tools: 6.1`, plataformas paquete iOS 15 / macOS 12 / watchOS 9 / tvOS 15 (NO se suben; el producto se anota `@available(iOS 18, …)`); productos declarados con `.library`; demos como apps Xcode con conector Supabase; tests con PowerSync `:memory:`; `CHANGELOG.md` con formato `## x.y.z`; sin swiftformat/swiftlint (se sigue el estilo existente).

---

## 4. Arquitectura

### 4.1 Estructura de ficheros

```
Sources/
└── PowerSyncSwiftData/
    ├── PowerSyncDataStore.swift            // DataStore + DataStoreBatching
    ├── PowerSyncDataStoreConfiguration.swift
    ├── PowerSyncSnapshot.swift             // DataStoreSnapshot custom (pieza crítica)
    ├── SchemaMapper.swift                  // reflexión SwiftData.Schema → tablas/columnas/keypaths
    ├── PowerSyncSchemaBuilder.swift        // (opcional) deriva PowerSync.Schema desde SwiftData.Schema
    ├── PredicateTranslator.swift           // FetchDescriptor → SQL
    ├── ValueCoercion.swift                 // Swift ↔ columnas SQLite
    ├── AsyncBridge.swift                   // _blocking (async→sync)
    ├── PowerSyncChangeObserver.swift       // reactividad (watch → ModelContext)
    ├── PowerSyncSwiftDataError.swift
    └── README.md
Demos/
└── SwiftDataDemo/                          // app to-do (@Query/@Model) + Widget read-only + conector Supabase
Tests/
└── PowerSyncSwiftDataTests/
```

### 4.2 Tipos núcleo

| Tipo | Conformidades | Responsabilidad |
|---|---|---|
| `PowerSyncDataStore` | `DataStore, DataStoreBatching` | `fetch`/`save`/`erase`/`delete` por lote; orquesta el resto. |
| `PowerSyncDataStoreConfiguration` | `DataStoreConfiguration` | Lleva el `PowerSyncDatabaseProtocol`, la `SwiftData.Schema`, overrides de mapeo y opciones. |
| `PowerSyncSnapshot` | `DataStoreSnapshot` | Snapshot custom genérico: `persistentIdentifier` + valores por nombre de propiedad. |
| `SchemaMapper` | — | Construye y cachea `[entidad: [propiedad: PropertyMapping]]` desde la `Schema`. |
| `PredicateTranslator` | — | `FetchDescriptor` → `(WHERE, ORDER BY, LIMIT/OFFSET, bindings)`; `preferInMemory*` para nodos no soportados. |
| `AsyncBridge` (`_blocking`) | — | Ejecuta trabajo async desde un contexto síncrono, con contrato de seguridad. |
| `PowerSyncChangeObserver` | — | Suscribe `watch`, reinyecta cambios remotos en un `ModelContext`, suprime eco. |
| `PowerSyncSwiftDataError` | `Error` | Errores tipados. |

### 4.3 Flujo de datos

```
LECTURA:   @Query / ModelContext.fetch
  → PowerSyncDataStore.fetch(req)                                  [SÍNC]
    → PredicateTranslator: descriptor → SQL + binds
    → _blocking { await db.getAll(sql, binds) { cursor → fila } }  // cursor no escapa
    → fila → PowerSyncSnapshot (valores por nombre, PID acuñado)
  → DataStoreFetchResult(descriptor, fetchedSnapshots, relatedSnapshots)
  → ModelContext materializa @Model por nombre de propiedad

ESCRITURA: ModelContext.save()
  → PowerSyncDataStore.save(req)                                   [SÍNC]
    → _blocking { await db.writeTransaction { tx in
         inserted/updated/deleted → INSERT/UPDATE/DELETE sobre la vista } }
       → triggers de PowerSync → ps_crud → connector sube al backend
  → DataStoreSaveChangesResult(remappedIdentifiers, snapshotsToReregister)

SYNC ↓:    PowerSync baja del servidor → cambia tabla
  → watch emite → PowerSyncChangeObserver → reinyección vía ModelContext (author="powersync-remote")
  → SwiftData propaga → @Query re-ejecuta fetch()
```

---

## 5. Diseño por componente

### 5.1 `PowerSyncDataStoreConfiguration`

```swift
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public final class PowerSyncDataStoreConfiguration: DataStoreConfiguration {
    public typealias Store = PowerSyncDataStore
    public var name: String
    public var schema: Schema?                       // SwiftData.Schema (lo inyecta ModelContainer)
    public let database: any PowerSyncDatabaseProtocol
    public let tableNameForEntity: (String) -> String   // override; por defecto snake_case(entityName)
    public let options: Options                       // política de fallback de predicates, autor de sync, etc.

    public init(name: String,
                database: any PowerSyncDatabaseProtocol,
                tableNameForEntity: @escaping (String) -> String = defaultTableName,
                options: Options = .init())

    public static func == (lhs, rhs) -> Bool { lhs.name == rhs.name }
    public func hash(into:)  { hasher.combine(name) }
    public func validate() throws { /* comprobar mapeo entidad↔tabla contra el schema de PowerSync */ }
}
```

La app crea el `PowerSyncDatabase`, llama `connect(connector:)`, y construye el `ModelContainer` con esta configuración apuntando a esa `database`.

### 5.2 `PowerSyncSnapshot` (pieza crítica)

```swift
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
public struct PowerSyncSnapshot: DataStoreSnapshot {
    public let persistentIdentifier: PersistentIdentifier
    let entityName: String
    let primaryKey: String                 // el id TEXT de PowerSync
    var values: [String: PowerSyncValue]   // CLAVE = nombre de propiedad (espejo del @Model)

    // model → snapshot (lo invoca SwiftData en save)
    public init(from backingData: any BackingData,
                relatedBackingDatas: inout [PersistentIdentifier: any BackingData]) { … }

    // fila SQL → snapshot (lo construimos en fetch)
    init(row: [String: PowerSyncValue], entity: EntityMapping, storeIdentifier: String) throws { … }

    public func copy(persistentIdentifier: PersistentIdentifier,
                     remappedIdentifiers: [PersistentIdentifier: PersistentIdentifier]?) -> Self { … }
}

enum PowerSyncValue: Codable, Sendable { case text(String), int(Int64), real(Double), blob(Data), null }
```

**Reglas de oro:**
1. **Los nombres de propiedad del snapshot DEBEN ser espejo de los del `@Model`** (la materialización es por nombre).
2. `init(from:)` recorre las propiedades del `Schema` y por cada una hace `backingData.getValue(forKey: keyPath)`, **despachando el `AnyKeyPath` con cast de existencial abierto** (patrón de DataStoreKit), parametrizado por el `valueType` del schema:
   ```swift
   switch keyPath {
   case let kp as KeyPath<Model, V>:  return backingData.getValue(forKey: kp)
   case let kp as KeyPath<Model, V?>: return backingData.getValue(forKey: kp)
   default: return nil
   }
   ```
   - to-one → `relatedModel.persistentModelID`; to-many → `[persistentModelID]`.
3. `init(row:)` coacciona cada columna al tipo de la propiedad (ver §6) y acuña el `PersistentIdentifier` con `PersistentIdentifier.identifier(for: storeId, entityName:, primaryKey: row["id"])`.
4. `copy(...)` reescribe las referencias de relación (to-one PID y to-many [PID]) aplicando `remappedIdentifiers`.

> **Obtención de KeyPaths tipados (tarea de robustez nº1):** preferir las **APIs públicas de `Schema`** (`Schema.Attribute`/`Schema.Relationship`) si exponen el `AnyKeyPath`; recurrir a reflejar el `schemaMetadata` del macro `@Model` con `Mirror` **solo si** no hay alternativa pública. La fuente elegida se cubre con tests-guardia de deriva de SDK.

### 5.3 `SchemaMapper`

En el init del store: recorre `schema.entities`; por entidad y `entity.storedProperties`:
- `Schema.Attribute` → columna = `attribute.name`; captura `valueType`, `isOptional`, `isUnique`, `options` (detecta `.externalStorage`).
- `Schema.Relationship` to-one → columna `{name}_id`; kind `.toOne(destination)`.
- to-many / many-to-many → sin columna en este lado; se resuelve por consulta / tabla de unión.

Cachea `[entityName: EntityMapping]` (con tablas de lookup nombre↔columna y nombre→keypath), protegido por el `Mutex` (`os_unfair_lock`) ya existente en el repo (`Sources/PowerSync/Utils/Mutex.swift`).

### 5.4 `PowerSyncSchemaBuilder` (opcional, reduce duplicación)

Como reflejamos la `SwiftData.Schema`, podemos **derivar automáticamente la `PowerSync.Schema`** (entidad→`Table`, atributos→`Column` con el tipo mapeado), de modo que el desarrollador solo declare sus `@Model` + el conector, evitando la duplicación que sufre la integración GRDB. Con escape hatch para overrides manuales. Recomendado, pero no bloqueante para la Fase 1.

### 5.5 `AsyncBridge`

```swift
func _blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    dispatchPrecondition(condition: .notOnQueue(.main))    // defensivo
    let sem = DispatchSemaphore(value: 0)
    let box = Box<Result<T, Error>>()                      // carrier con el Mutex del repo (iOS 15-safe)
    Task.detached(priority: .userInitiated) {
        do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
        sem.signal()
    }
    sem.wait()
    return try box.get().get()
}
```

**Por qué es seguro:** `Task.detached` no hereda aislamiento `@MainActor`; el `await` de PowerSync corre en el cooperative pool mientras `wait()` bloquea un hilo **distinto** y no-cooperativo; el semáforo es la barrera *happens-before*.

**Contrato (documentado en voz alta):** llamar solo desde el hilo de callback del store, **nunca** dentro de otro `Task`/función async, idealmente nunca en `@MainActor`; el cuerpo de PowerSync no debe saltar de vuelta al actor bloqueado. Se valida en Fase 1 (estrés de concurrencia + confirmar que el hilo de callback de SwiftData está fuera del cooperative pool).

### 5.6 `PredicateTranslator`

`translate(_ descriptor: FetchDescriptor<T>, _ entity: EntityMapping) -> (sql, bindings)`:
- Soporta: `==,!=,<,>,<=,>=`, `&&/||/!`, `IN`/`contains`, prefijo/sufijo de String, rangos, fechas, keypaths a columnas de la propia entidad y to-one (`{rel}_id`).
- `sortBy` → `ORDER BY` (asc/desc); `fetchLimit`/`fetchOffset` → `LIMIT`/`OFFSET`.
- Nodos no traducibles → `throw DataStoreError.preferInMemoryFilter` / `.preferInMemorySort` (SwiftData filtra en memoria). **Solo** como último recurso, documentado y testeado.
- `fetchCount` → `SELECT COUNT(*)`; `fetchIdentifiers` → `SELECT id`.

### 5.7 `PowerSyncChangeObserver` (reactividad)

- **Cimiento (iOS 18+):** suscribe `db.watch(sql:)` por tabla/consulta; al emitir, reinyecta las filas afectadas en un `ModelContext` de fondo con `editingState.author = "powersync-remote"`. SwiftData propaga el cambio entre contextos → `@Query` re-ejecuta `fetch()` (que lee fresco de PowerSync; la reinyección solo genera la notificación).
- **Supresión de eco:** en `save`, si `request.editingState.author == "powersync-remote"`, **no** se reescribe a PowerSync (el dato ya está sincronizado).
- **Capa iOS 27 (`@available`, opcional):** `ResultsObserver` para observación estilo `@Query` fuera de SwiftUI (p.ej. el propio observer / lógica del widget). **Sin `HistoryObserver`/`HistoryProviding`.**

---

## 6. Mapeo de tipos Swift ↔ PowerSync

| Swift | Columna PowerSync | Notas |
|---|---|---|
| `String` | `text` | passthrough |
| `Int`/`Int64`/`Int32` | `integer` | |
| `Bool` | `integer` | 0/1 |
| `Double`/`Float` | `real` | |
| `Date` | `real` (epoch) o `text` (ISO) | decisión: `real` por defecto (indexable, compacto) |
| `Data` | `blob` | |
| enum `RawRepresentable` | según raw (`integer`/`text`) | `init(rawValue:)` al leer |
| `@Attribute(.codable)` (iOS 27) | `text` (JSON) | **opaco a predicates/sort** |
| Opcional `T?` | nullable | `null` ↔ `nil` |
| to-one | columna `{rel}_id` (`text`) | guarda el `id` del relacionado |
| to-many / m2m | sin columna | consulta inversa / tabla de unión |

`id`: cada `@Model` sincronizado expone un identificador `String` mapeado al `id` de PowerSync (nombre configurable, por defecto `id`). En `insert` se acuña UUID si está vacío.

---

## 7. Flujos `fetch` / `save`

### 7.1 `fetch`

```swift
func fetch<T>(_ req: DataStoreFetchRequest<T>) throws -> DataStoreFetchResult<T, PowerSyncSnapshot> {
  let entity = mapper.entity(for: String(describing: T.self))
  let (sql, params) = try translator.build(req.descriptor, entity)
  let rows = try _blocking {
     try await database.getAll(sql: sql, parameters: params) { cursor in
        entity.rowDict(from: cursor)        // lee TODO dentro del mapper (cursor no escapa)
     }
  }
  let fetched = try rows.map { try PowerSyncSnapshot(row: $0, entity: entity, storeIdentifier: identifier) }
  return DataStoreFetchResult(descriptor: req.descriptor, fetchedSnapshots: fetched, relatedSnapshots: [:])
}
```

### 7.2 `save`

```swift
func save(_ req: DataStoreSaveChangesRequest<PowerSyncSnapshot>) throws -> DataStoreSaveChangesResult<PowerSyncSnapshot> {
  if req.editingState.author == options.remoteAuthor { return .init(for: identifier) } // eco: no-op
  var remapped: [PersistentIdentifier: PersistentIdentifier] = [:]
  try _blocking {
    try await database.writeTransaction { tx in
      for s in req.inserted {
        let pk = s.primaryKeyOrNewUUID()
        remapped[s.persistentIdentifier] = try .identifier(for: identifier, entityName: s.entityName, primaryKey: pk)
        try tx.execute(sql: s.insertSQL(table:), parameters: s.insertValues(pk: pk))   // → ps_crud automático
      }
      for s in req.updated { try tx.execute(sql: s.updateSQL(table:), parameters: s.updateValues()) }
      for s in req.deleted { try tx.execute(sql: s.deleteSQL(table:), parameters: [s.primaryKey]) }
    }
  }
  var saved: [PersistentIdentifier: PowerSyncSnapshot] = [:]
  for s in req.inserted { let pid = remapped[s.persistentIdentifier]!; saved[pid] = s.copy(persistentIdentifier: pid, remappedIdentifiers: remapped) }
  return DataStoreSaveChangesResult(for: identifier, remappedIdentifiers: remapped, snapshotsToReregister: saved)
}
```

Un `writeTransaction` = lote atómico (`BEGIN IMMEDIATE`/`COMMIT`/`ROLLBACK`). Inserts con dependencia circular: reintento diferido hasta resolver los FKs (patrón de DataStoreKit).

---

## 8. Modo dual iOS 18 / iOS 27

- **Todo lo esencial corre en iOS 18+.** La API pública del producto se anota `@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)`.
- **iOS 27 añade**, tras `if #available(iOS 27, *)`: `ResultsObserver` (observación fuera de SwiftUI), y opcionalmente `@Query(sectionBy:)`/`@Attribute(.codable)` en el lado de la app/demo. **No** cambia el mecanismo de reactividad (sigue siendo `watch`+reinyección).

---

## 9. Ruta solo-lectura para extensión/widget

El caso real del issue #126. La extensión abre el `PowerSyncDatabase` (App Group) y usa el mismo `PowerSyncDataStore` en modo de solo-lectura (`save` lanza `unsupportedFeature`). Seguridad ante suspensión: la lectura es corta y se cancela ante `willResignActive` (`interrupt`). Se valida bajo suspensión antes de declararlo listo.

---

## 10. Definition of Done (producto terminado y battle-tested)

**Funcionalidad completa:** todos los tipos de atributo (opcionales, `Date`, enums, `Data`, transformable, codable); relaciones to-one + to-many + many-to-many; `PredicateTranslator` exhaustivo (+ sort/limit/offset/count/identifiers; fallback en memoria solo para nodos intraducibles, documentado y testeado); `DataStoreBatching`; `erase`; remapeo de ids robusto (incl. circular); reactividad + supresión de eco; ruta solo-lectura para extensión con seguridad ante suspensión.

**Battle-tested:** suite con **Swift Testing** — unitarios + integración sobre PowerSync `:memory:` + **estrés de concurrencia/deadlock** del puente + **benchmarks** (incl. ventanas 60/28 días) + **tests-guardia de deriva del SDK**; demo + widget ejercitados; CI.

**Documentación:** `README.md` del módulo, entrada en `CHANGELOG.md`, doc-comments en la API pública.

---

## 11. Fases de ejecución

1. **Fase 1 — Gate de des-risking (NO es el entregable):** un `@Model Note{id,title,done,count}` plano + PowerSync `:memory:`. `insert`+`save` → verificar captura con `getNextCrudTransaction()` → `fetch` en otro contexto → **assert** valores+id correctos sin *"Failed to materialize"*. Incluye la *prueba de nombre desalineado*. Valida: materialización por nombre, `_blocking` sin deadlock, captura a `ps_crud`. **GO/NO-GO.**
2. CRUD completo + remapeo de ids + coerción de todos los tipos.
3. `PredicateTranslator` exhaustivo (+ sort/limit/offset/count).
4. Reactividad (`watch`+reinyección + eco) + capa iOS 27 (`ResultsObserver`).
5. Relaciones to-one → to-many/many-to-many.
6. Ruta solo-lectura extensión/widget + seguridad ante suspensión.
7. `PowerSyncSchemaBuilder` (derivar PowerSync.Schema) + ergonomía de API.
8. Demo `SwiftDataDemo` + widget.
9. Suite de tests completa + benchmarks + CI.
10. Endurecido, documentado, README/CHANGELOG, PR a #126.

---

## 12. Riesgos y mitigaciones

| Riesgo | Sev. | Mitigación |
|---|---|---|
| Materialización snapshot→modelo es **por nombre** (inferido, no API pública) | CRÍTICO | Fase 1 lo prueba (assert + prueba de nombre desalineado). Si falla, se pivota. |
| Dependencia de **internals privados** (`schemaMetadata` vía `Mirror`) para KeyPaths | ALTO | Preferir API pública de `Schema`; tests-guardia de deriva de SDK; fijar/declarar versiones probadas. **Se divulga en el PR.** |
| Puente `_blocking` → deadlock / inversión de prioridad | ALTO | `Task.detached` + semáforo en hilo distinto; contrato estricto; `dispatchPrecondition`; estrés de concurrencia. |
| `SqlCursor` escapa del mapper → crash | MEDIO | Extraer todo dentro del closure; nunca retener el cursor. |
| Traducción de predicates incompleta no escala | MEDIO | Cobertura amplia + fallback documentado; índices en consultas calientes. |
| Relaciones m2m / external storage / transformables | MEDIO | Fuera de Fase 1; cubiertos en fases 5+ con tests. |
| Suspensión 0xDEAD10CC en extensión | MEDIO | Lecturas cortas + `interrupt` en `willResignActive`; validar antes de lanzar. |
| Cambios futuros de SwiftData rompen la integración | MEDIO | **No se promete inmutabilidad**; tests-guardia + versiones fijadas; etiqueta de madurez la deciden los maintainers. |

---

## 13. Entregables y convenciones del repo

- **`Package.swift`:** `.library(name: "PowerSyncSwiftData", targets: ["PowerSyncSwiftData"])` + target dependiente de `PowerSync` + `.testTarget("PowerSyncSwiftDataTests")`. No se suben las plataformas del paquete; la API se anota `@available`.
- **`README.md`:** entrada en "Available Products" (con etiqueta de madurez según decidan los maintainers) + sección de Usage.
- **`CHANGELOG.md`:** entrada nueva con formato `## x.y.z`.
- **`Demos/SwiftDataDemo`:** layout de `PowerSyncExample` (`Screens/`, `Components/`, `PowerSync/` con schema + conector Supabase) + **Widget extension** de solo-lectura (caso del issue #126). README del demo.
- **Estilo:** seguir el código existente (sin swiftformat/swiftlint en el repo).

---

## 14. Fuera de alcance (futuro)

- Compartición multi-proceso multi-escritor (niveles 3-4 de simolus3 en #126).
- Migraciones complejas de schema entre versiones de modelo (más allá de lo básico).
- `HistoryProviding`/`HistoryObserver` (descartado salvo que un consumidor futuro lo justifique).

---

## 15. Cuestiones abiertas a cerrar en Fase 1

1. Confirmar que la materialización es **por nombre** (no por orden Codable) — prueba de nombre desalineado.
2. Confirmar que el hilo de callback de `fetch`/`save` está **fuera del cooperative pool** (estrés de deadlock).
3. Verificar las formas exactas en el SDK objetivo: `DataStoreFetchRequest.descriptor` (acceso a predicate/sortBy), `DataStoreSaveChangesRequest.inserted/updated/deleted`, `DataStoreSaveChangesResult(for:remappedIdentifiers:snapshotsToReregister:)`, y que devolver `remappedIdentifiers` evita el fatal de materialización.
4. Elegir la **fuente más estable de KeyPaths tipados** (API pública de `Schema` vs `Mirror` de `schemaMetadata`).
5. Validar coerción de tipos en ambas direcciones para las afinidades SQLite de PowerSync.
