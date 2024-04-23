# SwiftDataSync

SwiftDataSync is a Swift package that syncs SwiftData and CoreData models to CloudKit. It addresses the limitations and issues present in the default syncing mechanism provided by SwiftData and CoreData.

## Features

- **Enhanced Syncing**: Provides robust syncing functionality for SwiftData and CoreData models to CloudKit.
- **Configurability**: Allows users to configure objects and properties for syncing in an include or exclude fashion.
- **Debuggable**: Open-source nature enables easy debugging, and pull requests are welcome for further enhancements.
- **Supports Sharing**: Enables sharing functionality which is lacking in the default syncing mechanisms.

## Getting Started

In most apps, getting started with SwiftDataSync is as easy as providing your `ModelContainer` and the iCloud container identifier:

```swift
SDSSynchronizer.shared.setup(
    containerName: "iCloud.co.fivesheep.test",
    modelContainer: .shared
)
```

## Installation

SwiftDataSync can be installed like any other Swift package through the GitHub repository at [https://github.com/FiveSheepCo/SwiftDataSync](https://github.com/FiveSheepCo/SwiftDataSync).

## Usage

You can easily configure which properties to sync using the `SDSConfiguration`:

```swift
SDSConfiguration(swiftDataEntities: [
    .init(entity: Document.self, description: .sync(.with([\Document.title]), parentKey: nil, isSharable: false)),
    .init(entity: Tag.self, description: .noSync)
])
```

## Contributing

Any help is greatly appreciated. Feel free to contribute through pull requests, raise issues, or provide feedback.

## License

SwiftDataSync is available under the MIT license. See the [LICENSE](LICENSE) file for more info.
