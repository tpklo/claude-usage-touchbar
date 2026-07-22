// claude-touchbar — a Claude mascot that paces the Touch Bar and reacts to how
// much of your usage window you have burned.
//
// The app holds no credentials and opens no sockets: it shells out to
// ~/bin/claude-touchbar.sh --raw and draws the three numbers it prints. That
// script is the only thing that touches the keychain, via /usr/bin/security,
// which is already on the item's ACL — so nothing ever prompts.
//
// Build & run:  make run
//
// Why private API: a Control Strip tray item is a fixed narrow slot with no
// width control of any kind (checked the public headers and every private
// method on NSTouchBarItem — none exist). A wide surface is only reachable via
// +[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:].
// placement 0 shares the bar with the Control Strip; placement 1 covers it.

#import <Cocoa/Cocoa.h>
#import "clawd_presets.h"
#import <string.h>

extern void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL show);

@interface NSTouchBar (PrivateSPI)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar
                         placement:(long long)placement
          systemTrayItemIdentifier:(NSTouchBarItemIdentifier)ident;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)bar;
@end

static NSTouchBarItemIdentifier const kSceneID = @"local.claude-touchbar.scene";
static NSTouchBarItemIdentifier const kEscID   = @"local.claude-touchbar.esc";
static NSString *const kScript = @"~/bin/claude-touchbar.sh --raw";

// Measured with `make ruler`, which draws ticks at fixed coordinates: the last
// legible label is 600, so that is the usable width beside the Control Strip.
// The window reports 685pt, but part of that is never presented — trusting the
// window figure clipped the third readout cell clean off.
static CGFloat const kSceneW = 600.0;
static CGFloat const kSceneH = 30.0;
static double  const kFPS    = 15.0;    // both reference pet apps land at 14-18

// Readout: every limit gets an identical cell — label, percentage, bar — laid
// out side by side so they can be compared at a glance. Earlier versions gave
// 5h and 7d a row each and demoted the per-model cap to a bare number with no
// bar, which made the one number you could not compare the odd one out.
#define READ_W    300.0
#define READ_X    (kSceneW - READ_W - 8)   // right-aligned: usage is the thing
                                           // you look for, so it sits where the
                                           // eye lands last and stays put
#define CELL_GAP    9.0
// 30pt of height only fits two tiers. A third one for the countdown pushed the
// labels off the top edge, so the countdown rides alongside the first label.
#define BAR_Y       3.0
#define BAR_H       8.0
#define TEXT_Y     14.0

#pragma mark - Mood

// Mood is a pure function of the 5h burn: the pet's behaviour IS the gauge.
typedef NS_ENUM(NSInteger, Mood) { MoodCalm, MoodBrisk, MoodTired, MoodPanic };

static Mood MoodForUsage(int p5) {
    if (p5 >= 85) return MoodPanic;
    if (p5 >= 60) return MoodTired;
    if (p5 >= 30) return MoodBrisk;
    return MoodCalm;
}

static CGFloat SpeedForMood(Mood m) {
    switch (m) {
        case MoodCalm:  return 34.0;    // points per second
        case MoodBrisk: return 62.0;
        case MoodTired: return 20.0;    // worn out, slows down
        case MoodPanic: return 96.0;    // running around
    }
}

#pragma mark - Scene

// Clawd either paces (drawn from the sprite sheet below) or stops to perform a
// canned animation lifted straight out of Claude.app's own assets.
typedef NS_ENUM(NSInteger, Act) { ActWalk, ActClip, ActJuggle };

// Which official clip suits each mood. Indices follow kClawdClips order:
// 0 breathe 1 blink 2 look_around 3 wink 4 surprise 5 sleep 6 bounce 7 sway 8 think
// Pools per mood, with the previous pick excluded so the same clip never runs
// twice in a row. Panic used to be a single clip on a short cycle, which is the
// worst case: at high usage you see one animation on repeat.
static int ClipForMood(Mood m, int previous) {
    static const int calm[]  = {0,1,2,9,3};        // idle, laptop, wink
    static const int brisk[] = {6,7,3,10,11,12,2}; // dancing + DJ + a glance
    static const int tired[] = {8,5,9,0,1};        // thinking, sleeping, breathing
    static const int panic[] = {4,6,10,12,7};      // startled, then frantic motion

    const int *pool; int n;
    switch (m) {
        case MoodCalm:  pool = calm;  n = sizeof(calm)  / sizeof(int); break;
        case MoodBrisk: pool = brisk; n = sizeof(brisk) / sizeof(int); break;
        case MoodTired: pool = tired; n = sizeof(tired) / sizeof(int); break;
        default:        pool = panic; n = sizeof(panic) / sizeof(int); break;
    }
    for (int tries = 0; tries < 8; tries++) {
        int pick = pool[arc4random_uniform(n)];
        if (pick != previous) return pick;
    }
    return pool[0];
}

@interface PetView : NSView
@property (nonatomic) int p5, p7, resetMin, ageSec, scopedPct;
@property (nonatomic, copy) NSString *scopedName;   // per-model weekly cap (e.g. Fable)
@property (nonatomic, copy) NSString *state;   // ok | stale | expired | none
@property (nonatomic) CGFloat x, dir, phase;
@property (nonatomic) BOOL haveData;
@property (nonatomic) Act act;
@property (nonatomic) NSInteger clip;           // frame index within the clip
@property (nonatomic) NSInteger clipIdx;        // which clip in kClawdClips
@property (nonatomic) NSTimeInterval clipT, sinceAct;
@property (nonatomic) CGFloat ballY, ballV;   // juggled ball: height above his head, velocity
@property (nonatomic) BOOL dragging;
@property (nonatomic) CGFloat grabDX, dragVX, lastDragX, throwVX, wiggleT;
@property (nonatomic) CGFloat nextActAt;
@property (nonatomic) NSInteger lastClipIdx, clipLoops;
@end

@implementation PetView

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _x = 40; _dir = 1; _p5 = 0; _p7 = 0; _resetMin = -1;
        _act = ActWalk;
        _nextActAt = 4.0;
        _lastClipIdx = -1;
        // Without this the view gets direct touches only intermittently.
        self.allowedTouchTypes = NSTouchTypeMaskDirect;
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

// The system resizes this view to whatever the bar actually offers; asking for
// more just gets clipped. Report the real number instead of guessing.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // Warn if a future macOS gives us a different bar than the one this was
    // sized against, instead of silently drawing off-screen.
    CGFloat win = self.window ? NSWidth(self.window.frame) : 0;
    if (win > 0 && kSceneW > win)
        NSLog(@"claude-touchbar: scene %.0fpt wider than the %.0fpt bar — content will be clipped", kSceneW, win);
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

