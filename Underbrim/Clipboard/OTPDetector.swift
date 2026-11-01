//
//  OTPDetector.swift
//  Underbrim
//
//  Finds a one-time verification code in notification text. Precision over
//  recall: a phone number or price shown as a fake "code to copy" is worse
//  than occasionally missing a real one — same trade-off iOS's own OTP
//  autofill makes (it also requires contextual signal, not bare digits).
//
//  Rules, in order:
//   1. A digit run of 4–8 digits (or two 3-digit groups joined by a dash/
//      space, e.g. "123-456") is a *candidate*.
//   2. A candidate is only accepted if a verification-related keyword
//      ("code", "otp", "verification", "passcode", "pin", …, in each of the
//      app's languages) appears within `keywordWindow` characters of it — this
//      keeps "call me at 9876543210" and "invoice #48293021" from matching.
//      A number whose nearest such word is a postal code's isn't a code.
//   3. Currency, percentage, and time-adjacent digits are rejected outright
//      even if a keyword happens to be nearby (e.g. "OTP fee is $500"), and
//      so are prices and dates in Chinese, Japanese and Korean ("1000円").
//   4. If no digit-only candidate is accepted, a secondary pass looks for a
//      short uppercase alphanumeric token (Steam Guard-style: "R7K9P2") next
//      to the same keyword set.
//

import Foundation

enum OTPDetector {
    /// Longest a real OTP/2FA code gets in practice; wider misses ambiguity
    /// with tracking numbers and account IDs.
    private static let digitCountRange = 4...8

    /// How close a keyword has to be to a candidate to count as context,
    /// measured in UTF-16 code units: wide enough for German's "Ihr Bestätigungscode für die
    /// Anmeldung bei … lautet: 482910" without matching a keyword three sentences away.
    private static let keywordWindow = 60

    /// Left out, as they also sit beside order numbers, prices and phone
    /// numbers: a bare "clave", "verifica", "TAN", "token", コード, 番号,
    /// 비밀번호, 승인번호, 密码 and "подтверждение".
    private static let keywords = Keywords(
        whole: [
            "verification", "one-time", "one time", "passcode", "otp",
            "security code", "confirmation code", "confirmation", "access code",
            "auth code", "authentication code", "two-factor", "2fa", "pin", "code",
            "bestätigungscode", "verifizierungscode", "sicherheitscode", "zugangscode", "anmeldecode",
            "freigabecode", "einmalcode", "einmalpasswort", "einmalkennwort",
            "código", "verificación", "de un solo uso", "clave de seguridad", "clave dinámica", "clave temporal",
            "usage unique", "mot de passe temporaire",
            "codice", "monouso",
            "verificação", "uso único", "senha temporária"
        ],
        starts: ["kod", "şifre", "doğrulama", "tek kullanımlık", "код", "парол", "одноразов"],
        anywhere: [
            "التحقق", "التفعيل", "لمرة واحدة", "الرقم السري", "رمز", "كود",
            "認証コード", "確認コード", "認証番号", "ワンタイムパスワード", "セキュリティコード", "パスコード", "暗証番号",
            "인증번호", "인증 번호", "인증코드", "확인코드", "보안코드", "일회용 비밀번호",
            "验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "一次性密码",
            "驗證碼", "認證碼", "動態密碼", "一次性密碼"
        ]
    )

    /// Used for the alphanumeric fallback only. Excludes bare "code"/"pin" —
    /// those two are common in non-OTP contexts too ("promo code SAVE20",
    /// "pin your location"), which is fine for the digit-only pass (a random
    /// 6-digit number near "code" is almost always a real OTP) but would
    /// wrongly accept a dictionary-word promo code like "SAVE20" here.
    private static let strongKeywords = Keywords(
        whole: [
            "verification", "one-time", "one time", "passcode", "otp",
            "security code", "confirmation code", "access code", "auth code",
            "authentication code", "two-factor", "2fa"
        ],
        anywhere: ["التحقق", "التفعيل", "لمرة واحدة"]
    )

    /// Postal codes: "ZIP code 94103", "code postal 75008", "الرمز البريدي 12345". Not a bare "posta" or
    /// "postale" (Turkish e-posta is email; La Banque Postale sends codes). The nearest word decides.
    /// Whole phrases come before the words in them, so "postal code" matches whole.
    private static let postalCodes = Keywords(
        whole: ["zip code", "postal code", "code postal", "código postal", "codice postale", "posta kodu", "postal"],
        anywhere: ["الرمز البريدي", "بريدي"]
    )

