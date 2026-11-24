import CoreServices
import Foundation

/// Whether macOS lets Agent Trail send Claude its session links directly.
enum ClaudeLinkAccess: Equatable {
    /// Not asked yet, or the answer was reset (for example with tccutil). A
    /// rebuilt, ad-hoc-signed Agent Trail at the same path kept its answer
    /// (tested on macOS 15).
    case unknown
    case allowed
    case denied
}

/// Sends a link to one running process as the "open URL" Apple Event, the
/// event LaunchServices itself sends an app when it delivers a link.
/// LaunchServices picks the instance of a bundle that gets a link (the one
/// launched first); this event goes to the process named.
///
/// Unlike a link LaunchServices delivers, this event needs the Automation
/// permission for the target app (tested with Claude on macOS 15: without it,
/// macOS answers errAEEventWouldRequireUserConsent). Agent Trail sends it only
/// when "Open sessions in either instance" is on. Then macOS asks once, on
/// Agent Trail's behalf, before the first link; with the switch off it is
/// never sent. With a hardened runtime the app would also need the
/// com.apple.security.automation.apple-events entitlement; Agent Trail is
/// signed without one.
enum DirectLink {
    /// 'GURL', both the class and the id of the "open URL" event
    /// (kInternetEventClass, kAEGetURL).
    static let openURLEvent: FourCharCode = 0x4755_524C

    struct Result: Equatable {
        /// What macOS answered about permission: noErr, errAEEventNotPermitted,
        /// errAEEventWouldRequireUserConsent, or procNotFound.
        let permission: OSStatus
        /// noErr once the app's handler accepted the link; otherwise the reason.
        let status: OSStatus
    }

    /// Whether this app may send the "open URL" event to `pid`. With
    /// `askIfNeeded`, macOS asks the user when it has no answer yet, and this
    /// waits for that answer, so call it off the main thread.
    static func permission(for pid: pid_t, askIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return withExtendedLifetime(target) { () -> OSStatus in
            guard let address = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(address, openURLEvent, openURLEvent, askIfNeeded)
        }
    }

    /// Sends `link` to `pid` once macOS allows it, asking first when
    /// `askIfNeeded`. Waits for the permission answer and up to `timeout` for
    /// the reply, so call it off the main thread.
    static func send(_ link: String, to pid: pid_t, askIfNeeded: Bool, timeout: TimeInterval = 3) -> Result {
        let permission = permission(for: pid, askIfNeeded: askIfNeeded)
        guard permission == noErr else { return Result(permission: permission, status: permission) }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: openURLEvent, eventID: openURLEvent, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: link), forKeyword: AEKeyword(keyDirectObject))
        let status = withExtendedLifetime((target, event)) { () -> OSStatus in
            guard let message = event.aeDesc else { return OSStatus(paramErr) }
            var reply = AEDesc()
            defer { AEDisposeDesc(&reply) }
            // Never prompt here: the permission answer above already covers this event.
            let mode = AESendMode(kAEWaitReply) | AESendMode(kAENeverInteract)
                | AESendMode(kAEDoNotPromptForUserConsent)
            let sent = AESendMessage(message, &reply, mode, Int(timeout * 60))
            guard sent == noErr else { return sent }
            return handlerError(in: &reply)
        }
        return Result(permission: permission, status: status)
    }

    /// The access a permission answer means; nil when it says nothing about
    /// access (the app quit, or an unexpected error).
    static func access(for permission: OSStatus) -> ClaudeLinkAccess? {
        switch permission {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .unknown
        default: return nil
        }
    }

    /// The error number the handler put in its reply, or noErr.
    private static func handlerError(in reply: inout AEDesc) -> OSStatus {
        var number: Int32 = 0
        var type: DescType = 0
        var size = 0
        let found = AEGetParamPtr(&reply, AEKeyword(keyErrorNumber), DescType(typeSInt32), &type,
                                  &number, MemoryLayout<Int32>.size, &size)
        return found == noErr ? OSStatus(number) : noErr
    }
}