// Touch. A view must opt in to direct touches or it receives them only
// sporadically — that inconsistency cost four rounds of testing to spot.
- (void)touchesBeganWithEvent:(NSEvent *)e {
    NSTouch *t = [e touchesMatchingPhase:NSTouchPhaseAny inView:self].anyObject
              ?: [e touchesMatchingPhase:NSTouchPhaseAny inView:nil].anyObject;
    if (!t) return;
    // Direct touches report a real point in the view. normalizedPosition and
    // deviceSize belong to indirect (trackpad) touches and raise here.
    CGFloat tx = [t locationInView:self].x;
    // Grab only if the touch lands on him, with a generous margin: he is 39pt
    // wide on a bar you hit with a fingertip.
    if (fabs(tx - self.x) < 34) {
        self.dragging = YES;
        self.grabDX = tx - self.x;
        self.dragVX = 0;
        self.lastDragX = tx;
        self.act = ActClip;              // stop pacing while held
        self.clipIdx = 4;                // surprise
        self.clip = 0; self.clipT = 0; self.clipLoops = 2;
    }
}

- (void)touchesMovedWithEvent:(NSEvent *)e {
    if (!self.dragging) return;
    NSTouch *t = [e touchesMatchingPhase:NSTouchPhaseAny inView:self].anyObject
              ?: [e touchesMatchingPhase:NSTouchPhaseAny inView:nil].anyObject;
    if (!t) return;
    CGFloat tx = [t locationInView:self].x;
    CGFloat nx = tx - self.grabDX;
    self.dragVX = tx - self.lastDragX;   // for the throw
    self.lastDragX = tx;
    // Same wall the pacing uses: he may not be parked on top of the readout.
    CGFloat wall = READ_X - (CLAWD_N * 1.95) / 2.0 - 8;
    self.x = MAX(20, MIN(nx, wall));
    if (fabs(self.dragVX) > 0.5) self.dir = (self.dragVX > 0) ? 1 : -1;
    self.needsDisplay = YES;
}

- (void)touchesEndedWithEvent:(NSEvent *)e   { [self releaseDrag]; }
- (void)touchesCancelledWithEvent:(NSEvent *)e { [self releaseDrag]; }

- (void)releaseDrag {
    if (!self.dragging) return;
    self.dragging = NO;
    // Throw: carry the flick into a slide that decays, instead of stopping dead.
    self.throwVX = self.dragVX * 12.0;
    self.act = ActWalk;
    self.sinceAct = 0;
}

- (void)advance:(NSTimeInterval)dt {
    Mood m = MoodForUsage(self.p5);

    if (self.dragging) {
        // Held: legs scrabble, body shakes. A limp sprite following a finger
        // reads as a dragged icon; a struggling one reads as a creature.
        self.phase   += dt * 17.0;
        self.wiggleT += dt;
        self.needsDisplay = YES;
        return;
    }

    // A throw slides and decays back into the normal pacing speed.
    if (fabs(self.throwVX) > 1.0) {
        self.x += self.throwVX * dt;
        self.throwVX *= 0.92;
        CGFloat lo = 20, hi = READ_X - (CLAWD_N * 1.95) / 2.0 - 8;
        if (self.x < lo) { self.x = lo; self.throwVX = -self.throwVX * 0.5; self.dir = 1; }
        if (self.x > hi) { self.x = hi; self.throwVX = -self.throwVX * 0.5; self.dir = -1; }
        self.phase += dt * (fabs(self.throwVX) / 9.0);
        self.needsDisplay = YES;
        return;
    }

    if (self.act == ActWalk) {
        self.x += self.dir * SpeedForMood(m) * dt;

        // Turn around before the sprite's own edge — not its centre — reaches
        // the readout, or he walks over the "5h" label.
        CGFloat pad = 30, right = READ_X - (CLAWD_N * 1.95) / 2.0 - 8;
        if (self.x > right) { self.x = right; self.dir = -1; }
        if (self.x < pad)   { self.x = pad;   self.dir =  1; }

        // Step cadence tracks speed, so fast moods visibly scurry.
        self.phase += dt * (SpeedForMood(m) / 9.0);

        // Every so often, stop and do something. Panicking Clawd has no time
        // for hobbies, so the pause only happens when things are calm.
        // A fixed 12s gap put him on a metronome and left three quarters of
        // every cycle as plain pacing. The wait is now short and irregular, so
        // the next thing he does is neither far off nor predictable.
        self.sinceAct += dt;
        if (self.sinceAct > self.nextActAt) {
            self.sinceAct = 0;
            self.nextActAt = 3.0 + (CGFloat)arc4random_uniform(500) / 100.0;   // 3-8s
            self.clip = 0;
            self.clipT = 0;
            if (m != MoodPanic && arc4random_uniform(5) == 0) {   // เดาะบอลเฉพาะตอนไม่ตกใจ
                self.act = ActJuggle; self.ballY = 0; self.ballV = 46;
            } else {
                self.act = ActClip;
                self.clipIdx = ClipForMood(m, (int)self.lastClipIdx);
                self.lastClipIdx = self.clipIdx;
                const ClawdClip *pick = &kClawdClips[self.clipIdx];
                int ms = 0;
                for (int f = 0; f < pick->count; f++) ms += pick->frames[f].hold;
                self.clipLoops = MAX(1, MIN(3, 4000 / MAX(ms, 1)));
            }
        }
    } else if (self.act == ActJuggle) {
        // Simple ballistics: the ball falls, Clawd bumps it back up on contact.
        // ponytail: no collision system, just a floor test — it is one ball.
        self.clipT += dt;
        self.ballV -= 150.0 * dt;                 // gravity, points/s^2
        self.ballY += self.ballV * dt;
        if (self.ballY <= 0 && self.ballV < 0) {  // bounced off his head
            self.ballY = 0;
            self.ballV = 46;
            self.clip++;                          // count the bumps
        }
        self.phase += dt * 4.0;                   // little bob while juggling
        if (self.clipT > 6.0) { self.act = ActWalk; self.sinceAct = 0; }
    } else {
        // Each source frame carries its own hold in ms — honour it rather than
        // forcing a constant fps, or the timing of blinks and beats is wrong.
        const ClawdClip *cl = &kClawdClips[self.clipIdx];
        self.clipT += dt * 1000.0;
        while (self.clip < cl->count && self.clipT >= cl->frames[self.clip].hold) {
            self.clipT -= cl->frames[self.clip].hold;
            self.clip++;
        }
        if (self.clip >= cl->count) {
            // The dance clips run 1.4-2.4s and are built to loop, so playing
            // each exactly once sent him straight back to pacing — the busiest
            // moods ended up the least animated. Short clips repeat until they
            // have held the screen for a few seconds.
            if (--self.clipLoops > 0) {
                self.clip = 0;
            } else {
                self.act = ActWalk; self.clip = 0; self.sinceAct = 0;
            }
        }
    }

    self.needsDisplay = YES;
}

#pragma mark - Sprite


