//
//  CleanEnvironment.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Programs Underbrim starts run with its privacy permissions, so they get only
//  the variables they need: any program running as the user can set session-wide
//  variables (launchctl setenv), and some are read as options or code (PERL5OPT,
//  ZIPOPT, BASH_ENV, exported shell functions).
//

import Darwin
import Foundation

extension Process {
    /// The system's PATH, the real home and temporary folders (never the variables, which can
    /// be set), the locale, and `keeping` when this process has them.
    static func cleanEnvironment(keeping extra: [String] = []) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        if let user = getpwuid(getuid()), let home = user.pointee.pw_dir {
            environment["HOME"] = String(cString: home)
        }
        var temporary = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &temporary, temporary.count) > 0 {
            environment["TMPDIR"] = temporary.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"] + extra {
            environment[key] = parent[key]
        }
        return environment
    }
}
