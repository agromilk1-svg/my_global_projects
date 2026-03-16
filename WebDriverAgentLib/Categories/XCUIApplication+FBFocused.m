/**
 * Copyright (c) 2018-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "XCUIApplication+FBFocused.h"
#import "XCUIApplication+FBHelpers.h"

@implementation XCUIApplication (FBFocused)

- (id<FBElement>)fb_focusedElement {
  // Return the active element (element with keyboard focus)
  return (id<FBElement>)[self fb_activeElement];
}

@end
