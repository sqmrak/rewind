#include "rewind_playback.h"

#include <math.h>

void rewind_playback_reset(rewind_playback_t *state, double now, double position, int playing) {
    state->position = isfinite(position) && position > 0 ? position : 0;
    state->progressed_at = now;
    state->playing = playing != 0;
}

rewind_playback_status_t rewind_playback_update(rewind_playback_t *state, double now,
                                               double position, int playing) {
    if (!playing || !state->playing || now < state->progressed_at) {
        rewind_playback_reset(state, now, position, playing);
        return playing ? REWIND_PLAYBACK_WAITING : REWIND_PLAYBACK_IDLE;
    }
    if (isfinite(position) && position >= state->position + 0.05) {
        rewind_playback_reset(state, now, position, playing);
        return REWIND_PLAYBACK_ADVANCED;
    }
    return now - state->progressed_at >= 20.0 ? REWIND_PLAYBACK_STALLED : REWIND_PLAYBACK_WAITING;
}
