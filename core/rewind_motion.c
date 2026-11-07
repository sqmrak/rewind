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

/* one cubic bezier piece through (x0,y0) to (x3,y3); x must rise with t, which holds for every piece below */
static double piece(double time, const double p[8]) {
    double lower = 0.0, upper = 1.0;
    for (int i = 0; i < 40; ++i) {
        double middle = (lower + upper) * 0.5;
        double inverse = 1.0 - middle;
        double x = inverse * inverse * inverse * p[0] + 3.0 * inverse * inverse * middle * p[2] +
                   3.0 * inverse * middle * middle * p[4] + middle * middle * middle * p[6];
        if (x < time) lower = middle;
        else upper = middle;
    }
    double t = (lower + upper) * 0.5, inverse = 1.0 - t;
    return inverse * inverse * inverse * p[1] + 3.0 * inverse * inverse * t * p[3] +
           3.0 * inverse * t * t * p[5] + t * t * t * p[7];
}

/* the emphasized path of material 3: a fast rise to 0.4 in the first sixth, then a long settle */
static double emphasized(double time) {
    static const double first[8] = { 0.0, 0.0, 0.05, 0.0, 0.133333, 0.06, 0.166666, 0.4 };
    static const double second[8] = { 0.166666, 0.4, 0.208333, 0.82, 0.25, 1.0, 1.0, 1.0 };
    return piece(time, time <= 0.166666 ? first : second);
}

/* stiffness and damping ratio of the spring tokens, unit mass */
static int spring_token(rewind_motion_curve curve, double *stiffness, double *ratio) {
    switch (curve) {
    case REWIND_MOTION_M3_SPATIAL: *stiffness = 700.0; *ratio = 0.9; return 1;
    case REWIND_MOTION_M3_SPATIAL_FAST: *stiffness = 1400.0; *ratio = 0.9; return 1;
    case REWIND_MOTION_M3_SPATIAL_SLOW: *stiffness = 300.0; *ratio = 0.9; return 1;
    case REWIND_MOTION_M3_EFFECTS: *stiffness = 1600.0; *ratio = 1.0; return 1;
    case REWIND_MOTION_EXPRESSIVE_SPATIAL: *stiffness = 700.0; *ratio = 0.6; return 1;
    case REWIND_MOTION_EXPRESSIVE_SPATIAL_FAST: *stiffness = 1400.0; *ratio = 0.6; return 1;
    case REWIND_MOTION_EXPRESSIVE_SPATIAL_SLOW: *stiffness = 300.0; *ratio = 0.6; return 1;
    default: return 0;
    }
}

/* position of a spring that starts at 0 and rests at 1 */
static double damped(double seconds, double stiffness, double ratio) {
    double frequency = sqrt(stiffness);
    double decay = frequency * ratio;
    if (ratio >= 1.0) return 1.0 - exp(-decay * seconds) * (1.0 + decay * seconds);
    double oscillation = frequency * sqrt(1.0 - ratio * ratio);
    return 1.0 - exp(-decay * seconds) * (cos(oscillation * seconds) + decay / oscillation * sin(oscillation * seconds));
}

/* the last moment the spring is farther than a thousandth from rest, found backwards from a bound so a late swing back is never cut */
static double settle_seconds(double stiffness, double ratio) {
    double seconds = 1.5;
    while (seconds > 0.0 && fabs(1.0 - damped(seconds, stiffness, ratio)) <= 0.001) seconds -= 0.002;
    return seconds + 0.002;
}

double rewind_motion_duration(rewind_motion_curve curve) {
    double stiffness, ratio;
    if (spring_token(curve, &stiffness, &ratio)) return settle_seconds(stiffness, ratio);
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
    case REWIND_MOTION_M3_EMPHASIZED: return 0.5;
    case REWIND_MOTION_M3_EMPHASIZED_DECELERATE: return 0.4;
    case REWIND_MOTION_M3_EMPHASIZED_ACCELERATE: return 0.2;
    case REWIND_MOTION_M3_STANDARD: return 0.3;
    default: break;
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
    double stiffness, ratio;
    if (spring_token(curve, &stiffness, &ratio)) {
        double span = rewind_motion_duration(curve);
        return damped(time * span, stiffness, ratio) / damped(span, stiffness, ratio);
    }
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
    case REWIND_MOTION_POPUP_MODERN_ENTER: return bezier(time, 0.1, 0.7, 0.1, 1.0);
    case REWIND_MOTION_POPUP_MODERN_EXIT: return bezier(time, 0.3, 0.0, 0.8, 0.2);
    case REWIND_MOTION_M3_EMPHASIZED: return emphasized(time);
    case REWIND_MOTION_M3_EMPHASIZED_DECELERATE: return bezier(time, 0.1, 0.7, 0.1, 1.0);
    case REWIND_MOTION_M3_EMPHASIZED_ACCELERATE: return bezier(time, 0.3, 0.0, 0.8, 0.2);
    case REWIND_MOTION_M3_STANDARD: return bezier(time, 0.2, 0.0, 0.0, 1.0);
    case REWIND_MOTION_M3_SPATIAL:
    case REWIND_MOTION_M3_SPATIAL_FAST:
    case REWIND_MOTION_M3_SPATIAL_SLOW:
    case REWIND_MOTION_M3_EFFECTS:
    case REWIND_MOTION_EXPRESSIVE_SPATIAL:
    case REWIND_MOTION_EXPRESSIVE_SPATIAL_FAST:
    case REWIND_MOTION_EXPRESSIVE_SPATIAL_SLOW: break;
    /* the ease out and the ease in of UIKit */
    case REWIND_MOTION_POPUP_CLASSIC_ENTER: return bezier(time, 0.0, 0.0, 0.58, 1.0);
    case REWIND_MOTION_POPUP_CLASSIC_EXIT: return bezier(time, 0.42, 0.0, 1.0, 1.0);
    }
    return 0.0;
}
