#include "rewind_layout.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    const double rows[] = {278, 286, 336, 502, 720};
    double x[5], sizes[] = {42, 45, 63, 45, 42};
    unsigned row;
    int index;
    const double offsets[] = {-240, -30, 0, 120};
    for (row = 0; row < sizeof(offsets) / sizeof(offsets[0]); ++row) {
        rewind_playlist_header_geometry_t g = RewindPlaylistHeaderGeometry(300, offsets[row], 80);
        double stretch = fmax(0, -offsets[row]);
        assert(g.artwork_y == -stretch && g.scrim_y == g.artwork_y);
        assert(g.artwork_height == 300 + stretch);
        assert(g.scrim_height == 80 + stretch);
        assert(g.scrim_y + g.scrim_height == 80);
    }
    for (row = 0; row < sizeof(rows) / sizeof(rows[0]); ++row) {
        assert(rewind_player_controls(rows[row], 42, 45, 63, 8, x));
        assert(x[0] == 0);
        assert(fabs(x[4] + sizes[4] - rows[row]) < 0.001);
        for (index = 1; index < 5; ++index)
            assert(x[index] - x[index - 1] - sizes[index - 1] >= 7.999);
        assert(fabs(x[2] + sizes[2] / 2 - rows[row] / 2) < 0.001);
    }
    assert(rewind_player_controls(269, 42, 45, 63, 8, x));
    assert(!rewind_player_controls(268, 42, 45, 63, 8, x));
    assert(!rewind_player_controls(NAN, 42, 45, 63, 8, x));
    assert(!rewind_player_controls(300, -1, 45, 63, 8, x));
    assert(!rewind_player_controls(300, 42, 45, 63, 8, NULL));
    puts("all player layout checks passed");
    return 0;
}
