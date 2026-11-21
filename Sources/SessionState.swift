import CoreGraphics
import Darwin
import Foundation

enum SessionState {
    static func canMountVolumes() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionUserIDKey as String] as? UInt32 == getuid(),
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }

        // WindowServer omits this key while the session is unlocked.
        guard let locked = session["CGSSessionScreenIsLocked"] else { return true }
        return locked as? Bool == false
    }
}
