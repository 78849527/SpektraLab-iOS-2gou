//  CrashLog.swift — why the app died last time.
//
//  A crash does not run `catch`. A Swift fatal error, a failed force-unwrap, a
//  bad pointer or an out-of-memory kill all take the process down without
//  giving it a chance to report anything, which is why importing a photo
//  "just closes" with no message anywhere.
//
//  The only thing the app itself can do is leave a note before it goes:
//  `NSSetUncaughtExceptionHandler` for Objective-C exceptions, and a handler
//  per fatal signal for everything below that. The next launch reads the note
//  and puts it on screen.
//
//  The handlers deliberately do very little. `UserDefaults` is not
//  async-signal-safe, but it is the only storage reachable without opening a
//  file inside a signal handler, and a note that occasionally fails to land is
//  better than none. After recording, the default handler is restored and the
//  signal re-raised so iOS still writes its own `.ips` report.

import Foundation

enum CrashLog {

    private static let key = "lastCrash"

    /// Install the handlers. Call once, as early as possible.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            record("exception \(exception.name.rawValue) — \(exception.reason ?? "no reason")")
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { received in
                record("signal \(received)")
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    private static func record(_ text: String) {
        UserDefaults.standard.set(text, forKey: key)
        UserDefaults.standard.synchronize()
    }

    /// The note left by the previous run, consumed once.
    static func take() -> String? {
        let value = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return value
    }
}
