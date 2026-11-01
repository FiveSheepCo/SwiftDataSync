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

Call `setup` once, as early as possible, e.g. when the app launches, so pushes that launched the app are handled. The
`ModelContainer` has to be created by the `modelContainer` argument: the synchronizer finds its store while it's created.
Changes saved before the synchronizer observes the store aren't uploaded until they change again.

### Requirements

- **iCloud**: the iCloud capability with CloudKit, and the container passed as `containerName`.
- **Push Notifications** and the **Remote notifications** background mode, so other devices' changes arrive while the app
  isn't running. Forward the pushes to the synchronizer:

  ```swift
  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
      await SDSSynchronizer.shared.didReceiveRemoteNotification(userInfo: userInfo)
      return .newData
  }
  ```
- **The CloudKit schema**: records are created with the record type of each entity and a field for each synchronized property.
  Running a development build creates them in the development environment. Deploy the schema to production in the CloudKit
  Console before releasing a version that synchronizes new entities or properties, as production rejects unknown ones.
- **App groups**, to synchronize from app extensions too: set `SDSSynchronizer.appGroupToStoreSyncData` to an app group in
  the entitlements of the app and its extensions, before `SDSSynchronizer.shared` is used the first time. Synchronization data
  that an earlier version stored in the app's container is moved there.

### Turning Synchronizing Off and On

`stop()` stops synchronizing, e.g. when the user turns off a setting, without relaunching the app: nothing is uploaded or
downloaded, pushes and scheduled retries are ignored, and the state becomes `.stopped`. Local changes are still recorded,
so `start()` uploads them.

```swift
SDSSynchronizer.shared.stop()
SDSSynchronizer.shared.start()
```

### iCloud Accounts and Errors

- When the user signs into another iCloud account, the synchronizer starts over with it: local models stay, the previous
  account's synchronization data is forgotten, and local copies of other users' shares are removed.
- When the app's zone is missing, e.g. because the data was deleted on another device, it's created again and every local
  model is uploaded. When the user deleted the app's data in iCloud's settings (`CKError.Code.userDeletedZone`), nothing is
  uploaded again: synchronizing stops until `start()` or the next launch, and `SDSSynchronizationViewModel.state` shows the
  error, so the app can ask the user.
- Records CloudKit rejects, e.g. because a value is too large for a record, don't keep other changes from being synchronized.
  They're retried once they change, or after an hour, and the state shows an error until then. Records hold at most 1 MB,
  so store large data, e.g. images, as assets with `assetProperties`.

## Installation

SwiftDataSync can be installed like any other Swift package through the GitHub repository at [https://github.com/FiveSheepCo/SwiftDataSync](https://github.com/FiveSheepCo/SwiftDataSync).

## Usage

You can easily configure which properties to sync using the `SDSConfiguration`:

```swift
SDSConfiguration(swiftDataEntities: [
    .init(entity: Document.self, description: .sync(.with(["title", "folder"]), parentKey: "folder", isSharable: false)),
    .init(entity: Tag.self, description: .noSync)
])
```

Properties that aren't synchronized need a default value or have to be optional, as models downloaded from other devices
only have the synchronized values. Records leave out empty values, so clearing an optional value reaches other devices as
the record leaving out its key.

### Models That Several Devices Create

By default, every model gets a random record name. Models that several devices create independently for the same thing,
e.g. a subscription to the same podcast, then become duplicate records. Give such entities an `identity`: the names of
synchronized attributes whose values identify a model on every device.

```swift
SDSConfiguration(swiftDataEntities: [
    .init(entity: Subscription.self, description: .sync(.without(["lastOpened"]), identity: ["feedLink"])),
    .init(entity: EpisodeState.self, description: .sync(.without([]), identity: ["feedLink", "guid"]))
])
```

For these entities:

- The record is named `<Entity>.<SHA-256 of the identity values>`, the same on every device. Strings, numbers, booleans,
  dates (to the millisecond, the precision of CloudKit), URLs and data can be identity values.
- A downloaded record whose name isn't known yet is first matched to a saved local model with the same identity values.
  The model gets the record and its values instead of a duplicate being inserted.
- When another device uploaded the same identity first, the upload saves the changed keys over its record: as with any
  record, the last upload of a key wins.
- Changing an identity value deletes the record of the old values, and uploads the model as a new record.
- Two local models with the same identity values keep separate, randomly named records.
- Models with an identity can't be sharable. Records that were uploaded before the identity was configured keep their names.

## Contributing

Any help is greatly appreciated. Feel free to contribute through pull requests, raise issues, or provide feedback.

## License

SwiftDataSync is available under the MIT license. See the [LICENSE](LICENSE) file for more info.
