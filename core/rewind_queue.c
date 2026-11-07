#include "rewind_queue.h"

size_t rewind_queue_remaining(size_t count, long index) {
    if (index < 0 || (size_t)index >= count) return 0;
    return count - (size_t)index - 1;
}

rewind_plural_t rewind_plural_form(size_t n, int russian) {
    if (!russian) return n == 1 ? REWIND_PLURAL_ONE : REWIND_PLURAL_MANY;
    size_t tens = n % 100;
    size_t units = n % 10;
    if (tens >= 11 && tens <= 14) return REWIND_PLURAL_MANY;
    if (units == 1) return REWIND_PLURAL_ONE;
    if (units >= 2 && units <= 4) return REWIND_PLURAL_FEW;
    return REWIND_PLURAL_MANY;
}
