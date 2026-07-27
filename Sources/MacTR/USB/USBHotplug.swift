// USBHotplug.swift — IOKit notification-based USB connect/disconnect detection
//
// Watches for Thermalright LCD device attach/detach events using IOKit notifications.
// Does NOT use libusb hotplug (limited on macOS). Instead uses IOServiceMatching
// with kIOFirstMatchNotification and kIOTerminatedNotification.
//
// Usage:
//   let hotplug = USBHotplug()
//   hotplug.onConnect = { ... }
//   hotplug.onDisconnect = { ... }
//   hotplug.start()

import Foundation
import IOKit
import IOKit.usb

final class USBHotplug: @unchecked Sendable {

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    private var notifyPort: IONotificationPortRef?
    /// One iterator per (product, notification-type) registration. Each one has
    /// to stay retained for its notification to keep firing, so they are all
    /// kept here and released together in `stop()`. Reusing a single variable
    /// across products — as this used to do — leaks every registration but the
    /// last, and "fixing" that by releasing the previous value instead would
    /// silently disable hotplug detection for the first product ID.
    private var notificationIterators: [io_iterator_t] = []
    private let queue = DispatchQueue(label: "com.thermalvision.hotplug")

    func start() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }

        IONotificationPortSetDispatchQueue(notifyPort, queue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let registrations: [(notificationType: String, callback: IOServiceMatchingCallback)] = [
            (kIOFirstMatchNotification, deviceAdded),
            (kIOTerminatedNotification, deviceRemoved),
        ]

        for pid in USBDeviceIdentity.productIDs {
            for registration in registrations {
                // IOServiceAddMatchingNotification consumes a reference to the
                // matching dictionary, so build a fresh one per registration.
                guard let matching = Self.createMatchingDict(
                    vid: USBDeviceIdentity.vendorID, pid: pid)
                else { continue }

                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(
                    notifyPort,
                    registration.notificationType,
                    matching,
                    registration.callback,
                    selfPtr,
                    &iterator)
                guard result == KERN_SUCCESS, iterator != 0 else { continue }

                notificationIterators.append(iterator)
                // Arming the notification requires draining the initial matches.
                drainIterator(iterator)
            }
        }

        log("[Hotplug] Watching for device connect/disconnect")
    }

    func stop() {
        for iterator in notificationIterators {
            IOObjectRelease(iterator)
        }
        notificationIterators.removeAll()
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
        }
        notifyPort = nil
    }

    /// Whether the LCD is currently enumerated by IOKit (one-shot check).
    /// Static so `USBDevice` can tell "somebody else owns it" apart from
    /// "it was unplugged" without owning a hotplug watcher.
    static func isDevicePresent() -> Bool {
        for pid in USBDeviceIdentity.productIDs {
            guard let matching = createMatchingDict(
                vid: USBDeviceIdentity.vendorID, pid: pid)
            else { continue }
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            if result == KERN_SUCCESS {
                let service = IOIteratorNext(iterator)
                IOObjectRelease(iterator)
                if service != 0 {
                    IOObjectRelease(service)
                    return true
                }
            }
        }
        return false
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private static func createMatchingDict(vid: UInt16, pid: UInt16) -> CFMutableDictionary? {
        guard let dict = IOServiceMatching(kIOUSBDeviceClassName) else { return nil }
        let mutableDict = dict as NSMutableDictionary
        mutableDict[kUSBVendorID] = vid
        mutableDict[kUSBProductID] = pid
        return mutableDict
    }

    private func drainIterator(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}

// MARK: - C callbacks

private func deviceAdded(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    let hotplug = Unmanaged<USBHotplug>.fromOpaque(refcon!).takeUnretainedValue()
    // Drain iterator (required for notifications to keep firing)
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
    }
    log("[Hotplug] Device connected")
    hotplug.onConnect?()
}

private func deviceRemoved(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    let hotplug = Unmanaged<USBHotplug>.fromOpaque(refcon!).takeUnretainedValue()
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
    }
    log("[Hotplug] Device disconnected")
    hotplug.onDisconnect?()
}
