# PowerSync Swift GRDB Demo App

A Todo List app demonstrating the use of the PowerSync Swift SDK with GRDB and Supabase.

## Set up your Supabase and PowerSync projects

To run this demo, you need Supabase and PowerSync projects. Detailed instructions for integrating PowerSync with Supabase can be found in [the integration guide](https://docs.powersync.com/integration-guides/supabase).

Follow this guide to:

1. Create and configure a Supabase project.
2. Create a new PowerSync instance, connecting to the database of the Supabase project. See instructions [here](https://docs.powersync.com/integration-guides/supabase-+-powersync#connect-powersync-to-your-supabase).
3. Deploy sync rules.

## Configure The App

1. Open this directory in XCode.

2. Copy the `_Secrets.swift` file to a new `Secrets.swift` file and insert the credentials of your Supabase and PowerSync projects (more info can be found [here](https://docs.powersync.com/integration-guides/supabase-+-powersync#test-everything-using-our-demo-app)).

```bash
cp _Secrets.swift Secrets.swift
```

### GRDB Implementation Details

This demo uses GRDB.swift for local data storage and querying. The key differences from the standard PowerSync demo are:

1. Queries and mutations are handled using GRDB's data access patterns
2. Observable database queries are implemented using GRDB's ValueObservation

### Troubleshooting

If you run into build issues, try:

1. Clear Swift caches

```bash
rm -rf ~/Library/Caches/org.swift.swiftpm
rm -rf ~/Library/org.swift.swiftpm
```

2. In Xcode:

- Reset Packages: File -> Packages -> Reset Package Caches
- Clean Build: Product -> Clean Build Folder.

## Run project

Build the project, launch the app and sign in or register a new user. The app demonstrates real-time synchronization of todo lists between multiple devices and the cloud, powered by PowerSync's offline-first architecture and GRDB's robust local database capabilities.
