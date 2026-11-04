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

### How Synchronizing Works

Saves of the observed store are recorded as pending changes, and synchronized shortly after: every synchronization
**downloads first, then uploads**. Local changes are thus uploaded over the newest values: an edit of a model that another
device deleted is discarded with the deletion, rather than uploaded as a partial record. Local changes that weren't
uploaded yet still win over downloaded values of the same keys. A model created on this device keeps its record, though:
e.g. after unsubscribing and subscribing again, the earlier deletion doesn't delete the new subscription. If the download
fails, the changes are uploaded anyway, edits only of records that still exist, except while every record is downloaded
again, e.g. after `resetSyncData()`: local models can be copies of records that weren't downloaded yet. Then nothing is
uploaded until every record was downloaded, also if single records failed, for up to three downloads.

Downloads are saved page by page, together with their change token. A long first download, e.g. on a new device, doesn't
keep every record in memory, and continues where it was if the app is suspended or terminated meanwhile. Records that
can't be stored yet, e.g. as a record they reference wasn't downloaded yet, or that failed to download, are kept next to
the synchronization data and tried again later, so they don't keep the download from moving on. So are records that can't
be stored as they are, e.g. as the store rejects their values, rather than stopping every download and upload.

A page whose save is interrupted, e.g. as the app is force-quit, is repaired with the next launch, which continues the
download where it was.

`hasDownloadedOnce` tells whether the user's data was downloaded completely at least once with the current iCloud account,
e.g. to tell data that isn't there yet from data that was deleted. After each launch it's `false` until the account was
checked, as it can change while the app isn't running, and again after it changed until it's checked. It's also `false`
after `resetSyncData()`, and after the store's objects vanished, e.g. as it was lost or rebuilt, until every record was
downloaded again. A download that was interrupted doesn't count.

Models that were saved while nothing observed the store, e.g. before `setup`, before the app adopted SwiftDataSync, or by a
process without it, are uploaded too: the first synchronization after `setup` looks for models without records and queues
them. So does switching to another iCloud account, and a missing zone, with every model. As nothing tells how old their
values are, they never overwrite what's in iCloud: if a record of the same name exists, e.g. because another device created
the same identity (see below), the record wins completely, also over values it lacks, which another device might have
cleared. Only models whose records don't exist are uploaded with their values. If such a model is edited before it's
uploaded, the edited keys are uploaded like any change.

Deletions are only recorded when models are deleted through a context, e.g. `ModelContext.delete(_:)`, once the deletion is
saved: one that's discarded before, e.g. by a rollback, isn't uploaded. Batch deletes, like
`ModelContext.delete(model:where:)`, change the store directly. Their records stay in iCloud, and models whose records
are known but that are gone from the store aren't taken for deletions: a lost or replaced store would otherwise delete the
data on every device. Every record is downloaded again with the next launch's first synchronization instead. If the store
was rebuilt with the same data, its models of entities without an identity are given the records whose values they have,
rather than becoming duplicates. Only the ones without such a record are uploaded, once everything was downloaded.

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
- **The CloudKit schema**: records are created with the record type of each entity and a field for each synchronized property,
  plus the asset field `SDSOverflow` for values too large for a record (see below). Production rejects record types and
  fields it doesn't have, and development builds only create the ones they happen to save, e.g. not a field whose value was
  always empty. Call `initializeSchema()` from a development build to create all of them, then deploy the schema to
  production in the CloudKit Console before releasing a version that synchronizes new entities or properties:

  ```swift
  #if DEBUG
  try await SDSSynchronizer.shared.initializeSchema()
  #endif
  ```

  It saves a record of every synchronized entity with every field set, in a zone of its own that it deletes again, so other
  devices never see them. Call it once `setup` found the store and the user is signed into iCloud.

  Records CloudKit rejects, e.g. as production doesn't have their type yet, are set aside for an hour or until they change,
  and the synchronizer's state is an `SDSSyncError` whose `isIncompleteUpload` is true and whose `underlyingError` is
  CloudKit's error, to show or log why. `forceDownload()`, e.g. a "Sync Now" button, tries them again right away.
- **App groups**, to synchronize from app extensions too: set `SDSSynchronizer.appGroupToStoreSyncData` to an app group in
  the entitlements of the app and its extensions, before `SDSSynchronizer.shared` is used the first time. Synchronization data
  that an earlier version stored in the app's container is moved there.

### Turning Synchronizing Off and On

`stop()` stops synchronizing, e.g. when the user turns off a setting, without relaunching the app: nothing is uploaded or
downloaded, pushes and scheduled retries are ignored, a running download stops after its current page, and the state
becomes `.stopped`. Local changes are still recorded, so `start()` uploads them.

```swift
SDSSynchronizer.shared.stop()
SDSSynchronizer.shared.start()
```

