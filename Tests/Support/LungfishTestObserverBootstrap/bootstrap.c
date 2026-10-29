// bootstrap.c - Signs the test-state observer up with XCTest when a test bundle loads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 ruling QA-RELEASE-LOOP, section 4. The observer must be installed in every process that loads a test
// bundle, the one-class processes of the unit tier included, so no first-sorting test class can do it. This
// constructor runs when the bundle's image loads, before XCTest starts the bundle, and sends `install` to the
// observer class (`Tests/Support/LungfishTestSupport/TestStateObserver.swift`) and then, where the bundle has them,
// to the row and window checks (`Tests/Support/LungfishKitTestSupport/KitTestStateChecks.swift`) and the App checks
// (`Tests/LungfishAppTests/AppTestStateChecks.swift`). It names each class by its Objective-C name only, so this
// target links no Swift module and a bundle without a class loads unchanged.

#include "LungfishTestObserverBootstrap.h"

#if defined(__APPLE__)
#include <objc/message.h>
#include <objc/runtime.h>

static void LGESendInstall(const char *className) {
    Class target = objc_getClass(className);
    if (target == Nil) {
        return;
    }
    ((void (*)(Class, SEL))objc_msgSend)(target, sel_registerName("install"));
}

__attribute__((constructor)) static void LGEInstallTestStateObserver(void) {
    LGESendInstall("LGETestStateObserver");
    LGESendInstall("LGEKitTestStateChecks");
    LGESendInstall("LGEAppTestStateChecks");
}
#endif

int LGETestObserverBootstrapIsLinked(void) {
    return 1;
}
