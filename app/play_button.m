#import "play_button.h"

static UIImage *TuneButtonImage(NSString *name) {
    return [UIImage imageNamed:name];
}

@implementation TunePlaybackButton

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _lightStyle = NO;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.adjustsImageWhenHighlighted = NO;
        self.accessibilityLabel = @"Play";
        [self updateButtonImage];
    }
    return self;
}

- (BOOL)isPlaying {
    return _playing;
}

- (void)setPlaying:(BOOL)playing {
    if (_playing == playing) return;
    _playing = playing;
    self.accessibilityLabel = playing ? @"Pause" : @"Play";
    [self updateButtonImage];
}

- (void)setLightStyle:(BOOL)lightStyle {
    if (_lightStyle == lightStyle) return;
    _lightStyle = lightStyle;
    [self updateButtonImage];
}

- (void)applyTheme {
    [self updateButtonImage];
}

- (void)updateButtonImage {
    NSString *name;
    if (_lightStyle)
        name = _playing ? @"player-pause-light.png" : @"player-play-light.png";
    else
        name = _playing ? @"player-pause.png" : @"player-play.png";
    [self setImage:TuneButtonImage(name) forState:UIControlStateNormal];
    self.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    self.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.clipsToBounds = YES;
}

@end

@implementation TuneRoundButton

- (id)initWithKind:(TuneRoundButtonKind)kind {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _kind = kind;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.adjustsImageWhenHighlighted = NO;
        if (kind == TuneRoundButtonKindStar) self.accessibilityLabel = @"Add to Library";
        else if (kind == TuneRoundButtonKindClose) self.accessibilityLabel = @"Close";
        else if (kind == TuneRoundButtonKindPrevious) self.accessibilityLabel = @"Previous track";
        else if (kind == TuneRoundButtonKindRepeat) self.accessibilityLabel = @"Repeat";
        else self.accessibilityLabel = @"Next track";
        [self updateButtonImage];
    }
    return self;
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    [self updateButtonImage];
}

- (void)applyTheme {
    [self updateButtonImage];
}

- (void)updateButtonImage {
    NSString *name = nil;
    switch (_kind) {
        case TuneRoundButtonKindPrevious:
            name = @"player-previous.png";
            break;
        case TuneRoundButtonKindNext:
            name = @"player-next.png";
            break;
        case TuneRoundButtonKindStar:
            name = _active ? @"player-star-on.png" : @"player-star-off.png";
            break;
        case TuneRoundButtonKindRepeat:
            name = _active ? @"player-repeat-on.png" : @"player-repeat.png";
            break;
        case TuneRoundButtonKindClose:
            name = @"player-close.png";
            break;
    }
    [self setImage:TuneButtonImage(name) forState:UIControlStateNormal];
    self.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    self.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.clipsToBounds = YES;
}

@end
