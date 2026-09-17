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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning a raised NSException into a return value instead of
/// an abort. Swift's `do/catch` cannot catch ObjC exceptions — this function
/// is that boundary for the AVAudioEngine calls that raise (not throw) when
/// an input device vanishes mid-build.
///
/// Returns YES if the block completed, NO if it raised (with a human-readable
/// description of the exception written to ` _Nullable exceptionDescription`).
BOOL ObjCRunCatching(NS_NOESCAPE void (^block)(void),
                     NSString *_Nullable *_Nullable exceptionDescription);

NS_ASSUME_NONNULL_END
