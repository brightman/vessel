#ifndef WISELIFE_RECORDING_ATOMICS_H
#define WISELIFE_RECORDING_ATOMICS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Opaque storage keeps C atomic initialization and all accesses on the C side.
typedef struct WLRecordingAtomicInt32 WLRecordingAtomicInt32;

WLRecordingAtomicInt32 *WLRecordingAtomicInt32Create(size_t count, int32_t initialValue);
void WLRecordingAtomicInt32Destroy(WLRecordingAtomicInt32 *values);
bool WLRecordingAtomicInt32CompareExchange(WLRecordingAtomicInt32 *values, size_t index,
                                          int32_t expected, int32_t desired);
int32_t WLRecordingAtomicInt32Load(const WLRecordingAtomicInt32 *values, size_t index);

#endif
