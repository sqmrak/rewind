#include "rewind_layout.h"
#include <math.h>

rewind_playlist_header_geometry_t RewindPlaylistHeaderGeometry(
    double header_height, double content_offset, double scrim_height) {
    double stretch = content_offset < 0.0 ? -content_offset : 0.0;
    /* the scrim follows the artwork's stretched top during a downward pull */
    rewind_playlist_header_geometry_t geometry = {
        -stretch, header_height + stretch, -stretch, scrim_height + stretch
    };
    return geometry;
}

double rewind_player_controls_width(double small, double previous, double play, double gap) {
    return small * 2 + previous * 2 + play + gap * 4;
}

int rewind_player_controls(double width, double small, double previous, double play,
                           double gap, double positions[5]) {
    double sizes[5], available, x;
    int index;
    if (!positions) return 0;
    for (index = 0; index < 5; ++index) positions[index] = 0;
    if (!isfinite(width) || !isfinite(small) || !isfinite(previous) ||
        !isfinite(play) || !isfinite(gap) || small <= 0 || previous <= 0 ||
        play <= 0 || gap < 0) return 0;
    available = width - rewind_player_controls_width(small, previous, play, gap);
    if (available < -0.001) return 0;
    gap += fmax(0, available) / 4;
    sizes[0] = sizes[4] = small;
    sizes[1] = sizes[3] = previous;
    sizes[2] = play;
    x = 0;
    for (index = 0; index < 5; ++index) {
        positions[index] = x;
        x += sizes[index] + gap;
    }
    return 1;
}
