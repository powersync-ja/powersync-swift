# PowerSync Swift SDK

## Run against a local kotlin build

* To run using the local kotlin build you need to apply the following change in the `Package.swift` file:

  ```swift
      dependencies: [
          .package(url: "https://github.com/powersync-ja/powersync-kotlin.git", exact: "x.y.z"), <-- Comment this
  //        .package(path: "../powersync-kotlin"), <-- Include this line and put in the path to you powersync-kotlin repo
  ```
* To quickly make a local build to apply changes you made in `powersync-kotlin` for local development in the Swift SDK run the gradle task `spmDevBuild` in `PowerSyncKotlin` in the `powersync-kotlin` repo. This will update the files and the changes will be reflected in the Swift SDK.
