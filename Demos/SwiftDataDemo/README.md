# PowerSync SwiftData Demo

A Todo List app built with **SwiftData** (`@Model`, `@Query`, `ModelContext`) whose storage is
**PowerSync**, using the `PowerSyncSwiftData` product of this package. It includes a
**read-only Widget Extension** that renders synced data from the same PowerSync database
file via an App Group — the use case from
[powersync-swift#126](https://github.com/powersync-ja/powersync-swift/issues/126).

How it fits together:

- `PowerSyncSchema(for: [TodoList.self, Todo.self])` derives the PowerSync schema (tables
  `todo_list` and `todo`) from the SwiftData models — the models are declared once.
- `PowerSyncDataStoreConfiguration` + `ModelContainer` route every SwiftData fetch and save
  through PowerSync, so local writes land in the upload queue and sync to Supabase.
- `PowerSyncChangeObserver` re-injects sync downloads into SwiftData, so plain `@Query`
  views update live.
- The PowerSync database file lives in the App Group container; the widget opens its own
  read-only store over the same file, without connecting to the sync service.

## Set up your Supabase and PowerSync projects

To run this demo, you need Supabase and PowerSync projects. Detailed instructions for
integrating PowerSync with Supabase can be found in
[the integration guide](https://docs.powersync.com/integration-guides/supabase).

### 1. Create the tables

The PowerSync tables are derived from the SwiftData models: entity names become snake_case
table names (`TodoList` → `todo_list`, `Todo` → `todo`), attribute names become column
names verbatim, and the to-one relationship `Todo.list` becomes a `list_id` column.
Create the matching Postgres tables in the Supabase SQL editor:

```sql
create table public.todo_list (
    id uuid not null default gen_random_uuid() primary key,
    name text not null
);

create table public.todo (
    id uuid not null default gen_random_uuid() primary key,
    "descriptionText" text not null,
    completed boolean not null default false,
    list_id uuid references public.todo_list (id) on delete cascade
);
```

> Note the quotes around `"descriptionText"`: the column name preserves the Swift property
> name's camelCase, so it must be quoted in Postgres.

### 2. Create the PowerSync publication

```sql
create publication powersync for table public.todo_list, public.todo;
```

### 3. Create a PowerSync instance and deploy sync rules

Create a new PowerSync instance connected to the Supabase database (see
[instructions](https://docs.powersync.com/integration-guides/supabase-+-powersync#connect-powersync-to-your-supabase)),
then deploy these sync rules:

```yaml
bucket_definitions:
  global:
    data:
      - SELECT * FROM todo_list
      - SELECT * FROM todo
```

> The demo models intentionally have no owner column, so the rules sync everything to every
> signed-in user. A real app would add e.g. an `owner_id` column and bucket parameters.

## Configure the app

1. Copy the secrets template and insert the credentials of your Supabase and PowerSync
   projects:

   ```bash
   cp SwiftDataDemo/Secrets.template.swift SwiftDataDemo/Secrets.swift
   ```

   `Secrets.swift` is gitignored.

2. Generate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

   ```bash
   xcodegen
   ```

3. Open `SwiftDataDemo.xcodeproj`, select your development team for both targets, and run
   the `SwiftDataDemo` scheme. Sign in or register a new user, create lists and todos, then
   add the "Pending Todos" widget to your home screen.

### App Group

The app and the widget share the PowerSync database file through the App Group
`group.co.powersync.swiftdatademo` (see the `.entitlements` files of both targets). The
database is opened with an **absolute** `dbFilename` pointing into the group container:

```swift
FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.co.powersync.swiftdatademo")!
    .appendingPathComponent("powersync.db").path
```

To run on a device you must register that App Group (or your own identifier — change it in
`Shared/SharedDatabase.swift`, both `.entitlements` files and `project.yml`) under your
Apple Developer team. On the simulator it works out of the box.

## The widget is read-only

The widget opens its **own** `PowerSyncDatabase` over the same file but:

- it never calls `connect()` — only the app talks to the PowerSync service;
- its `PowerSyncDataStoreConfiguration` uses `readOnly: true`, so the store refuses every
  write (`DataStoreError.unsupportedFeature`) and nothing can ever land in the upload queue
  from the extension;
- it fetches the first 5 pending todos plus the total count, builds value snapshots, closes
  the database and returns the timeline. The timeline asks for a refresh after 15 minutes
  (`.after(now + 15min)`); the system refreshes on its own cadence as well.

### Manually validating extension suspension behavior

App extensions that hold SQLite locks while being suspended get killed with `0xDEAD10CC`.
The widget avoids this by keeping reads short and never writing. To validate manually:

1. Run the app, sign in, and let it sync some todos. Add the widget to the home screen.
2. Background the app and force a timeline reload (edit a todo on another device, or just
   wait for the 15-minute refresh; while developing you can run the `SwiftDataDemoWidget`
   scheme to attach the debugger to the extension).
3. Watch the device log in Console.app (filter by `SwiftDataDemoWidget`): each reload should
   open the database, fetch, close and exit within milliseconds.
4. Confirm there are no `0xDEAD10CC` termination reports for the widget process under
   *Settings → Privacy & Security → Analytics & Improvements → Analytics Data* (or in
   Console crash reports).
5. Optional negative test: temporarily flip `readOnly` to `false` in
   `PendingTodosProvider.loadEntry()` and try inserting from the widget — with
   `readOnly: true` restored, `context.save()` must throw, proving the extension cannot
   write to the upload queue.

## Project generation

The Xcode project is generated from `project.yml` with XcodeGen (`xcodegen` from this
directory). The local package (`../..`) provides the `PowerSync` and `PowerSyncSwiftData`
products to both targets; `supabase-swift` is linked into the app target only.
