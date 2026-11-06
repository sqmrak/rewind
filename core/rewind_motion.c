#include "rewind_motion.h"

#include <math.h>

static double cubic(double t, double first, double second) {
    double inverse = 1.0 - t;
    return 3.0 * inverse * inverse * t * first + 3.0 * inverse * t * t * second + t * t * t;
}

static double bezier(double time, double x1, double y1, double x2, double y2) {
    double lower = 0.0, upper = 1.0;
    /* bisection stays bounded where a bezier endpoint has zero derivative */
    for (int i = 0; i < 32; ++i) {
        double middle = (lower + upper) * 0.5;
        if (cubic(middle, x1, x2) < time) lower = middle;
        else upper = middle;
    }
    return cubic((lower + upper) * 0.5, y1, y2);
}

double rewind_motion_duration(rewind_motion_curve curve) {
    switch (curve) {
    case REWIND_MOTION_ENTER: return 0.32;
    case REWIND_MOTION_EXIT: return 0.18;
    case REWIND_MOTION_SPRING: return 0.48;
    case REWIND_MOTION_NAVIGATION: return 0.32;
    case REWIND_MOTION_LIST_MOVE: return 0.25;
    case REWIND_MOTION_DISMISS: return 0.2;
    case REWIND_MOTION_SHEET_DISMISS: return 0.25;
    case REWIND_MOTION_POPUP_MODERN_ENTER: return 0.34;
    case REWIND_MOTION_POPUP_MODERN_EXIT: return 0.2;
    case REWIND_MOTION_POPUP_CLASSIC_ENTER: return 0.25;
    case REWIND_MOTION_POPUP_CLASSIC_EXIT: return 0.2;
    }
    return 0.0;
}

static double spring(double seconds) {
    /* stiffness 650, damping ratio 0.6, unit mass */
    double frequency = sqrt(650.0), damping = 0.6;
    double decay = frequency * damping;
    double oscillation = frequency * sqrt(1.0 - damping * damping);
    return 1.0 - exp(-decay * seconds) *
        (cos(oscillation * seconds) + decay / oscillation * sin(oscillation * seconds));
}

double rewind_motion_progress(rewind_motion_curve curve, double time) {
    if (rewind_motion_duration(curve) == 0.0) return 0.0;
    if (!isfinite(time) || time <= 0.0) return 0.0;
    if (time >= 1.0) return 1.0;
    switch (curve) {
    /* ease out quint in, ease in out */
    case REWIND_MOTION_ENTER: return bezier(time, 0.23, 1.0, 0.32, 1.0);
    case REWIND_MOTION_EXIT: return bezier(time, 0.42, 0.0, 1.0, 1.0);
    case REWIND_MOTION_SPRING:
        return spring(time * rewind_motion_duration(curve)) / spring(rewind_motion_duration(curve));
    case REWIND_MOTION_NAVIGATION: {
        /* decelerate with factor 1.5, for opening and closing screens */
        double remaining = 1.0 - time;
        return 1.0 - remaining * remaining * remaining;
    }
    /* 250 ms for rows that move and rows that are added */
    case REWIND_MOTION_LIST_MOVE: return bezier(time, 0.19919472913616398, 0.010644531250000006, 0.27920937042459737, 0.91025390625);
    case REWIND_MOTION_DISMISS: {
        double remaining = 1.0 - time;
        return 1.0 - remaining * remaining;
    }
    /* 250 ms ease out: the quint of the way in covers most of the distance in the first frames and then crawls, which reads as a jerk on a sheet that leaves */
    case REWIND_MOTION_SHEET_DISMISS: return bezier(time, 0.0, 0.0, 0.58, 1.0);
    /* material 3: emphasized decelerate in, emphasized accelerate out */
    case REWIND_MOTION_POPUP_MODERN_ENTER: return bezier(time, 0.05, 0.7, 0.1, 1.0);
    case REWIND_MOTION_POPUP_MODERN_EXIT: return bezier(time, 0.3, 0.0, 0.8, 0.15);
    /* the ease out and the ease in of UIKit */
    case REWIND_MOTION_POPUP_CLASSIC_ENTER: return bezier(time, 0.0, 0.0, 0.58, 1.0);
    case REWIND_MOTION_POPUP_CLASSIC_EXIT: return bezier(time, 0.42, 0.0, 1.0, 1.0);
    }
    return 0.0;
}
