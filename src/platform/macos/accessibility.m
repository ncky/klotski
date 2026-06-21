#include "platform/macos/accessibility.h"

#import <ApplicationServices/ApplicationServices.h>

bool kl_macos_accessibility_is_trusted(bool prompt)
{
    const void *keys[] = { kAXTrustedCheckOptionPrompt };
    const void *values[] = { prompt ? kCFBooleanTrue : kCFBooleanFalse };
    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    bool trusted = AXIsProcessTrustedWithOptions(options);
    CFRelease(options);
    return trusted;
}