To start over instead, `resetSyncData()` forgets everything the synchronizer stored about iCloud's data: which objects
have records, the changes that weren't uploaded, change tokens and whether everything was downloaded. iCloud's data stays
as it is. Synchronizing stops, and the next `start()` downloads everything and uploads the local objects iCloud doesn't
have, like a new device. Local models without an identity, or without all of its values, are first matched with the
records that have their values, so they aren't duplicated, and local copies of other users' shares are removed, and
downloaded again. Changes made in
`beforeForgetting`, which runs once no synchronization runs anymore, aren't recorded, so they're never uploaded: an app can
empty its store there, to look at iCloud's data before deciding what to do with its own. If the data can't be forgotten,
e.g. as the disk is full, the reset throws, the data stays as it is, apart from local copies of other users' shares that
were removed already, which are downloaded again once a reset succeeds, and synchronizing stays stopped until `start()`:

```swift
try await SDSSynchronizer.shared.resetSyncData {
    // E.g. delete the local objects, so iCloud's data is downloaded into an empty store
}
SDSSynchronizer.shared.start()
```

### iCloud Accounts and Errors

- Signing out and back into the same account keeps the changes made meanwhile, and uploads only those. While the account
  is temporarily unavailable, e.g. until the user enters their password again, nothing is reset.
- When the user signs into another iCloud account, the synchronizer starts over with it: local models stay, the previous
  account's pending changes, shares and change tokens are forgotten, and local copies of other users' shares are removed.
  Every local model is uploaded to the new account without overwriting its data, see above. Models keep their record names,
  so switching back to an account doesn't duplicate them. A synchronization that runs while the account changes stops.
- When the app's zone is missing, e.g. because the data was deleted on another device, it's created again and every local
  model is uploaded, also by devices that find it created again by another one, without overwriting what's in it. When the user deleted the app's data in iCloud's settings (`CKError.Code.userDeletedZone`), nothing is
  uploaded again: synchronizing stops until `start()` or the next launch, and `SDSSynchronizationViewModel.state` shows the
  error, so the app can ask the user.
- When CloudKit asks to wait, e.g. while it throttles requests, the remaining changes are uploaded once the time is up, also
  if only some records of an upload were throttled.
- When the user's iCloud storage is full, uploads pause for half an hour, or until `start()`, `forceDownload()` (e.g. a
  "Sync Now" button) or the settings section's button, and the state shows `CKError.Code.quotaExceeded` with a description
  to show. Pushes don't end the pause. Downloads go on, and records
  aren't set aside. A full storage of the owner of a share only pauses uploads to shares.
- Records CloudKit rejects don't keep other changes from being synchronized. They're retried once they change, or after an
  hour, and the state shows an error until then.

### Large Values

Records hold at most 1 MB, not counting assets. Store large data that is always large, e.g. images, as assets with
`assetProperties`. Other texts and data that grow too large for a record, or a single value of 256 KB or more, are uploaded
in the asset field `SDSOverflow` instead of their fields, and other devices read them like any other value. Which values
go into the asset only depends on the model's values, so it's cleared once they fit again. Uploads only send the values
that changed, and the asset if a value in it changed, so edits of other values on other devices stay. Two devices that
edit two values in the same asset at the same time are the exception: the last upload of the asset wins. Only records that
need the field or had it get it, so a production schema without it keeps working until a value grows that large:
`initializeSchema()` creates it for every entity with texts or data. Identity values are never moved into the asset.

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

- The record is named `<Entity>.<SHA-256 of the identity values>`, the same on every device. Strings, integers, doubles,
  booleans, dates (to the millisecond, the precision of CloudKit), UUIDs, URLs and data can be identity values. A model
  without all of its identity values gets a randomly named record, like one without an identity.
- A downloaded record whose name isn't known yet is first matched to a saved local model with the same identity values.
  The model gets the record and its values instead of a duplicate being inserted.
- When another device uploaded the same identity first, the upload saves the changed keys over its record: as with any
  record, the last upload of a key wins. Models that were saved before synchronizing started are the exception: the record's
  values win, see above.
- Changing an identity value deletes the record of the old values once the change is saved, unless another model takes
  them in the same save, and uploads the model as a new record. Records that reference the model are uploaded again, so they reference the new record. Until they are, a
  relationship that cascades deletions from the model deletes their models on devices that download in between, which get
  them back with the new records: avoid cascading deletions to synchronized models from entities with an identity.
- Two local models with the same identity values keep separate, randomly named records. A model that changes to an identity
  another model has moves to a randomly named record too.
- Identity values have to be stored in the record, so they can't be `assetProperties`.
- Entities with an identity can't be sharable, below a sharable entity, or the parent of other entities: different users'
  shares could have records of the same identity, and deleting a parent's record would delete its children's records.
- Records that were uploaded before the identity was configured keep their names.

## Contributing

Any help is greatly appreciated. Feel free to contribute through pull requests, raise issues, or provide feedback.

## License

SwiftDataSync is available under the MIT license. See the [LICENSE](LICENSE) file for more info.
