import Foundation

/// Makes sure only one process synchronizes at a time, e.g. an app and its extensions that share the synchronization data.
///
/// The lease is stored in a file next to the synchronization data. The file is only locked while the lease is read and written,
/// as processes that are suspended while holding a file lock in a shared container get terminated.
/// While synchronizing, the lease is renewed regularly, so it expires when the holding process gets suspended or terminated.
final class SDSSyncLease: @unchecked Sendable {
    
    /// Thrown when another process holds the lease.
    struct UnavailableError: Error {}
    
    private struct Lease: Codable, Equatable {
        let ownerId: String
        let expiryDate: Date
    }
    
    static let duration: TimeInterval = 30
    
    private let url: URL?
    private let ownerId = UUID().uuidString
    private let heartbeatLock = NSLock()
    private var heartbeat: Task<Void, Never>?
    
    init(url: URL?) {
        self.url = url
    }
    
    /// Acquires the lease if no other process holds it and keeps renewing it until it is released.
    func acquire() -> Bool {
        let isHeld = updateLease { lease in
            guard let lease, lease.ownerId != ownerId, lease.expiryDate > .now else {
                return newLease()
            }
            return lease
        }
        guard isHeld else { return false }
        
        heartbeatLock.withLock {
            heartbeat?.cancel()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.duration / 3))
                    guard !Task.isCancelled, let self, self.renew() else { return }
                }
            }
        }
        return true
    }
    
    /// Renews the lease and returns whether this process still holds it.
    func renew() -> Bool {
        updateLease { lease in
            lease?.ownerId == ownerId ? newLease() : lease
        }
    }
    
    func release() {
        heartbeatLock.withLock {
            heartbeat?.cancel()
            heartbeat = nil
        }
        
        _ = updateLease { lease in
            lease?.ownerId == ownerId ? nil : lease
        }
    }
    
    private func newLease() -> Lease {
        Lease(ownerId: ownerId, expiryDate: .now.addingTimeInterval(Self.duration))
    }
    
    /// Replaces the lease with the result of `update` while the lease file is locked and returns whether this process holds the lease afterwards.
    private func updateLease(_ update: (Lease?) -> Lease?) -> Bool {
        guard let url else { return true }
        
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        // Synchronizing without the lease is better than not synchronizing at all
        guard descriptor >= 0 else { return true }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        
        // Other processes only hold the file lock for a moment, so waiting a little is enough
        var isLocked = false
        for _ in 0..<100 {
            isLocked = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            if isLocked { break }
            usleep(1_000)
        }
        guard isLocked else { return false }
        defer { flock(descriptor, LOCK_UN) }
        
        let lease = (try? handle.readToEnd()).flatMap { try? JSONDecoder().decode(Lease.self, from: $0) }
        let updatedLease = update(lease)
        
        if updatedLease != lease {
            try? handle.truncate(atOffset: 0)
            if let data = try? updatedLease.map(JSONEncoder().encode) {
                try? handle.write(contentsOf: data)
            }
        }
        
        return updatedLease?.ownerId == ownerId
    }
}
