# PowerSync Swift Demo App

A Todo List app demonstrating the use of the PowerSync Swift SDK together with Supabase.

The PowerSync Swift SDK is an extension of the [PowerSync Kotlin Multiplatform SDK](https://github.com/powersync-ja/powersync-kotlin), and uses the API tool [SKIE](https://skie.touchlab.co/) and KMMBridge to generate and publish a native Swift SDK. More details about this configuration can be found in our blog [here](https://www.powersync.com/blog/using-kotlin-multiplatform-with-kmmbridge-and-skie-to-publish-a-native-swift-sdk).

The SDK reference for the PowerSync Swift SDK is available [here](https://docs.powersync.com/client-sdk-references/swift).

## Alpha Release

This SDK is currently in an alpha release and not suitable for production use, unless you have tested your use case(s) extensively. Breaking changes are still likely to occur.

## Set up your Supabase and PowerSync projects

To run this demo, you need Supabase and PowerSync projects. Detailed instructions for integrating PowerSync with Supabase can be found in [the integration guide](https://docs.powersync.com/integration-guides/supabase).

Follow this guide to:

1. Create and configure a Supabase project.
2. Create a new PowerSync instance, connecting to the database of the Supabase project. See instructions [here](https://docs.powersync.com/integration-guides/supabase-+-powersync#connect-powersync-to-your-supabase).
3. Deploy sync rules.

## Configure The App

Open the project in XCode.

Open the “_Secrets” file and insert the credentials of your Supabase and PowerSync projects (more info can be found [here](https://docs.powersync.com/integration-guides/supabase-+-powersync#test-everything-using-our-demo-app)).

### Finish XCode configuration

1. Clear Swift caches

```bash
rm -rf ~/Library/Caches/org.swift.swiftpm
rm -rf ~/Library/org.swift.swiftpm
```

2. In Xcode:

- Reset Packages: File -> Packages -> Reset Package Caches
- Clean Build: Product -> Clean Build Folder.

3. Enable CasePathMacros. We are using SwiftUI Navigation for the demo which requires this.

## Run project

Build the project, launch the app and sign in or register a new user.