    /// Not beside a Latin letter or another digit ("ABC12345", a ten-digit phone number), but
    /// touching Chinese, Japanese or Korean text: "验证码482913，", "認証番号は482913です".
    private static let digitRunRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{Latin}\d])(?:\d{3}[-\s]\d{3}|\d{4,8})(?![\p{Latin}\d])"#
    )
    private static let alphanumericRegex = try! NSRegularExpression(
        pattern: #"\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{5,8}\b"#
    )

    /// Returns the code with any separators stripped, ready to paste into an
    /// OTP field — or nil if nothing in `text` clears the bar above.
    static func detect(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let text = text.westernDigits
        let ns = text as NSString

        if let match = bestDigitCandidate(in: text, ns: ns) {
            return match.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
        }

        return bestAlphanumericCandidate(in: text, ns: ns)
    }

    private static func bestDigitCandidate(in text: String, ns: NSString) -> String? {
        let matches = digitRunRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard !isExcluded(match.range, in: ns), hasNearbyKeyword(match.range, in: ns) else { continue }
            return ns.substring(with: match.range)
        }
        return nil
    }

    private static func bestAlphanumericCandidate(in text: String, ns: NSString) -> String? {
        let matches = alphanumericRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches where hasNearbyKeyword(match.range, in: ns, from: strongKeywords) {
            return ns.substring(with: match.range)
        }
        return nil
    }

    /// Currency amounts, percentages, and clock times shouldn't match even
    /// with a keyword nearby ("OTP delivery fee is $500", "meeting at 4:30").
    private static func isExcluded(_ range: NSRange, in ns: NSString) -> Bool {
        // Exclusions still apply when punctuation carries combining marks.
        let before = charBefore(range, in: ns)?.unicodeScalars.first
        let after = charAfter(range, in: ns)?.unicodeScalars.first

        if let before, "$€£¥₹﷼₩￥".unicodeScalars.contains(before) { return true }
        if let after, after == "%" || after == "٪" { return true }
        // Prices, years and dates in Chinese, Japanese and Korean: "1000円", "2026年", "1000원".
        if let after, "円元원年月日년월일時时".unicodeScalars.contains(after) { return true }
        if let after, after == ":" { return true }
        // "12:3456" reads as a time; "OTP:482910" is a code.
        if let before, before == ":", charBefore(NSRange(location: range.location - 1, length: 0), in: ns)?.isNumber == true { return true }
        if let after, after == "." || after == "٫" {
            // "500.00" is a decimal amount (a digit follows the point), not a code ending a sentence.
            let next = ns.substring(with: NSRange(location: range.location + range.length, length: min(3, ns.length - range.location - range.length)))
            if next.dropFirst().first?.isNumber == true { return true }
        }
        return false
    }

    private static func charBefore(_ range: NSRange, in ns: NSString) -> Character? {
        guard range.location > 0, range.location <= ns.length else { return nil }
        // Regex offsets are UTF-16 units; adjacent characters may span several.
        let adjacent = ns.rangeOfComposedCharacterSequence(at: range.location - 1)
        return ns.substring(with: adjacent).first
    }

    private static func charAfter(_ range: NSRange, in ns: NSString) -> Character? {
        let end = range.location + range.length
        guard end >= 0, end < ns.length else { return nil }
        let adjacent = ns.rangeOfComposedCharacterSequence(at: end)
        return ns.substring(with: adjacent).first
    }

    private static func hasNearbyKeyword(_ range: NSRange, in ns: NSString, from list: Keywords = keywords) -> Bool {
        let windowStart = max(0, range.location - keywordWindow)
        let windowEnd = min(ns.length, NSMaxRange(range) + keywordWindow)
        let before = fold(ns.substring(with: NSRange(location: windowStart, length: range.location - windowStart)))
        let after = fold(ns.substring(with: NSRange(location: NSMaxRange(range), length: windowEnd - NSMaxRange(range))))
        guard let keyword = list.distance(before: before, after: after) else { return false }
        // A postal word at least as near is the number's own ("ZIP code 94103" has "code" too).
        return postalCodes.distance(before: before, after: after).map { $0 > keyword } ?? true
    }

    /// Case, accents and full width set aside, as messages often drop them ("codigo", "SIFRENIZ"), and
    /// Turkish's dotless ı read as i (lowercased "ŞİFRENİZ" has a stray dot).
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }

    private struct Keywords {
        private let regex: NSRegularExpression

        /// `whole` as whole words, so "shipping", "decode" or "footprint" aren't
        /// "pin", "code" and "otp"; `starts` at a word's start, for the endings
        /// Turkish and Russian add ("kodunuz", "кода", but not "промокод");
        /// `anywhere` as written: Arabic attaches ال, و and ب to the word, and
        /// Chinese, Japanese and Korean don't put spaces between words.
        init(whole: [String], starts: [String] = [], anywhere: [String] = []) {
            // Only a Latin or Cyrillic letter carries a word on: "您的OTP为" has "otp" in it.
            let letter = #"[\p{Latin}\p{Cyrillic}]"#
            func oneOf(_ words: [String]) -> String {
                "(?:" + words.map { NSRegularExpression.escapedPattern(for: OTPDetector.fold($0)) }.joined(separator: "|") + ")"
            }
            var patterns = ["(?<!\(letter))\(oneOf(whole))(?!\(letter))"]
            if !starts.isEmpty { patterns.append("(?<!\(letter))\(oneOf(starts))") }
            if !anywhere.isEmpty { patterns.append(oneOf(anywhere)) }
            regex = try! NSRegularExpression(pattern: patterns.joined(separator: "|"))
        }

        /// How near the nearest one is to a number between `before` and `after` (folded), in UTF-16 units.
        func distance(before: String, after: String) -> Int? {
            let length = (before as NSString).length
            let fromBefore = regex.matches(in: before, range: NSRange(location: 0, length: length)).last
                .map { length - NSMaxRange($0.range) }
            let fromAfter = regex.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length))?
                .range.location
            return [fromBefore, fromAfter].compactMap { $0 }.min()
        }
    }
}
