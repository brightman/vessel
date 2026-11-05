#include "RecordingAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>

// Capture must never fall back to an implementation that locks the audio tap.
_Static_assert(sizeof(int32_t) == sizeof(int) && ATOMIC_INT_LOCK_FREE == 2,
               "Recording requires always-lock-free 32-bit integer atomics");

struct WLRecordingAtomicInt32 {
    _Atomic(int32_t) value;
};

WLRecordingAtomicInt32 *WLRecordingAtomicInt32Create(size_t count, int32_t initialValue) {
    if (count == 0 || count > SIZE_MAX / sizeof(WLRecordingAtomicInt32)) { return NULL; }
    WLRecordingAtomicInt32 *values = malloc(count * sizeof(*values));
    if (values == NULL) { return NULL; }
    for (size_t index = 0; index < count; ++index) {
        atomic_init(&values[index].value, initialValue);
    }
    return values;
}

void WLRecordingAtomicInt32Destroy(WLRecordingAtomicInt32 *values) {
    free(values);
}

bool WLRecordingAtomicInt32CompareExchange(WLRecordingAtomicInt32 *values, size_t index,
                                          int32_t expected, int32_t desired) {
    // Preserve the full barriers and non-spurious CAS result of the old API.
    return atomic_compare_exchange_strong_explicit(&values[index].value, &expected, desired,
                                                   memory_order_seq_cst, memory_order_seq_cst);
}

int32_t WLRecordingAtomicInt32Load(const WLRecordingAtomicInt32 *values, size_t index) {
    return atomic_load_explicit(&values[index].value, memory_order_seq_cst);
}