// Walk cycle: the official art has no walking pose, so build one from the base
// grid by moving the four legs. Row 14-16 hold the legs at columns 5, 8, 12, 15.
// ponytail: mutate a copy of the base rather than storing extra 400-byte frames.
static const unsigned char *WalkFrame(const unsigned char *base, int step) {
    static unsigned char buf[CLAWD_N * CLAWD_N];
    memcpy(buf, base, sizeof(buf));

    // Clear the existing legs, then redraw them at the offsets for this step.
    for (int r = 14; r <= 16; r++)
        for (int c = 0; c < CLAWD_N; c++)
            if (buf[r * CLAWD_N + c] == 1) buf[r * CLAWD_N + c] = 0;

    // Two pairs in counter-phase — front pair forward while back pair trails.
    static const int kLegX[4] = {5, 8, 12, 15};
    // Four genuinely distinct poses. Legs 0,2 lead while 1,3 trail (diagonal
    // gait) — a leg swings forward only while it is lifted, and plants when down.
    static const int kSwing[4][4] = {   // horizontal offset per step, per leg
        { -1, +1, -1, +1},
        {  0,  0,  0,  0},
        { +1, -1, +1, -1},
        {  0,  0,  0,  0},
    };
    static const int kLift[4][4]  = {   // 1 = lifted (drawn one row shorter)
        { 0, 1, 0, 1},
        { 0, 0, 0, 0},
        { 1, 0, 1, 0},
        { 0, 0, 0, 0},
    };

    int ph = step & 3;
    for (int i = 0; i < 4; i++) {
        int c = kLegX[i] + kSwing[ph][i];
        if (c < 0 || c >= CLAWD_N) continue;
        int bottom = kLift[ph][i] ? 15 : 16;         // lifted legs stop short
        for (int r = 14; r <= bottom; r++) buf[r * CLAWD_N + c] = 1;
    }
    return buf;
}

// Draw one 20x20 official frame. Rows run top-down; the view is not flipped.
// The base pose only occupies rows 4..16 — the rest of the 20x20 canvas is
// padding. Skipping it lets each pixel be ~60% larger in the same 30pt bar.
#define CLAWD_TOP 3
#define CLAWD_BOT 17
#define CLAWD_ROWS (CLAWD_BOT - CLAWD_TOP + 1)

static void DrawGridLean(const unsigned char *g, NSPoint origin, CGFloat px,
                         BOOL flip, NSColor *body, CGFloat lean,
                         const unsigned char (*pal)[3], int palCount,
                         int top, int bot);

// A clip either carries its own palette (scenes with props — laptop, desk,
// headphones) or is the plain 0/1/2 creature, in which case the caller's body
// colour applies so mood tinting still reaches it.
static void DrawGridPal(const unsigned char *g, NSPoint origin, CGFloat px,
                        BOOL flip, NSColor *body,
                        const unsigned char (*pal)[3], int palCount,
                        int top, int bot) {
    DrawGridLean(g, origin, px, flip, body, 0, pal, palCount, top, bot);
}

// lean shears the sprite: rows further from the feet shift further, so he
// tilts against the direction he is being pulled instead of sliding rigid.
static void DrawGridLean(const unsigned char *g, NSPoint origin, CGFloat px,
                         BOOL flip, NSColor *body, CGFloat lean,
                         const unsigned char (*pal)[3], int palCount,
                         int top, int bot) {
    NSColor *eye = [NSColor colorWithSRGBRed:0.06 green:0.06 blue:0.06 alpha:1.0];
    NSColor *cache[16] = {0};
    for (int r = top; r <= bot; r++) {
        for (int c = 0; c < CLAWD_N; c++) {
            unsigned char v = g[r * CLAWD_N + c];
            if (!v) continue;
            NSColor *ink;
            if (pal && v < palCount) {
                if (!cache[v])
                    cache[v] = [NSColor colorWithSRGBRed:pal[v][0] / 255.0
                                                   green:pal[v][1] / 255.0
                                                    blue:pal[v][2] / 255.0 alpha:1.0];
                ink = cache[v];
            } else {
                ink = (v == 2) ? eye : body;
            }
            [ink set];
            int cx = flip ? (CLAWD_N - 1 - c) : c;
            CGFloat rowUp = (bot - r);                // 0 at the feet
            NSRectFill(NSMakeRect(origin.x + (cx - CLAWD_N / 2.0) * px + lean * rowUp,
                                  origin.y + rowUp * px,
                                  px + 0.4, px + 0.4));
        }
    }
}

