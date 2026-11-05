import Foundation
import CloudKit

/// Records that CloudKit rejected for a reason that retrying doesn't fix, e.g. a value too large for a record, or a field type
/// the production schema doesn't have.
///
/// They're left out of uploads for a while, so they don't keep the other changes from being uploaded and downloads from
/// running. A record is uploaded again once it changes, as that might fix it, or once the time is up.
struct SDSRecordQuarantine: Sendable {

    /// How long a rejected record isn't uploaded, unless it changes.
    static let duration: TimeInterval = 60 * 60

    /// When the removal of a record last changed, as removals don't change, e.g. one CloudKit rejects as the user may only
    /// read a share. It's retried once the time is up.
    static let removalChangeDate = Date.distantPast

    /// A record CloudKit rejected: when its update last changed, and CloudKit's error.
    struct Rejection: Sendable {
        let lastChangeDate: Date
        let error: (any Error)?
    }

    private struct Entry: Sendable {
        /// When the record's update last changed when it was rejected.
        let lastChangeDate: Date
        let endDate: Date
        let error: (any Error)?
    }

    private var entries: [String: Entry] = [:]

    /// Whether a record isn't uploaded now. `lastChangeDate` is when its update last changed.
    func contains(_ recordName: String, lastChangeDate: Date, now: Date = .now) -> Bool {
        guard let entry = entries[recordName] else { return false }
        return entry.lastChangeDate == lastChangeDate && now < entry.endDate
    }

    /// How many records were rejected and aren't uploaded until their time is up, unless they change. Uploads fetch as many
    /// more updates, as they're left out, so ones whose time is up don't count.
    func count(now: Date = .now) -> Int {
        entries.values.count { now < $0.endDate }
    }

    /// Why CloudKit rejected the record it rejected last, which later uploads that leave the records out still report.
    func latestError(now: Date = .now) -> (any Error)? {
        entries.values.filter { $0.error != nil && now < $0.endDate }.max { $0.endDate < $1.endDate }?.error
    }

    /// Records whose time is up are forgotten, as they're uploaded again anyway.
    mutating func add(_ recordName: String, lastChangeDate: Date, error: (any Error)? = nil, now: Date = .now) {
        entries = entries.filter { now < $0.value.endDate }
        entries[recordName] = Entry(lastChangeDate: lastChangeDate, endDate: now.addingTimeInterval(Self.duration), error: error)
    }

    /// Whether CloudKit rejected a record for a reason that retrying it unchanged doesn't fix.
    static func isPermanentRejection(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }

        return switch error.code {
        case .invalidArguments, .limitExceeded, .referenceViolation, .constraintViolation, .serverRejectedRequest,
             .permissionFailure, .assetFileNotFound, .assetFileModified, .incompatibleVersion:
            true
        default:
            false
        }
    }
}
