#ifndef REWIND_PLAYBACK_H
#define REWIND_PLAYBACK_H

typedef struct {
    double position;
    double progressed_at;
    int playing;
} rewind_playback_t;

typedef enum {
    REWIND_PLAYBACK_IDLE = 0,
    REWIND_PLAYBACK_WAITING,
    REWIND_PLAYBACK_ADVANCED,
    REWIND_PLAYBACK_STALLED
} rewind_playback_status_t;

void rewind_playback_reset(rewind_playback_t *state, double now, double position, int playing);
rewind_playback_status_t rewind_playback_update(rewind_playback_t *state, double now,
                                               double position, int playing);

#endif