static void DrawGrid(const unsigned char *g, NSPoint origin, CGFloat px,
                     BOOL flip, NSColor *body) {
    DrawGridPal(g, origin, px, flip, body, NULL, 0, CLAWD_TOP, CLAWD_BOT);
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.clearColor set];
    NSRectFill(dirty);

    CGFloat midY = NSHeight(self.bounds) / 2.0;

    if (!self.haveData) {
        NSDictionary *at = @{ NSFontAttributeName: [NSFont systemFontOfSize:12],
                              NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
        [@"claude …" drawAtPoint:NSMakePoint(20, midY - 8) withAttributes:at];
        return;
    }

    Mood mood = MoodForUsage(self.p5);

    // Anthropic coral, desaturating toward alarm red as the window fills.
    NSColor *body = (mood == MoodPanic)
        ? [NSColor colorWithSRGBRed:0.86 green:0.30 blue:0.22 alpha:1.0]
        : [NSColor colorWithSRGBRed:0.804 green:0.498 blue:0.416 alpha:1.0];  // #CD7F6A — official, from creature-engine.js

    // 15 rows at 1.95 filled 29.2 of the 30pt bar, leaving 0.8pt of margin —
    // less than the bob, so his head clipped, and the sweat drawn above it was
    // off-screen entirely. 1.72 keeps him large while leaving room to move.
    CGFloat const px = 1.72;
    CGFloat bob = (mood == MoodTired) ? 0 : (((int)(self.phase * 2.0) & 1) ? 0.7 : 0);
    // Sit him slightly low: the space above his head is where the sweat goes.
    NSPoint feet = NSMakePoint(self.x, 2.2 + bob);   // 2.2 clears the ground line at feet.y-1.5

    // Ground line, like the reference art.
    [[NSColor colorWithWhite:1.0 alpha:0.14] set];
    NSRectFill(NSMakeRect(0, feet.y - 1.5, NSWidth(self.bounds), 1.0));

    // Panic: motion streaks trailing behind.
    if (mood == MoodPanic) {
        [[body colorWithAlphaComponent:0.28] set];
        for (int i = 1; i <= 3; i++) {
            CGFloat sx = self.x - self.dir * (CLAWD_N * px * 0.4 + i * 5.0);
            NSRectFill(NSMakeRect(MIN(sx, sx - self.dir * 4.0), feet.y + 8, 4.0, 1.6));
        }
    }

    const unsigned char *base = kClawdClips[0].frames[0].grid;   // canonical pose

    if (self.dragging) {
        // Startled, not malfunctioning: a fast wobble with a slow sway under
        // it, so the motion has a shape instead of reading as vibration.
        CGFloat t = self.wiggleT;
        CGFloat jx = sin(t * 16.0) * 1.3 + sin(t * 6.0) * 0.6;
        CGFloat jy = sin(t * 13.0) * 1.5 + cos(t * 21.0) * 0.5;
        CGFloat lean = MAX(-0.35, MIN(0.35, -self.dragVX * 0.04));
        NSPoint p = NSMakePoint(feet.x + jx, feet.y + jy);
        DrawGridLean(WalkFrame(base, (int)(self.phase * 2.0)), p, px,
                     (self.dir < 0), body, lean, NULL, 0, CLAWD_TOP, CLAWD_BOT);

        // Sweat: three drops on staggered cycles, each arcing up and out from
        // the head and fading. Position comes from the clock, so no particle
        // state has to be kept anywhere.
        CGFloat headY = p.y + CLAWD_ROWS * px;
        for (int i = 0; i < 3; i++) {
            CGFloat prog = fmod(t * 1.6 + i * 0.37, 1.0);       // 0..1 per drop
            if (prog > 0.85) continue;                          // brief gap
            CGFloat side = (i == 1) ? -1.0 : 1.0;
            CGFloat dx = side * (5.0 + prog * 13.0) + ((i == 2) ? 3.0 : 0);
            CGFloat dy = sin(prog * M_PI) * 7.0 - prog * 2.0;   // arc up, then fall
            CGFloat fade = MIN(1.0, (1.0 - prog) * 1.6);   // stay opaque until well clear
            [[NSColor colorWithSRGBRed:0.42 green:0.72 blue:0.96
                                  alpha:0.95 * fade] set];
            CGFloat sz = 2.6 * (1.0 - prog * 0.3);
            NSRectFill(NSMakeRect(p.x + dx, headY + dy - 2, sz, sz * 1.35));
        }
    } else if (self.act == ActWalk) {
        DrawGrid(WalkFrame(base, (int)(self.phase * 2.0)), feet, px, (self.dir < 0), body);
    } else if (self.act == ActJuggle) {
        DrawGrid(base, feet, px, (self.dir < 0), body);
        // The ball, sitting above his head.
        CGFloat top = feet.y + CLAWD_ROWS * px;
        NSRect b = NSMakeRect(self.x - px, top + 1 + self.ballY, px * 2, px * 2);
        [NSColor.whiteColor set];
        NSRectFill(b);
    } else {
        const ClawdClip *cl = &kClawdClips[self.clipIdx];
        NSInteger i = MIN(MAX(self.clip, 0), (NSInteger)cl->count - 1);
        // Prop scenes must not be mirrored: a laptop drawn backwards reads as
        // a glitch, unlike the creature itself which is symmetric enough.
        // Clips carry their own row window. The prop scenes are taller than the
        // creature alone, so shrink the pixel just enough to fit rather than
        // cropping desks and thought bubbles off the top — which is what the
        // fixed 3..17 window had been doing to every clip, old ones included.
        int ctop = cl->top, cbot = cl->bot;
        CGFloat cpx = MIN(px, (kSceneH - 1.0) / (cbot - ctop + 1));
        NSPoint cfeet = NSMakePoint(self.x, midY - ((cbot - ctop + 1) * cpx) / 2.0);
        DrawGridPal(cl->frames[i].grid, cfeet, cpx,
                    cl->pal ? NO : (self.dir < 0), body, cl->pal, cl->palCount,
                    ctop, cbot);
    }

    // Tired: a sweat drop above the head.
    if (mood == MoodTired) {
        [[NSColor colorWithSRGBRed:0.42 green:0.70 blue:0.94 alpha:0.95] set];
        NSRectFill(NSMakeRect(self.x + 8, feet.y + CLAWD_ROWS * px * 0.9, 2.4, 3.4));
    }

    [self drawReadout];
}

static void DrawRight(NSString *s, CGFloat rightEdge, CGFloat y, NSDictionary *at) {
    CGFloat w = [s sizeWithAttributes:at].width;
    [s drawAtPoint:NSMakePoint(rightEdge - w, y) withAttributes:at];
}

- (void)drawReadout {
    CGFloat h = NSHeight(self.bounds);

    int p5 = MAX(0, MIN(100, self.p5)), p7 = MAX(0, MIN(100, self.p7));
    BOOL dead = [self.state isEqualToString:@"expired"];
    BOOL old  = [self.state isEqualToString:@"stale"];

    // An expired token means every number on screen is a fossil. Dimming them
    // is not enough — replace the readout outright, and say what fixes it.
    if (dead) {
        NSDictionary *t = @{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.45 blue:0.35 alpha:1.0] };
        NSDictionary *s = @{ NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular],
                             NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.55] };
        [@"token expired" drawAtPoint:NSMakePoint(READ_X, h - 16) withAttributes:t];
        [@"claude -p hi" drawAtPoint:NSMakePoint(READ_X, 3) withAttributes:s];
        return;
    }

    // Staleness is already stated in words by the amber badge, so the dimming
    // only needs to be a hint. At 0.55 it dragged the labels to 2.9:1 — below
    // the 4.5:1 floor, i.e. the state that says "do not trust this" was the
    // one you could not read.
    CGFloat dim = old ? 0.72 : 1.0;

    // One cell per limit. The per-model cap only exists once it is being
    // consumed, so the block is two or three cells wide and shares the width
    // evenly — no cell is ever the runt with a number but no bar.
    NSMutableArray *cells = [@[@[@"5h", @(p5)], @[@"7d", @(p7)]] mutableCopy];
    if (self.scopedPct > 0 && self.scopedName.length) {
        [cells addObject:@[self.scopedName, @(self.scopedPct)]];
    }

    NSInteger n = cells.count;
    CGFloat cellW = (READ_W - CELL_GAP * (n - 1)) / n;
    for (NSInteger i = 0; i < n; i++) {
        [self drawCell:cells[i][0] pct:[cells[i][1] intValue]
                     x:READ_X + i * (cellW + CELL_GAP) width:cellW dim:dim];
    }

    // The countdown belongs to the 5h window, so it sits beside that label
    // rather than in a row of its own. Staleness takes the same slot when it
    // applies — an old reading matters more than when the next one resets.
    NSString *note = nil;
    NSColor *noteColor = [NSColor colorWithWhite:1.0 alpha:0.55];
    if (old) {
        note = [NSString stringWithFormat:@"%dm old", self.ageSec / 60];
        noteColor = [NSColor colorWithSRGBRed:1.0 green:0.78 blue:0.31 alpha:0.95];
    } else if (self.resetMin >= 0) {
        note = [NSString stringWithFormat:@"%dh%02d", self.resetMin / 60, self.resetMin % 60];
    }
    if (note) {
        NSDictionary *at = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8
                                                                                    weight:NSFontWeightMedium],
                              NSForegroundColorAttributeName: noteColor };
        [note drawAtPoint:NSMakePoint(READ_X + 17, TEXT_Y + 1) withAttributes:at];
    }
}

