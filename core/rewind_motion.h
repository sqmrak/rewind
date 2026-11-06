#ifndef REWIND_MOTION_H
#define REWIND_MOTION_H

typedef enum rewind_motion_curve {
    REWIND_MOTION_ENTER,
    REWIND_MOTION_EXIT,
    REWIND_MOTION_SPRING,
    REWIND_MOTION_NAVIGATION,
    REWIND_MOTION_LIST_MOVE,
    /* a card or a menu that goes away: it starts to leave at once and settles, where EXIT starts slowly and the card seems to hang for a moment */
    REWIND_MOTION_DISMISS,
    /* a sheet that leaves: ease out in 250 ms */
    REWIND_MOTION_SHEET_DISMISS,
    /* the way every popup comes and goes, menus, dialogs and sheets, in the modern theme: the emphasized curves of material 3, a long deceleration in and a
       short sharp acceleration out */
    REWIND_MOTION_POPUP_MODERN_ENTER,
    REWIND_MOTION_POPUP_MODERN_EXIT,
    /* and in the classic theme: the ease out and the ease in of the system of the time, a little quicker and with no overshoot anywhere */
    REWIND_MOTION_POPUP_CLASSIC_ENTER,
    REWIND_MOTION_POPUP_CLASSIC_EXIT
} rewind_motion_curve;

double rewind_motion_duration(rewind_motion_curve curve);
/* normalized time, with exact endpoints and bounded spring overshoot */
double rewind_motion_progress(rewind_motion_curve curve, double time);

#endif
