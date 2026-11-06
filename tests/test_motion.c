#include "rewind_motion.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static const rewind_motion_curve curves[] = {
    REWIND_MOTION_ENTER, REWIND_MOTION_EXIT, REWIND_MOTION_SPRING, REWIND_MOTION_NAVIGATION, REWIND_MOTION_LIST_MOVE,
    REWIND_MOTION_DISMISS, REWIND_MOTION_SHEET_DISMISS, REWIND_MOTION_POPUP_MODERN_ENTER, REWIND_MOTION_POPUP_MODERN_EXIT,
    REWIND_MOTION_POPUP_CLASSIC_ENTER, REWIND_MOTION_POPUP_CLASSIC_EXIT
};

int main(void) {
    unsigned i;
    int step;
    for (i = 0; i < sizeof(curves) / sizeof(curves[0]); ++i) {
        rewind_motion_curve curve = curves[i];
        double duration = rewind_motion_duration(curve);
        assert(duration > 0.1 && duration < 0.6);
        /* exact endpoints, and out of range or non finite time stays on them */
        assert(rewind_motion_progress(curve, 0) == 0);
        assert(rewind_motion_progress(curve, 1) == 1);
        assert(rewind_motion_progress(curve, -1) == 0);
        assert(rewind_motion_progress(curve, 2) == 1);
        assert(rewind_motion_progress(curve, NAN) == 0);
        assert(rewind_motion_progress(curve, INFINITY) == 0);
        /* the spring may overshoot, but boundedly; every other curve stays inside 0..1 and never moves back */
        double previous = 0;
        for (step = 1; step <= 100; ++step) {
            double value = rewind_motion_progress(curve, step / 100.0);
            assert(isfinite(value));
            if (curve == REWIND_MOTION_SPRING) {
                assert(value > -0.1 && value < 1.3);
            } else {
                assert(value >= 0 && value <= 1.0000001);
                assert(value >= previous - 1e-9);
            }
            previous = value;
        }
    }
    /* the leaving popup starts slowly in the classic style, and the entering one covers most of the way early in the modern one */
    assert(rewind_motion_progress(REWIND_MOTION_POPUP_CLASSIC_EXIT, 0.25) < 0.25);
    assert(rewind_motion_progress(REWIND_MOTION_POPUP_MODERN_ENTER, 0.25) > 0.6);
    assert(rewind_motion_progress(REWIND_MOTION_SPRING, 0.5) > 0.9);
    /* a value that is not a curve has no duration and no progress */
    assert(rewind_motion_duration((rewind_motion_curve)99) == 0);
    assert(rewind_motion_progress((rewind_motion_curve)99, 0.5) == 0);
    puts("test_motion ok");
    return 0;
}