// A cell is label + percentage on one line, bar underneath, all cells identical.
// Colour does NOT track the value: the bar's length already says how full it is,
// and a green-to-red ramp restates that with invisible thresholds (why is 68%
// green and 71% amber?). Colour is spent only on the one state that needs an
// action — at or above 90% — so it reads as an alarm rather than decoration.
- (void)drawCell:(NSString *)label pct:(int)pct x:(CGFloat)x width:(CGFloat)w dim:(CGFloat)dim {
    // #B1B9F9 is the exact colour Claude Code fills its own /usage bars with —
    // read off the escape codes it emits, not guessed. Amber and red take over
    // as the window fills. Coral is deliberately absent: it is Clawd's, and at
    // 1.08:1 against a warning red it could not carry a warning anyway.
    //
    // Thresholds are visible on the bar itself (ticks at 50 and 90), so a
    // change of colour lands where the user can see why, and ">= 90" also
    // prints "!" so the alarm never depends on colour vision alone.
    // Picked on the Touch Bar itself via `--palette`, not from renders. Claude
    // Code's own #B1B9F9 was the starting point and lost: hue 233 reads as
    // lavender and L84 washes out on a 30pt strip you glance at. A panel this
    // dim wants more saturation and less lightness than a terminal does.
    BOOL alarm = (pct >= 90);
    NSColor *ink;
    if (alarm)          ink = [NSColor colorWithSRGBRed:0.902 green:0.208 blue:0.180 alpha:1.0];  // #E6352E
    else if (pct >= 50) ink = [NSColor colorWithSRGBRed:0.949 green:0.706 blue:0.161 alpha:1.0];  // #F2B429
    else                ink = [NSColor colorWithSRGBRed:0.173 green:0.533 blue:0.945 alpha:1.0];  // #2C88F1

    NSDictionary *lb = @{ NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.70 * dim] };
    [label drawAtPoint:NSMakePoint(x, TEXT_Y) withAttributes:lb];

    // Every percentage is the same size and weight — one glance, one scale.
    NSString *num = alarm ? [NSString stringWithFormat:@"%d%% !", pct]
                          : [NSString stringWithFormat:@"%d%%", pct];
    NSDictionary *nu = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12
                                                                                weight:NSFontWeightBold],
                          NSForegroundColorAttributeName: [ink colorWithAlphaComponent:dim] };
    DrawRight(num, x + w, TEXT_Y - 1, nu);

    // The track is the 100% reference, not decoration — keep it readable.
    [[NSColor colorWithWhite:1.0 alpha:0.36 * dim] set];
    NSRectFill(NSMakeRect(x, BAR_Y, w, BAR_H));

    CGFloat fillW = w * pct / 100.0;
    [[ink colorWithAlphaComponent:dim] set];
    NSRectFill(NSMakeRect(x, BAR_Y, fillW, BAR_H));

    // Ticks at 50 and 90 turn the bar into a scale, drawn only over the unfilled
    // remainder — notches punched through a nearly-full bar read as breakage.
    [[NSColor colorWithWhite:1.0 alpha:0.3 * dim] set];
    for (NSNumber *frac in @[@0.5, @0.9]) {
        CGFloat tx = w * frac.doubleValue;
        if (tx > fillW) NSRectFill(NSMakeRect(x + tx, BAR_Y, 1, BAR_H));
    }
}

@end

#pragma mark - App

#pragma mark - Palette picker

// `--palette` puts candidate colours on the actual Touch Bar side by side.
// Renders to PNG are useful for layout, but a colour has to be judged on the
// panel it will live on — this one is dim, warm, and viewed at a glance.
@interface PaletteView : NSView
@end

// `--ruler`: how much width does the system actually give us? Ask for far more
// than we think we have and read the answer off the bar.
@interface RulerView : NSView
@end

// `--sweat`: four sweat treatments animating side by side on the real panel.
// Sweat is motion, so a still render cannot settle it — and neither can I,
// since the bar cannot be screenshotted.
@interface SweatView : NSView
@property (nonatomic) NSTimeInterval t;
@end
@implementation PaletteView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    [NSColor.clearColor set];
    NSRectFill(dirty);

    // Two rows: amber candidates above, red below. Both are judged against the
    // blue that was already chosen, so that one is drawn at the far left as a
    // fixed reference rather than left to memory.
    NSColor *chosenBlue = [NSColor colorWithSRGBRed:0.173 green:0.533 blue:0.945 alpha:1.0];  // E

    NSArray *ambers = @[
        @[@"1", [NSColor colorWithSRGBRed:0.961 green:0.831 blue:0.400 alpha:1.0]],  // F5D466
        @[@"2", [NSColor colorWithSRGBRed:0.957 green:0.773 blue:0.267 alpha:1.0]],  // F4C544
        @[@"3", [NSColor colorWithSRGBRed:0.949 green:0.706 blue:0.161 alpha:1.0]],  // F2B429
        @[@"4", [NSColor colorWithSRGBRed:0.937 green:0.639 blue:0.129 alpha:1.0]],  // EFA321
    ];
    NSArray *reds = @[
        @[@"1", [NSColor colorWithSRGBRed:0.937 green:0.427 blue:0.376 alpha:1.0]],  // EF6D60
        @[@"2", [NSColor colorWithSRGBRed:0.925 green:0.318 blue:0.263 alpha:1.0]],  // EC5143
        @[@"3", [NSColor colorWithSRGBRed:0.902 green:0.208 blue:0.180 alpha:1.0]],  // E6352E
        @[@"4", [NSColor colorWithSRGBRed:0.996 green:0.271 blue:0.227 alpha:1.0]],  // FE453A
    ];

    NSDictionary *lb = @{ NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.75] };

    // Reference: the chosen blue, full height, so both rows sit next to it.
    [@"blue" drawAtPoint:NSMakePoint(4, 9) withAttributes:lb];
    [[NSColor colorWithWhite:1.0 alpha:0.36] set];
    NSRectFill(NSMakeRect(34, 2, 44, 26));
    [chosenBlue set];
    NSRectFill(NSMakeRect(34, 2, 44 * 0.48, 26));

    CGFloat x0 = 92, avail = NSWidth(self.bounds) - x0 - 6;
    CGFloat w = avail / ambers.count;

    for (NSInteger i = 0; i < ambers.count; i++) {
        CGFloat x = x0 + i * w, cw = w - 10;
        // amber row (top)
        [[NSString stringWithFormat:@"A%@", ambers[i][0]] drawAtPoint:NSMakePoint(x, 16) withAttributes:lb];
        [[NSColor colorWithWhite:1.0 alpha:0.36] set];
        NSRectFill(NSMakeRect(x + 22, 17, cw - 22, 9));
        [(NSColor *)ambers[i][1] set];
        NSRectFill(NSMakeRect(x + 22, 17, (cw - 22) * 0.68, 9));

        // red row (bottom)
        [[NSString stringWithFormat:@"R%@", reds[i][0]] drawAtPoint:NSMakePoint(x, 2) withAttributes:lb];
        [[NSColor colorWithWhite:1.0 alpha:0.36] set];
        NSRectFill(NSMakeRect(x + 22, 3, cw - 22, 9));
        [(NSColor *)reds[i][1] set];
        NSRectFill(NSMakeRect(x + 22, 3, (cw - 22) * 0.94, 9));
    }
}
@end

