// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Security

/// How the running binary is signed, for diagnosing permission grants that
/// "don't stick".
///
/// TCC keys Accessibility (and friends) on the app's code signature. A
/// team-signed binary keeps a stable identity across rebuilds; an ad-hoc one
/// (this repo's Debug config, so clean clones build without an Apple account)
/// gets a new signature hash on EVERY rebuild — so a grant made to yesterday's
/// build is invisible to today's, and System Settings still shows the old row
/// toggled on. That reads, from the user's side, as "granted but not
/// detected", and no number of relaunches fixes it.
enum CodeSigningInfo {
    struct Identity {
        let adHoc: Bool
        let teamID: String?
        let identifier: String?
        /// Hex cdhash — the value that changes per rebuild on ad-hoc builds.
        let cdhash: String?
    }

    /// kSecCodeInfoFlags bit for ad-hoc signatures (codesign.h CS_ADHOC; the
    /// constant isn't exposed to Swift).
    private static let csAdHocFlag: Int = 0x2

    static func current() -> Identity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var infoPointer: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoPointer
        ) == errSecSuccess, let info = infoPointer as? [String: Any] else { return nil }
        let flags = info[kSecCodeInfoFlags as String] as? Int ?? 0
        let cdhash = (info[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }
            .joined()
        return Identity(
            adHoc: flags & Self.csAdHocFlag != 0,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            cdhash: cdhash
        )
    }
}
