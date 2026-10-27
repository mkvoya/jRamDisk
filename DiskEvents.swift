import Foundation
import DiskArbitration

/// Disk Arbitration delivers device changes even when no volume is mounted.
/// The owner creates/releases this observer on the main thread, which is also
/// the delivery queue, so the callback context cannot outlive the observer.
final class DiskEvents {
    private let session: DASession
    let onChange: @Sendable () -> Void

    init?(onChange: @escaping @Sendable () -> Void) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppeared, context)
        DARegisterDiskDisappearedCallback(session, nil, diskAppeared, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, diskDescriptionChanged, context)
        DASessionSetDispatchQueue(session, .main)
    }

    deinit { DASessionSetDispatchQueue(session, nil) }
}

private let diskAppeared: DADiskAppearedCallback = { _, context in
    guard let context else { return }
    Unmanaged<DiskEvents>.fromOpaque(context).takeUnretainedValue().onChange()
}

private let diskDescriptionChanged: DADiskDescriptionChangedCallback = { _, _, context in
    guard let context else { return }
    Unmanaged<DiskEvents>.fromOpaque(context).takeUnretainedValue().onChange()
}