@implementation SweatView
- (BOOL)isFlipped { return NO; }
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        [NSTimer scheduledTimerWithTimeInterval:1.0/15.0 repeats:YES block:^(NSTimer *tm) {
            self.t += 1.0/15.0; self.needsDisplay = YES;
        }];
    }
    return self;
}
// A pixel teardrop: narrow at the top, widest just below centre, rounded off.
// Two flat rectangles read as a blob; the silhouette is what makes it water.
static void DrawDrop(CGFloat x, CGFloat y, CGFloat scale, NSColor *c, CGFloat alpha) {
    [[c colorWithAlphaComponent:alpha] set];
    CGFloat u = scale;
    NSRectFill(NSMakeRect(x + u * 0.9, y + u * 3.4, u * 1.0, u * 1.1));   // tip
    NSRectFill(NSMakeRect(x + u * 0.5, y + u * 2.3, u * 1.8, u * 1.2));
    NSRectFill(NSMakeRect(x,           y + u * 0.9, u * 2.8, u * 1.5));   // belly
    NSRectFill(NSMakeRect(x + u * 0.4, y,           u * 2.0, u * 1.0));   // base
    [[NSColor colorWithWhite:1.0 alpha:alpha * 0.55] set];
    NSRectFill(NSMakeRect(x + u * 0.55, y + u * 1.7, u * 0.7, u * 0.9));  // highlight
}

- (void)drawRect:(NSRect)d {
    [NSColor.clearColor set]; NSRectFill(d);
    NSColor *body = [NSColor colorWithSRGBRed:0.804 green:0.498 blue:0.416 alpha:1.0];
    NSColor *drop = [NSColor colorWithSRGBRed:0.45 green:0.76 blue:0.98 alpha:1.0];
    NSDictionary *lb = @{ NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.8] };
    const unsigned char *base = kClawdClips[0].frames[0].grid;
    CGFloat px = 1.95, t = self.t;
    CGFloat w = NSWidth(self.bounds) / 4.0;

    for (int v = 0; v < 4; v++) {
        CGFloat cx = v * w + w * 0.45;
        [[NSString stringWithFormat:@"%c", 'A' + v] drawAtPoint:NSMakePoint(v * w + 6, 16) withAttributes:lb];

        CGFloat jx = sin(t * 16.0) * 1.3 + sin(t * 6.0) * 0.6;
        CGFloat jy = sin(t * 13.0) * 1.5 + cos(t * 21.0) * 0.5;
        NSPoint p = NSMakePoint(cx + jx, 2 + jy);
        DrawGridLean(WalkFrame(base, (int)(t * 34.0)), p, px, NO, body, 0.15, NULL, 0,
                     CLAWD_TOP, CLAWD_BOT);
        CGFloat hy = p.y + CLAWD_ROWS * px;

        if (v == 0) {          // A: หยดเดียว ค้างข้างหัว ทรงหยดน้ำ สั่นตามตัว
            DrawDrop(p.x + 10, hy - 5, 1.5, drop, 0.95);
        } else if (v == 1) {   // B: หยดค้าง + ไหลลงช้าๆ แล้ววนใหม่
            CGFloat pr = fmod(t * 0.55, 1.0);
            DrawDrop(p.x + 10, hy - 3 - pr * 11, 1.5, drop, pr > 0.75 ? (1 - pr) * 4 : 0.95);
        } else if (v == 2) {   // C: หยดใหญ่ค้าง + หยดเล็กกระเด็นอีกฝั่ง
            DrawDrop(p.x + 10, hy - 4, 1.8, drop, 0.95);
            for (int i = 0; i < 2; i++) {
                CGFloat pr = fmod(t * 1.7 + i * 0.5, 1.0);
                if (pr > 0.7) continue;
                DrawDrop(p.x - 12 - pr * 7, hy - 1 + pr * 4, 0.9, drop, 0.9 * (1 - pr / 0.7));
            }
        } else {               // D: 2 หยดคนละข้าง สั่นคนละจังหวะ
            DrawDrop(p.x + 10, hy - 4 + sin(t * 11.0) * 0.8, 1.5, drop, 0.95);
            DrawDrop(p.x - 13, hy - 6 + sin(t * 9.0 + 1.7) * 0.8, 1.2, drop, 0.9);
        }
    }
}
@end

@implementation RulerView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)d {
    [NSColor.clearColor set]; NSRectFill(d);
    NSDictionary *a = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10
                                                                              weight:NSFontWeightBold],
                         NSForegroundColorAttributeName: NSColor.whiteColor };
    // Ticks at fixed coordinates only. An earlier version drew a marker at
    // NSWidth(bounds)-6, which sits at the view's own edge no matter how wide
    // the view is — it always looked like the full width had been granted.
    for (int x = 0; x <= 900; x += 25) {
        BOOL hundred = (x % 100 == 0), fifty = (x % 50 == 0);
        [[NSColor colorWithWhite:1.0 alpha:hundred ? 1.0 : (fifty ? 0.6 : 0.3)] set];
        NSRectFill(NSMakeRect(x, 0, hundred ? 2 : 1, hundred ? 12 : (fifty ? 7 : 4)));
        if (hundred && x > 0)
            [[NSString stringWithFormat:@"%d", x] drawAtPoint:NSMakePoint(x + 3, 14) withAttributes:a];
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
@property (nonatomic) BOOL paletteMode;
@property (nonatomic) BOOL rulerMode;
@property (nonatomic) BOOL sweatMode;
@property (nonatomic, strong) NSTouchBar *bar;
@property (nonatomic, strong) PetView *pet;
@property (nonatomic, strong) NSTimer *frameTimer;
@property (nonatomic, strong) dispatch_queue_t shell;
@property (nonatomic, strong) id activity;
@property (nonatomic) NSTimeInterval lastFrame;
@property (nonatomic) NSTimeInterval lastPoll;
@property (nonatomic) BOOL polling, asleep;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.shell = dispatch_queue_create("local.claude-touchbar.shell", DISPATCH_QUEUE_SERIAL);

    if (![NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)]) {
        NSLog(@"claude-touchbar: system-modal Touch Bar SPI missing — exiting.");
        [NSApp terminate:nil];
        return;
    }

    DFRSystemModalShowsCloseBoxWhenFrontMost(NO);

    if (self.paletteMode || self.rulerMode || self.sweatMode) {
        self.bar = [NSTouchBar new];
        self.bar.delegate = self;
        self.bar.defaultItemIdentifiers = @[kSceneID];
        self.bar.escapeKeyReplacementItemIdentifier = kEscID;
        [self present];
        NSLog(@"palette mode — press Ctrl-C to exit");
        return;
    }

    self.pet = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];

    self.bar = [NSTouchBar new];
    self.bar.delegate = self;
    self.bar.defaultItemIdentifiers = @[kSceneID];
    // Keep Esc working — a presented bar otherwise covers the system one.
    self.bar.escapeKeyReplacementItemIdentifier = kEscID;

    [self present];

    // App Nap will freeze the animation the moment you switch away, which is
    // precisely when the pet is worth watching.
    self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated
                                                                 reason:@"animate the Touch Bar pet"];

    self.lastFrame = NSDate.timeIntervalSinceReferenceDate;
    self.frameTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / kFPS repeats:YES
                                                        block:^(NSTimer *t) { [self frame]; }];
    // .common mode: default-mode timers stall inside menu/tracking loops.
    [NSRunLoop.mainRunLoop addTimer:self.frameTimer forMode:NSRunLoopCommonModes];

    // A presented bar yields when another app presents its own, so re-assert on
    // every app switch. Cheap and idempotent.
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self selector:@selector(present)
               name:NSWorkspaceDidActivateApplicationNotification object:nil];

    // Don't animate into a locked screen.
    [NSDistributedNotificationCenter.defaultCenter
        addObserver:self selector:@selector(sleep) name:@"com.apple.screenIsLocked" object:nil];
    [NSDistributedNotificationCenter.defaultCenter
        addObserver:self selector:@selector(wake) name:@"com.apple.screenIsUnlocked" object:nil];

    [self poll];
}

