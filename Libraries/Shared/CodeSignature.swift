//
//  CodeSignature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Programs Underbrim starts from places other software can write to (the codex
//  tool, Lunar) run with its privacy permissions, so they start only when signed
//  by their developer. The check runs right before each start, on that file.
//

import Foundation
import Security

enum CodeSignature {
    /// OpenAI's Developer ID team, which signs the Codex app and its command-line tool.
    static let openAI = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
    static let lunar = "identifier \"fyi.lunar.Lunar\" and anchor apple generic and certificate leaf[subject.OU] = \"RDDXV84A73\""

    static func satisfies(_ url: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), compiled) == errSecSuccess
    }
}
