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

static CGFloat const kSceneW = 560.0;   // fits the app region alongside the Control Strip
static CGFloat const kSceneH = 30.0;
static double  const kFPS    = 15.0;    // both reference pet apps land at 14-18

// Readout: every limit gets an identical cell — label, percentage, bar — laid
// out side by side so they can be compared at a glance. Earlier versions gave
// 5h and 7d a row each and demoted the per-model cap to a bare number with no
// bar, which made the one number you could not compare the odd one out.
#define READ_X    296.0    // left edge of the readout block
#define READ_W    258.0    // to x=554, clear of the 560pt right edge
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
static int ClipForMood(Mood m) {
    switch (m) {
        case MoodCalm:  { int c[] = {0,1,2};   return c[arc4random_uniform(3)]; }
        case MoodBrisk: { int c[] = {6,7,3};   return c[arc4random_uniform(3)]; }
        case MoodTired: { int c[] = {8,5};     return c[arc4random_uniform(2)]; }
        case MoodPanic: return 4;   // surprise
    }
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
@end

@implementation PetView

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _x = 40; _dir = 1; _p5 = 0; _p7 = 0; _resetMin = -1;
        _act = ActWalk;
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

- (void)advance:(NSTimeInterval)dt {
    Mood m = MoodForUsage(self.p5);

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
        self.sinceAct += dt;
        if (self.sinceAct > 12.0 && m != MoodPanic) {
            self.sinceAct = 0;
            self.clip = 0;
            self.clipT = 0;
            if (arc4random_uniform(4) == 0) {          // 1 ใน 4 = เดาะบอล
                self.act = ActJuggle; self.ballY = 0; self.ballV = 46;
            } else {
                self.act = ActClip;
                self.clipIdx = ClipForMood(m);
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
        if (self.clip >= cl->count) { self.act = ActWalk; self.clip = 0; self.sinceAct = 0; }
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

static void DrawGrid(const unsigned char *g, NSPoint origin, CGFloat px,
                     BOOL flip, NSColor *body) {
    NSColor *eye = [NSColor colorWithSRGBRed:0.06 green:0.06 blue:0.06 alpha:1.0];
    for (int r = CLAWD_TOP; r <= CLAWD_BOT; r++) {
        for (int c = 0; c < CLAWD_N; c++) {
            unsigned char v = g[r * CLAWD_N + c];
            if (!v) continue;
            [(v == 2 ? eye : body) set];
            int cx = flip ? (CLAWD_N - 1 - c) : c;
            NSRectFill(NSMakeRect(origin.x + (cx - CLAWD_N / 2.0) * px,
                                  origin.y + (CLAWD_BOT - r) * px,
                                  px + 0.4, px + 0.4));
        }
    }
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

    CGFloat const px = 1.95;                      // 15 drawn rows * 1.95 = 29pt of the 30pt bar
    CGFloat bob = (mood == MoodTired) ? 0 : (((int)(self.phase * 2.0) & 1) ? 0.9 : 0);
    NSPoint feet = NSMakePoint(self.x, midY - (CLAWD_ROWS * px) / 2.0 + bob);

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
    if (self.act == ActWalk) {
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
        DrawGrid(cl->frames[i].grid, feet, px, (self.dir < 0), body);
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
    // All three sit in the same family as the blue: high lightness, moderate
    // saturation. The first attempt used a vivid amber and red at L60-62 next
    // to an L84 lavender, which is why they read as borrowed from a different
    // palette — the mismatch was lightness, not hue.
    BOOL alarm = (pct >= 90);
    NSColor *ink;
    if (alarm)          ink = [NSColor colorWithSRGBRed:0.906 green:0.424 blue:0.373 alpha:1.0];  // #E76C5F
    else if (pct >= 50) ink = [NSColor colorWithSRGBRed:0.929 green:0.851 blue:0.584 alpha:1.0];  // #EDD995
    else                ink = [NSColor colorWithSRGBRed:0.694 green:0.725 blue:0.976 alpha:1.0];  // #B1B9F9

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

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
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

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--render") == 0) {
            [NSApplication sharedApplication];   // AppKit drawing needs this
            return RenderStates(@(argv[2]));
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
