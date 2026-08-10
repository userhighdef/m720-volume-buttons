#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDDeviceKeys.h>
#import <IOKit/hid/IOHIDKeys.h>

#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// Logitech M720 Triathlon over Bluetooth Low Energy.
static const int64_t M720_VENDOR_ID = 0x046d;
static const int64_t M720_PRODUCT_ID = 0xb015;

// macOS numbers extra mouse buttons from zero: 3 = Back, 4 = Forward.
static const int64_t BUTTON_BACK = 3;
static const int64_t BUTTON_FORWARD = 4;

// NX_KEYTYPE_* and system-defined event constants from ev_keymap.h.
static const int32_t NX_KEYTYPE_SOUND_UP_VALUE = 0;
static const int32_t NX_KEYTYPE_SOUND_DOWN_VALUE = 1;
static const int32_t NX_SUBTYPE_AUX_CONTROL_BUTTONS_VALUE = 8;
static const int32_t NX_KEY_DOWN_VALUE = 0x0a;
static const int32_t NX_KEY_UP_VALUE = 0x0b;

static volatile sig_atomic_t keep_running = 1;
static CFMachPortRef active_tap = NULL;
static bool captured_back_down = false;
static bool captured_forward_down = false;

// Unlike M720 button events, scroll events retain their physical HID sender.
extern CFTypeRef CGEventCopyIOHIDEvent(CGEventRef event);
extern uint64_t IOHIDEventGetSenderID(CFTypeRef event);

static void handle_signal(int signal_number) {
    (void)signal_number;
    keep_running = 0;
}

static bool accessibility_is_granted(void) {
    return AXIsProcessTrusted();
}

static void request_accessibility(void) {
    NSDictionary *options = @{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES,
    };
    (void)AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

static bool m720_is_connected(void) {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOHIDDeviceKey);
    if (matching == NULL) {
        return false;
    }

    int32_t vendor_id = (int32_t)M720_VENDOR_ID;
    int32_t product_id = (int32_t)M720_PRODUCT_ID;
    CFNumberRef vendor = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt32Type,
        &vendor_id);
    CFNumberRef product = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt32Type,
        &product_id);
    if (vendor == NULL || product == NULL) {
        if (vendor != NULL) CFRelease(vendor);
        if (product != NULL) CFRelease(product);
        CFRelease(matching);
        return false;
    }
    CFDictionarySetValue(matching, CFSTR(kIOHIDVendorIDKey), vendor);
    CFDictionarySetValue(matching, CFSTR(kIOHIDProductIDKey), product);
    CFRelease(vendor);
    CFRelease(product);

    // IOServiceGetMatchingService consumes the matching dictionary.
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (service == IO_OBJECT_NULL) {
        return false;
    }
    IOObjectRelease(service);
    return true;
}

static bool read_int_property(io_service_t service, CFStringRef key, int64_t *result) {
    CFTypeRef value = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        key,
        kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (value == NULL) {
        return false;
    }

    bool found = false;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        found = CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, result);
    }
    CFRelease(value);
    return found;
}

static bool scroll_event_is_from_m720(CGEventRef event) {
    CFTypeRef hid_event = CGEventCopyIOHIDEvent(event);
    if (hid_event == NULL) {
        return false;
    }
    uint64_t sender_id = IOHIDEventGetSenderID(hid_event);
    CFRelease(hid_event);
    if (sender_id == 0) {
        return false;
    }

    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(sender_id);
    if (matching == NULL) {
        return false;
    }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (service == IO_OBJECT_NULL) {
        return false;
    }

    int64_t vendor_id = -1;
    int64_t product_id = -1;
    bool found_vendor = read_int_property(service, CFSTR("VendorID"), &vendor_id)
        || read_int_property(service, CFSTR("idVendor"), &vendor_id);
    bool found_product = read_int_property(service, CFSTR("ProductID"), &product_id)
        || read_int_property(service, CFSTR("idProduct"), &product_id);
    IOObjectRelease(service);

    return found_vendor && found_product
        && vendor_id == M720_VENDOR_ID
        && product_id == M720_PRODUCT_ID;
}

static double horizontal_scroll_delta(CGEventRef event) {
    double point = CGEventGetDoubleValueField(event, kCGScrollWheelEventPointDeltaAxis2);
    if (point != 0.0) {
        return point;
    }
    double fixed = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2);
    if (fixed != 0.0) {
        return fixed;
    }
    return (double)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
}

static void post_media_key(int32_t key_type) {
    @autoreleasepool {
        const int32_t states[] = {NX_KEY_DOWN_VALUE, NX_KEY_UP_VALUE};
        for (size_t index = 0; index < sizeof(states) / sizeof(states[0]); ++index) {
            NSInteger data1 = (NSInteger)((key_type << 16) | (states[index] << 8));
            NSEvent *media_event = [NSEvent
                otherEventWithType:NSEventTypeSystemDefined
                location:NSZeroPoint
                modifierFlags:0
                timestamp:0
                windowNumber:0
                context:nil
                subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS_VALUE
                data1:data1
                data2:0];
            if (media_event == nil || media_event.CGEvent == NULL) {
                fprintf(stderr, "m720-volume-buttons: could not create media-key event\n");
                return;
            }
            CGEventPost(kCGHIDEventTap, media_event.CGEvent);
        }
    }
}

