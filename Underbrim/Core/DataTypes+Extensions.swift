//
    //  DataTypes+Extensions.swift
    //  Underbrim
    //
    //  Created by Harsh Vardhan  Goswami  on 27/08/24.
    //

import Foundation

extension String {
    /// "٤٨٢٩١٠" → "482910": Arabic text and keyboards use Arabic-Indic digits, Swift's
    /// number parsing and code fields Western ones. One UTF-16 unit each way, so ranges hold.
    var westernDigits: String {
        String(String.UnicodeScalarView(unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0660...0x0669: Unicode.Scalar(scalar.value - 0x0660 + 0x30)!
            case 0x06F0...0x06F9: Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!
            default: scalar
            }
        }))
    }
}

extension Date {
    var date: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd"
        return dateFormatter.string(from: self)
    }

    var month: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM"
        return dateFormatter.string(from: self)
    }

    func dayOfTheWeek(dayOfWeek: Int) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE"
        let date = Calendar.current.date(bySetting: .weekday, value: dayOfWeek, of: self) ?? self
        return dateFormatter.string(from: date)
    }
}

extension NSSize {
    var s: String { "\(width.i)×\(height.i)" }

    var aspectRatio: Double {
        width / height
    }
    func scaled(by factor: Double) -> CGSize {
        CGSize(width: (width * factor).evenInt, height: (height * factor).evenInt)
    }
}

extension Int {
    var s: String {
        String(self)
    }
    var d: Double {
        Double(self)
    }
}

extension Double {
    @inline(__always) @inlinable var intround: Int {
        rounded().i
    }

    @inline(__always) @inlinable var i: Int {
        Int(self)
    }

    var evenInt: Int {
        let x = intround
        return x + x % 2
    }
}

extension CGFloat {
    @inline(__always) @inlinable var intround: Int {
        rounded().i
    }

    @inline(__always) @inlinable var i: Int {
        Int(self)
    }

    var evenInt: Int {
        let x = intround
        return x + x % 2
    }
}
