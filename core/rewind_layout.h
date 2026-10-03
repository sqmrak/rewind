#ifndef REWIND_LAYOUT_H
#define REWIND_LAYOUT_H

typedef struct {
    double artwork_y;
    double artwork_height;
    double scrim_y;
    double scrim_height;
} rewind_playlist_header_geometry_t;

rewind_playlist_header_geometry_t RewindPlaylistHeaderGeometry(
    double header_height, double content_offset, double scrim_height);

/* widths include the play circle, so every neighbouring pair gets the same gap */
double rewind_player_controls_width(double small, double previous, double play, double gap);
int rewind_player_controls(double width, double small, double previous, double play,
                           double gap, double positions[5]);

#endif