- (void)present {
    [NSTouchBar presentSystemModalTouchBar:self.bar placement:0 systemTrayItemIdentifier:nil];
}

- (void)sleep { self.asleep = YES; }
- (void)wake  { self.asleep = NO; [self present]; }

- (nullable NSTouchBarItem *)touchBar:(NSTouchBar *)bar
                makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    if ([identifier isEqualToString:kSceneID]) {
        NSCustomTouchBarItem *it = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        if (self.sweatMode)
            it.view = [[SweatView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
        else if (self.rulerMode)
            it.view = [[RulerView alloc] initWithFrame:NSMakeRect(0, 0, 900, kSceneH)];
        else if (self.paletteMode)
            it.view = [[PaletteView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
        else
            it.view = self.pet;
        return it;
    }
    if ([identifier isEqualToString:kEscID]) {
        NSCustomTouchBarItem *it = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        it.view = [NSButton buttonWithTitle:@"esc" target:self action:@selector(sendEscape:)];
        return it;
    }
    return nil;
}

- (void)sendEscape:(id)sender {
    // Posting to the system requires no special right for a plain key event.
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)53, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)53, false);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    if (down) CFRelease(down);
    if (up)   CFRelease(up);
}

- (void)frame {
    if (self.asleep) return;

    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    NSTimeInterval dt = MIN(now - self.lastFrame, 0.25);   // clamp after a stall
    self.lastFrame = now;

    [self.pet advance:dt];

    if (now - self.lastPoll >= 30.0) { self.lastPoll = now; [self poll]; }
}

- (void)poll {
    if (self.polling) return;
    self.polling = YES;

    dispatch_async(self.shell, ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
        task.arguments = @[@"-lc", kScript];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;

        NSString *out = nil;
        NSError *err = nil;
        if ([task launchAndReturnError:&err]) {
            NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }

        NSArray<NSString *> *parts = [[out ?: @""
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            componentsSeparatedByString:@" "];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (parts.count >= 5) {
                self.pet.p5 = parts[0].intValue;
                self.pet.p7 = parts[1].intValue;
                self.pet.resetMin = parts[2].intValue;
                self.pet.ageSec = parts[3].intValue;
                self.pet.state = parts[4];
                // The API also reports a per-model weekly cap (kind=weekly_scoped).
                // Only surface it once it is actually being consumed — at 0% it is
                // noise on a 30pt strip.
                self.pet.scopedPct  = (parts.count >= 6) ? parts[5].intValue : -1;
                self.pet.scopedName = (parts.count >= 7) ? parts[6] : @"";
                self.pet.haveData = ![parts[4] isEqualToString:@"none"];
            }
            self.polling = NO;
        });
    });
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [NSTouchBar dismissSystemModalTouchBar:self.bar];
    if (self.activity) [NSProcessInfo.processInfo endActivity:self.activity];
}

@end

// --render <dir>: draw the readout to PNGs at a spread of states and exit.
// The Touch Bar cannot be screenshotted, so this is the only way to actually
// look at what drawRect: produces instead of guessing from the code.
static int RenderStates(NSString *dir) {
    NSDictionary *states = @{
        @"01-low":      @[@12, @4,  @185, @"ok",      @0,  @""],
        @"02-mid":      @[@48, @31, @92,  @"ok",      @0,  @""],
        @"03-scoped":   @[@48, @31, @92,  @"ok",      @37, @"Fable"],
        @"04-high":     @[@91, @68, @14,  @"ok",      @0,  @""],
        @"05-both-high":@[@94, @96, @3,   @"ok",      @88, @"Fable"],
        @"06-stale":    @[@48, @31, @92,  @"stale",   @0,  @""],
        @"07-expired":  @[@48, @31, @-1,  @"expired", @0,  @""],
        @"08-zero":     @[@0,  @0,  @300, @"ok",      @0,  @""],
    };
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    for (NSString *name in [states.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray *s = states[name];
        PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
        v.p5 = [s[0] intValue]; v.p7 = [s[1] intValue]; v.resetMin = [s[2] intValue];
        v.state = s[3]; v.scopedPct = [s[4] intValue]; v.scopedName = s[5];
        v.ageSec = 300; v.haveData = YES; v.x = 60;

        // Two passes, and the order matters. drawRect: opens by filling itself
        // with clearColor in copy mode, so anything painted underneath first is
        // wiped — the widget must be drawn onto a transparent surface and only
        // then composited over the dark backdrop, exactly as the Touch Bar
        // does it. Flattening the two into one pass makes every translucent
        // fill read as solid white.
        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus];
        [v drawRect:v.bounds];
        [layer unlockFocus];

        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        // Black, exactly like the Touch Bar: a lighter backdrop lifts every
        // translucent fill and makes measured contrast look better than it is.
        [[NSColor blackColor] set];
        NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];

        NSBitmapImageRep *out = [[NSBitmapImageRep alloc]
            initWithData:[img TIFFRepresentation]];
        NSData *png = [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *path = [dir stringByAppendingPathComponent:
                          [name stringByAppendingString:@".png"]];
        [png writeToFile:path atomically:YES];
        printf("%s\n", path.UTF8String);
    }
    return 0;
}

