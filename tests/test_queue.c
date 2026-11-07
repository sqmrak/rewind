#include "rewind_queue.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(rewind_queue_remaining(0, 0) == 0);
    assert(rewind_queue_remaining(5, 0) == 4);
    assert(rewind_queue_remaining(5, 3) == 1);
    assert(rewind_queue_remaining(5, 4) == 0);
    assert(rewind_queue_remaining(5, 5) == 0);
    assert(rewind_queue_remaining(5, -1) == 0);

    assert(rewind_plural_form(0, 0) == REWIND_PLURAL_MANY);
    assert(rewind_plural_form(1, 0) == REWIND_PLURAL_ONE);
    assert(rewind_plural_form(2, 0) == REWIND_PLURAL_MANY);
    assert(rewind_plural_form(21, 0) == REWIND_PLURAL_MANY);

    assert(rewind_plural_form(0, 1) == REWIND_PLURAL_MANY);
    assert(rewind_plural_form(1, 1) == REWIND_PLURAL_ONE);
    assert(rewind_plural_form(2, 1) == REWIND_PLURAL_FEW);
    assert(rewind_plural_form(4, 1) == REWIND_PLURAL_FEW);
    assert(rewind_plural_form(5, 1) == REWIND_PLURAL_MANY);
    assert(rewind_plural_form(11, 1) == REWIND_PLURAL_MANY);
    assert(rewind_plural_form(12, 1) == REWIND_PLURAL_MANY);
    assert(rewind_plural_form(14, 1) == REWIND_PLURAL_MANY);
    assert(rewind_plural_form(21, 1) == REWIND_PLURAL_ONE);
    assert(rewind_plural_form(22, 1) == REWIND_PLURAL_FEW);
    assert(rewind_plural_form(111, 1) == REWIND_PLURAL_MANY);
    assert(rewind_plural_form(101, 1) == REWIND_PLURAL_ONE);
    puts("all queue checks passed");
    return 0;
}