static void post_control_arrow(CGKeyCode key_code) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == NULL) {
        fprintf(stderr, "m720-volume-buttons: could not create keyboard event source\n");
        return;
    }

    CGEventRef down = CGEventCreateKeyboardEvent(source, key_code, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, key_code, false);
    if (down == NULL || up == NULL) {
        fprintf(stderr, "m720-volume-buttons: could not create desktop-switch event\n");
        if (down != NULL) CFRelease(down);
        if (up != NULL) CFRelease(up);
        CFRelease(source);
        return;
    }

    CGEventSetFlags(down, kCGEventFlagMaskControl);
    CGEventSetFlags(up, kCGEventFlagMaskControl);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    CFRelease(source);
}

static CGEventRef event_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *context) {
    (void)proxy;
    (void)context;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (active_tap != NULL && accessibility_is_granted()) {
            CGEventTapEnable(active_tap, true);
            fprintf(stderr, "m720-volume-buttons: event tap re-enabled\n");
        }
        return event;
    }

    if (type == kCGEventScrollWheel) {
        double horizontal = horizontal_scroll_delta(event);
        if (horizontal == 0.0 || !scroll_event_is_from_m720(event)) {
            return event;
        }

        // Actual M720 events on this Mac: tilt-left = -1, tilt-right = +1.
        if (horizontal < 0.0) {
            post_control_arrow(0x7b); // kVK_LeftArrow
            fprintf(stdout, "m720-volume-buttons: Wheel Left -> Previous Desktop\n");
        } else {
            post_control_arrow(0x7c); // kVK_RightArrow
            fprintf(stdout, "m720-volume-buttons: Wheel Right -> Next Desktop\n");
        }
        return NULL;
    }

    if (type != kCGEventOtherMouseDown && type != kCGEventOtherMouseUp) {
        return event;
    }

    int64_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
    if (button != BUTTON_BACK && button != BUTTON_FORWARD) {
        return event;
    }

    bool *captured_down = button == BUTTON_BACK
        ? &captured_back_down
        : &captured_forward_down;

    if (type == kCGEventOtherMouseUp && *captured_down) {
        *captured_down = false;
        return NULL;
    }
    // macOS does not retain an IOHID sender ID on M720 button 3/4 CGEvents.
    // Gate the global button numbers on the physical M720 being connected.
    if (!m720_is_connected()) {
        return event;
    }

    if (type == kCGEventOtherMouseDown) {
        *captured_down = true;
        if (button == BUTTON_FORWARD) {
            post_media_key(NX_KEYTYPE_SOUND_UP_VALUE);
            fprintf(stdout, "m720-volume-buttons: Forward -> Volume Up\n");
        } else {
            post_media_key(NX_KEYTYPE_SOUND_DOWN_VALUE);
            fprintf(stdout, "m720-volume-buttons: Back -> Volume Down\n");
        }
    }
    return NULL;
}

static int run_event_tap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventOtherMouseDown)
        | CGEventMaskBit(kCGEventOtherMouseUp)
        | CGEventMaskBit(kCGEventScrollWheel);
    active_tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        event_callback,
        NULL);
    if (active_tap == NULL) {
        fprintf(stderr, "m720-volume-buttons: could not create event tap\n");
        return 1;
    }

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault,
        active_tap,
        0);
    if (source == NULL) {
        fprintf(stderr, "m720-volume-buttons: could not create run-loop source\n");
        CFRelease(active_tap);
        active_tap = NULL;
        return 1;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(active_tap, true);
    fprintf(stdout, "m720-volume-buttons: active for Logitech M720 (046d:b015)\n");

    while (keep_running && accessibility_is_granted()) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    }

    CGEventTapEnable(active_tap, false);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CFRelease(active_tap);
    active_tap = NULL;
    captured_back_down = false;
    captured_forward_down = false;
    return 0;
}

static void print_usage(const char *program) {
    fprintf(
        stdout,
        "Usage: %s [--check | --request-permission | --volume-up | --volume-down | --previous-desktop | --next-desktop]\n",
        program);
}

int main(int argc, const char *argv[]) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);

    if (argc > 2) {
        print_usage(argv[0]);
        return 64;
    }
    if (argc == 2 && strcmp(argv[1], "--check") == 0) {
        bool accessibility = accessibility_is_granted();
        bool connected = m720_is_connected();
        fprintf(stdout, "Accessibility: %s\n", accessibility ? "granted" : "not granted");
        fprintf(stdout, "M720 (046d:b015): %s\n", connected ? "connected" : "not connected");
        return accessibility && connected ? 0 : 1;
    }
    if (argc == 2 && strcmp(argv[1], "--request-permission") == 0) {
        request_accessibility();
        return accessibility_is_granted() ? 0 : 1;
    }
    if (argc == 2 && strcmp(argv[1], "--volume-up") == 0) {
        post_media_key(NX_KEYTYPE_SOUND_UP_VALUE);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--volume-down") == 0) {
        post_media_key(NX_KEYTYPE_SOUND_DOWN_VALUE);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--previous-desktop") == 0) {
        post_control_arrow(0x7b);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--next-desktop") == 0) {
        post_control_arrow(0x7c);
        return 0;
    }
    if (argc == 2) {
        print_usage(argv[0]);
        return 64;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    bool permission_requested = false;
    while (keep_running) {
        if (!accessibility_is_granted()) {
            if (!permission_requested) {
                fprintf(stderr, "m720-volume-buttons: waiting for Accessibility permission\n");
                request_accessibility();
                permission_requested = true;
            }
            sleep(1);
            continue;
        }

        permission_requested = false;
        if (run_event_tap() != 0 && keep_running) {
            sleep(2);
        }
    }
    return 0;
}
