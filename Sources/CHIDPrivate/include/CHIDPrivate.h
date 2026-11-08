#pragma once
#include <CoreFoundation/CoreFoundation.h>

// Private IOKit HID event-system API (exported by IOKit.framework, not in the public SDK headers).
// Own opaque type names so this module never clashes with IOKit's public hidsystem headers.
CF_ASSUME_NONNULL_BEGIN

typedef struct CF_BRIDGED_TYPE(id) __ATGHIDEventSystemClient *ATGHIDEventSystemClientRef;
typedef struct CF_BRIDGED_TYPE(id) __ATGHIDServiceClient *ATGHIDServiceClientRef;
typedef struct CF_BRIDGED_TYPE(id) __ATGHIDEvent *ATGHIDEventRef;

ATGHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;
int IOHIDEventSystemClientSetMatching(ATGHIDEventSystemClientRef client, CFDictionaryRef matching);
CFArrayRef _Nullable IOHIDEventSystemClientCopyServices(ATGHIDEventSystemClientRef client) CF_RETURNS_RETAINED;
CFTypeRef _Nullable IOHIDServiceClientCopyProperty(ATGHIDServiceClientRef service, CFStringRef key) CF_RETURNS_RETAINED;
ATGHIDEventRef _Nullable IOHIDServiceClientCopyEvent(ATGHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(ATGHIDEventRef event, int32_t field);

CF_ASSUME_NONNULL_END
