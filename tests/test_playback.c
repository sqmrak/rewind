#include "rewind_playback.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    rewind_playback_t state;
    rewind_playback_reset(&state, 100, 0, 1);
    assert(rewind_playback_update(&state, 119.9, 0, 1) == REWIND_PLAYBACK_WAITING);
    assert(rewind_playback_update(&state, 120, 0, 1) == REWIND_PLAYBACK_STALLED);
    rewind_playback_reset(&state, 200, 0, 1);
    assert(rewind_playback_update(&state, 219, 1, 1) == REWIND_PLAYBACK_ADVANCED);
    assert(rewind_playback_update(&state, 238, 1.02, 1) == REWIND_PLAYBACK_WAITING);
    assert(rewind_playback_update(&state, 239, NAN, 1) == REWIND_PLAYBACK_STALLED);
    assert(rewind_playback_update(&state, 300, 1, 0) == REWIND_PLAYBACK_IDLE);
    assert(rewind_playback_update(&state, 400, 1, 0) == REWIND_PLAYBACK_IDLE);
    assert(rewind_playback_update(&state, 500, 1, 1) == REWIND_PLAYBACK_WAITING);
    assert(rewind_playback_update(&state, 519, 2, 1) == REWIND_PLAYBACK_ADVANCED);
    /* seeking starts a new deadline, including backward seeks */
    rewind_playback_reset(&state, 520, 0, 1);
    assert(rewind_playback_update(&state, 521, 0.5, 1) == REWIND_PLAYBACK_ADVANCED);
    assert(rewind_playback_update(&state, 500, 0.5, 1) == REWIND_PLAYBACK_WAITING);
    assert(rewind_playback_update(&state, 519.9, INFINITY, 1) == REWIND_PLAYBACK_WAITING);
    assert(rewind_playback_update(&state, 520, INFINITY, 1) == REWIND_PLAYBACK_STALLED);
    puts("all playback checks passed");
    return 0;
}
