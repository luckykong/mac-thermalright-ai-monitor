// ThermalSensor.m — IOHIDEventSystemClient-based temperature reader
//
// Reads CPU and GPU temperature on Apple Silicon without sudo.
// Based on fermion-star/apple_sensors (BSD 3-Clause License).
// Uses private IOKit HID API: IOHIDEventSystemClient.
//
// IMPORTANT: IOHIDEventSystemClient is created ONCE and reused
// to prevent memory leak (~4GB over hours of 0.5s polling).

#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <Foundation/Foundation.h>
#include "ThermalSensor.h"

// Private IOKit declarations (not in public headers)
typedef struct __IOHIDEvent *IOHIDEventRef;
#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);

#define IOHIDEventFieldBase(type) (type << 16)
#define kIOHIDEventTypeTemperature 15

// Persistent state — created once, reused across calls
static IOHIDEventSystemClientRef _system = NULL;
static CFDictionaryRef _match = NULL;

static void ensureInitialized(void) {
    if (_system) return;

    int page = 0xff00;
    int usage = 0x0005;
    CFNumberRef nums[2];
    CFStringRef keys[2];
    keys[0] = CFStringCreateWithCString(0, "PrimaryUsagePage", 0);
    keys[1] = CFStringCreateWithCString(0, "PrimaryUsage", 0);
    nums[0] = CFNumberCreate(0, kCFNumberSInt32Type, &page);
    nums[1] = CFNumberCreate(0, kCFNumberSInt32Type, &usage);
    _match = CFDictionaryCreate(0, (const void**)keys, (const void**)nums, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(keys[0]); CFRelease(keys[1]);
    CFRelease(nums[0]); CFRelease(nums[1]);

    _system = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientSetMatching(_system, _match);
}

void readThermalSensors(double *cpuTemp, double *gpuTemp) {
    *cpuTemp = -1;
    *gpuTemp = -1;

    ensureInitialized();
    if (!_system) return;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(_system);
    if (!services) return;

    long count = CFArrayGetCount(services);
    double cpuMax = 0, gpuMax = 0;
    int cpuFound = 0, gpuFound = 0;

    for (int i = 0; i < count; i++) {
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(sc, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;

        double temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease(event);

        if (temp <= 0 || temp > 150) continue;

        CFStringRef name = IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
        if (!name) continue;

        NSString *sensorName = (__bridge NSString *)name;

        if ([sensorName containsString:@"PMU tdie"] ||
            [sensorName containsString:@"CPU"] ||
            [sensorName containsString:@"pACC"] ||
            [sensorName containsString:@"eACC"]) {
            if (temp > cpuMax) cpuMax = temp;
            cpuFound = 1;
        }
        else if ([sensorName containsString:@"GPU"] ||
                 ([sensorName hasPrefix:@"PMU TP"] && [sensorName hasSuffix:@"g"])) {
            if (temp > gpuMax) gpuMax = temp;
            gpuFound = 1;
        }

        CFRelease(name);
    }

    if (cpuFound) *cpuTemp = cpuMax;
    if (gpuFound) *gpuTemp = gpuMax;

    CFRelease(services);
}

void mactrMultiplyRGB(uint8_t *bytes, size_t pixelCount, double factor) {
    if (!bytes || pixelCount == 0 || factor <= 1.0) return;

    // Gain is capped per pixel so the brightest channel lands exactly on 255.
    //
    // Scaling each channel independently and clipping drains saturation: a
    // channel already above 255/factor stops at the ceiling while the darker
    // channels keep climbing, so every vivid colour slides toward white. At the
    // default factor of 2.2 that turned the accent red (239,68,68) into a pale
    // (255,152,128) and Bongo Cat's pink paws (244,150,174) into pure white —
    // which is exactly how it looked on the panel while the preview window,
    // which never runs this pass, stayed correct.
    //
    // Capping instead preserves the ratios between channels, and therefore hue
    // and saturation. Dark pixels — nearly the whole dashboard — still receive
    // the full factor, because nothing there is close to clipping.
    double gainForPeak[256];
    gainForPeak[0] = factor;
    for (size_t peak = 1; peak < 256; peak++) {
        double ceilingGain = 255.0 / (double)peak;
        gainForPeak[peak] = factor < ceilingGain ? factor : ceilingGain;
    }

    for (size_t pixel = 0; pixel < pixelCount; pixel++) {
        uint8_t *rgba = bytes + pixel * 4;
        uint8_t peak = rgba[0] > rgba[1] ? rgba[0] : rgba[1];
        if (rgba[2] > peak) peak = rgba[2];
        if (peak == 0) continue;

        double gain = gainForPeak[peak];
        rgba[0] = (uint8_t)((double)rgba[0] * gain + 0.5);
        rgba[1] = (uint8_t)((double)rgba[1] * gain + 0.5);
        rgba[2] = (uint8_t)((double)rgba[2] * gain + 0.5);
    }
}