// `--shot <out.png> <p5> <p7> <resetMin> <ageSec> [scopedPct scopedName]`:
// one frame at exactly the numbers you ask for. `--render` covers the eight
// states worth reviewing, but a press shot has to match a state that actually
// happened — a photograph of the bar and a render beside it disagreeing on the
// percentages is the kind of detail that makes both look fabricated.
static int RenderShot(NSString *out, int p5, int p7, int resetMin, int ageSec,
                      int scopedPct, NSString *scopedName) {
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
    v.p5 = p5; v.p7 = p7; v.resetMin = resetMin; v.ageSec = ageSec;
    v.scopedPct = scopedPct; v.scopedName = scopedName;
    v.state = @"ok"; v.haveData = YES; v.x = 60;

    // Two passes, for the reason spelled out in RenderStates: drawRect: opens
    // by clearing itself in copy mode, so the backdrop has to go on afterwards.
    NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
    [layer lockFocus];
    [v drawRect:v.bounds];
    [layer unlockFocus];

    NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
    [img lockFocus];
    [NSColor.blackColor set];
    NSRectFill(v.bounds);
    [layer drawInRect:v.bounds fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1.0];
    [img unlockFocus];

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithData:[img TIFFRepresentation]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:out atomically:YES];
    printf("%s (%.0fx%.0f)\n", out.UTF8String,
           (double)rep.pixelsWide, (double)rep.pixelsHigh);
    return 0;
}

// `--poses <dir>`: one PNG per clip, mid-animation, so a new pose can be
// checked for clipping and palette errors without waiting for it to appear.
// `--film <dir> <seconds>`: run the real animation loop headless and write one
// PNG per frame, so the widget can be turned into a GIF without filming a
// screen. Uses the same advance:/drawRect: path as the live app.
static int RenderFilm(NSString *dir, double secs) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
    v.p5 = 62; v.p7 = 61; v.resetMin = 93; v.scopedPct = 61; v.scopedName = @"Fable";
    v.state = @"ok"; v.haveData = YES; v.x = 60;

    int n = (int)(secs * kFPS);
    for (int i = 0; i < n; i++) {
        [v advance:1.0 / kFPS];
        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus]; [v drawRect:v.bounds]; [layer unlockFocus];
        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        [NSColor.blackColor set]; NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];
        NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation];
        [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"f%04d.png", i]] atomically:YES];
    }
    printf("%d frames at %.0f fps -> %s\n", n, kFPS, dir.UTF8String);
    return 0;
}

// `--film-drag <dir>`: scripted sequence — pacing, then grabbed and dragged,
// then thrown. Drives the same state the touch handlers set, so what it records
// is the real reaction rather than a re-creation of it.
static int RenderFilmDrag(NSString *dir) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
    v.p5 = 62; v.p7 = 61; v.resetMin = 93; v.scopedPct = 61; v.scopedName = @"Fable";
    v.state = @"ok"; v.haveData = YES; v.x = 90; v.dir = 1;

    double dt = 1.0 / kFPS;
    __block int i = 0;
    void (^shoot)(void) = ^{
        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus]; [v drawRect:v.bounds]; [layer unlockFocus];
        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        [NSColor.blackColor set]; NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];
        NSBitmapImageRep *o = [[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation];
        [[o representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"f%04d.png", i++]] atomically:YES];
    };

    for (int f = 0; f < 30; f++) { [v advance:dt]; shoot(); }      // pacing, 2s

    v.dragging = YES; v.grabDX = 0; v.act = ActClip; v.clipIdx = 4;
    v.clip = 0; v.clipT = 0; v.clipLoops = 3;
    // Same wall the real handler applies — an earlier version of this recorder
    // moved x directly and produced footage of him standing on the readout,
    // which the app itself does not allow.
    CGFloat wall = READ_X - (CLAWD_N * 1.95) / 2.0 - 8;
    CGFloat path[] = {150, 200, 245, 262, 240, 200, 150, 100, 60, 30, 70, 130, 190, 250};
    for (int p = 0; p < (int)(sizeof(path)/sizeof(CGFloat)); p++) {
        for (int f = 0; f < 4; f++) {                              // ~4s held
            v.dragVX = (path[p] - v.x) / 4.0;
            v.x = MAX(20, MIN(v.x + v.dragVX, wall));
            v.lastDragX = v.x;
            if (fabs(v.dragVX) > 0.5) v.dir = (v.dragVX > 0) ? 1 : -1;
            [v advance:dt]; shoot();
        }
    }
    [v releaseDrag];                                                // thrown
    for (int f = 0; f < 60; f++) { [v advance:dt]; shoot(); }       // slide + settle, 4s

    printf("%d frames -> %s\n", i, dir.UTF8String);
    return 0;
}

static int RenderPoses(NSString *dir) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    for (int i = 0; i < kClawdClipCount; i++) {
        const ClawdClip *cl = &kClawdClips[i];
        PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, 120, kSceneH)];
        v.p5 = 20; v.p7 = 10; v.state = @"ok"; v.haveData = YES;
        v.x = 60; v.act = ActClip; v.clipIdx = i; v.clip = cl->count / 2;

        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus]; [v drawRect:v.bounds]; [layer unlockFocus];
        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        [NSColor.blackColor set]; NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];
        NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation];
        [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%02d-%s.png", i, cl->name]] atomically:YES];
        printf("%2d %-20s %2d frames %s\n", i, cl->name, cl->count, cl->pal ? "(own palette)" : "");
    }
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--film-drag") == 0) {
            [NSApplication sharedApplication];
            return RenderFilmDrag(@(argv[2]));
        }
        if (argc == 4 && strcmp(argv[1], "--film") == 0) {
            [NSApplication sharedApplication];
            return RenderFilm(@(argv[2]), atof(argv[3]));
        }
        if (argc == 3 && strcmp(argv[1], "--poses") == 0) {
            [NSApplication sharedApplication];
            return RenderPoses(@(argv[2]));
        }
        if (argc == 3 && strcmp(argv[1], "--render") == 0) {
            [NSApplication sharedApplication];   // AppKit drawing needs this
            return RenderStates(@(argv[2]));
        }
        if ((argc == 7 || argc == 9) && strcmp(argv[1], "--shot") == 0) {
            [NSApplication sharedApplication];
            return RenderShot(@(argv[2]), atoi(argv[3]), atoi(argv[4]),
                              atoi(argv[5]), atoi(argv[6]),
                              argc == 9 ? atoi(argv[7]) : 0,
                              argc == 9 ? @(argv[8]) : @"");
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *d = [AppDelegate new];
        d.paletteMode = (argc == 2 && strcmp(argv[1], "--palette") == 0);
        d.rulerMode  = (argc == 2 && strcmp(argv[1], "--ruler") == 0);
        d.sweatMode  = (argc == 2 && strcmp(argv[1], "--sweat") == 0);
        app.delegate = d;
        [app run];
    }
    return 0;
}
