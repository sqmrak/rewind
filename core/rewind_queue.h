#ifndef REWIND_QUEUE_H
#define REWIND_QUEUE_H

#include <stddef.h>

typedef enum {
    REWIND_PLURAL_ONE = 0,
    REWIND_PLURAL_FEW,
    REWIND_PLURAL_MANY
} rewind_plural_t;

/* tracks after the current one, 0 for an empty queue or an index outside it */
size_t rewind_queue_remaining(size_t count, long index);

/* russian splits counts into one, few and many; english only has one and many */
rewind_plural_t rewind_plural_form(size_t n, int russian);

#endif
