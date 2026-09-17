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

import XCTest
import ObjCExceptionGuard

final class ObjCExceptionGuardTests: XCTestCase {

    func testBlockRunsAndReportsSuccess() {
        var ran = false
        var message: NSString?
        let ok = ObjCRunCatching({ ran = true }, &message)
        XCTAssertTrue(ok)
        XCTAssertTrue(ran)
        XCTAssertNil(message)
    }

    func testRaisedExceptionBecomesFailureInsteadOfAbort() {
        var message: NSString?
        let ok = ObjCRunCatching({
            NSException(name: NSExceptionName("TapInstallBoom"), reason: "required condition is false").raise()
        }, &message)
        XCTAssertFalse(ok)
        XCTAssertTrue(message?.contains("TapInstallBoom") == true)
        XCTAssertTrue(message?.contains("required condition is false") == true)
    }

    func testNullDescriptionOutletIsAccepted() {
        let ok = ObjCRunCatching({
            NSException(name: NSExceptionName("AnyException"), reason: nil).raise()
        }, nil)
        XCTAssertFalse(ok)
    }
}
