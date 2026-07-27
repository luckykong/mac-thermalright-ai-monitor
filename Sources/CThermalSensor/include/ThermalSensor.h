// ThermalSensor.h — C interface for IOHIDEventSystemClient temperature reader
#pragma once

#include <stddef.h>
#include <stdint.h>

/// Read CPU and GPU temperatures via IOHIDEventSystemClient.
/// Returns -1 if sensor not available.
/// No sudo required on Apple Silicon.
void readThermalSensors(double *cpuTemp, double *gpuTemp);

/// Apply a brightness lookup table to the RGB bytes of an RGBA raster.
/// Kept in optimized C because doing three floating-point conversions per
/// channel in Swift was the largest always-on CPU hotspot.
void mactrMultiplyRGB(uint8_t *bytes, size_t pixelCount, double factor);
