//
//  BundleInfos.swift
//  Underbrim
//
//  Created by Richard Kunkli on 08/08/2024.
//

import Foundation

extension Bundle {
    var releaseVersionNumber: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
