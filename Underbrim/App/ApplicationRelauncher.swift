//
//  ApplicationRelauncher.swift
//  Underbrim
//
//  Created by Corentin132 on 03/10/2025.
//

import AppKit

@MainActor
enum ApplicationRelauncher {
    /// Quits, then opens this copy again once it's gone: a second copy started first would share the
    /// relay socket, the clipboard vault and the notch's place for a moment.
    static func restart() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#,
                            "restart", String(ProcessInfo.processInfo.processIdentifier), bundlePath]
        helper.environment = Process.cleanEnvironment()
        try? helper.run()
        NSApplication.shared.terminate(nil)
    }

    /// Where this copy really is: one run unmoved from Downloads is translocated to a place macOS removes
    /// on quit, so it reopens from the original (Security has no public call for that).
    static var bundlePath: String {
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let path = Bundle.main.bundlePath
        guard path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL"),
              let original = unsafeBitCast(symbol, to: OriginalPath.self)(Bundle.main.bundleURL as CFURL, nil)
        else { return path }
        return (original.takeRetainedValue() as URL).path
    }
}
