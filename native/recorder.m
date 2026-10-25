#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <unistd.h>

// All state and public entry points live on the macOS main thread. Framework
// callbacks hop to it; no frame data crosses the FFI and no pipe can block Bevy.
@interface BGRSession : NSObject <SCStreamDelegate, SCRecordingOutputDelegate>
@property SCStream *stream;
@property SCStreamConfiguration *config;
@property SCRecordingOutput *output;
@property(weak) NSWindow *window;
@property id resizeObserver;
@property BOOL updating;
@property BOOL updatePending;
@property NSString *error;
@property int state;
@property BOOL stopRequested;
@property BOOL quitRequested;
- (void)fail:(NSString *)message;
- (void)stop;
- (void)track;
@end

// The title bar's separator, a hairline macOS draws over the top of the content, in points.
static const CGFloat BGR_SEPARATOR = 1.0;

// The window's content below its title bar, as a single-window stream's sourceRect measures it:
// in points from the window's top left. contentLayoutRect is in the window's own coordinates,
// from its bottom left, and leaves out the title bar (in full screen, there is none), but not
// its separator. A window with no content to measure gives CGRectNull: the whole window.
static CGRect bgr_content(CGSize frame, CGRect layout) {
    if (!(layout.size.width > 0 && layout.size.height > BGR_SEPARATOR)) return CGRectNull;
    CGFloat top = frame.height - CGRectGetMaxY(layout);
    CGFloat separator = top > 0 ? BGR_SEPARATOR : 0;
    return CGRectMake(layout.origin.x, top + separator, layout.size.width, layout.size.height - separator);
}
@implementation BGRSession
- (void)fail:(NSString *)message {
    if (self.state >= 4) return; // Terminal outcomes are immutable.
    self.error = message;
    self.state = 5;
    [self stopTracking];
    if (self.stream) [self.stream stopCaptureWithCompletionHandler:^(NSError *e) { (void)e; }];
}
- (void)stop {
    self.stopRequested = YES;
    if (self.state == 1 && !self.stream) {
        [self fail:@"Recording cancelled before capture started; no video was finalized."];
        return;
    }
    if (self.state != 2) return; // Starting callback honors pending stop.
    self.state = 3;
    [self.stream stopCaptureWithCompletionHandler:^(NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (e && self.state != 5) [self fail:e.localizedDescription]; });
    }];
}
// Follows the window's content when it is resized or goes full screen: the video keeps its
// size, and the new content is scaled to fit it, keeping its shape. One update is in flight at a
// time; a resize meanwhile is applied when it finishes, so a live resize keeps up without a
// queue. A failed update leaves the earlier crop, and the recording carries on.
- (void)track {
    if (self.state != 2 || !self.window) return;
    CGRect content = bgr_content(self.window.frame.size, self.window.contentLayoutRect);
    if (CGRectIsNull(content) || CGRectEqualToRect(content, self.config.sourceRect)) return;
    if (self.updating) { self.updatePending = YES; return; }
    self.updating = YES;
    self.config.sourceRect = content;
    [self.stream updateConfiguration:self.config completionHandler:^(NSError *e) {
        (void)e;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.updating = NO;
            if (!self.updatePending) return;
            self.updatePending = NO;
            [self track];
        });
    }];
}
- (void)stopTracking {
    if (self.resizeObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.resizeObserver];
    self.resizeObserver = nil;
}
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output {
    (void)output;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.state != 1) return;
        self.state = 2;
        if (self.stopRequested) [self stop];
        else [self track]; // A resize while it started.
    });
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output {
    (void)output;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.state == 5) return;
        self.state = 4;
        [self stopTracking];
    });
}
- (void)recordingOutput:(SCRecordingOutput *)output didFailWithError:(NSError *)error {
    (void)output;
    dispatch_async(dispatch_get_main_queue(), ^{ [self fail:error.localizedDescription]; });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    dispatch_async(dispatch_get_main_queue(), ^{ [self fail:error.localizedDescription]; });
}
@end
static BGRSession *session;

// -[NSApplication terminate:] (⌘Q, the Dock's Quit, logout) asks the delegate's
// applicationShouldTerminate: first. winit's delegate has none, so AppKit goes straight to
// applicationWillTerminate:, Bevy clears its world and the process exits before the MP4 is
// finalized. While a session is unfinished, the guard refuses and notes the request, which Rust
// turns into a graceful stop and quit; once it is finished or failed, quitting goes ahead.
static IMP previousShouldTerminate;
static NSApplicationTerminateReply bgr_should_terminate(id self, SEL cmd, NSApplication *sender) {
    if (session && session.state >= 1 && session.state <= 3) {
        session.quitRequested = YES;
        return NSTerminateCancel;
    }
    if (previousShouldTerminate)
        return ((NSApplicationTerminateReply (*)(id, SEL, NSApplication *))previousShouldTerminate)(self, cmd, sender);
    return NSTerminateNow;
}
// Added to the delegate's class at run time (or wrapping the class's own method), once.
// terminate: looks the method up when it is called, so the delegate needn't be set again (the
// native harness checks this against AppKit's real terminate:).
static void bgr_guard_termination(void) {
    static BOOL installed;
    id<NSApplicationDelegate> delegate = NSApp.delegate;
    if (installed || !delegate) return;
    Class cls = object_getClass(delegate);
    SEL selector = @selector(applicationShouldTerminate:);
    const char *types = protocol_getMethodDescription(@protocol(NSApplicationDelegate), selector, NO, YES).types;
    Method inherited = class_getInstanceMethod(cls, selector);
    IMP before = inherited ? method_getImplementation(inherited) : NULL;
    if (!class_addMethod(cls, selector, (IMP)bgr_should_terminate, types ? types : "Q@:@"))
        before = method_setImplementation(class_getInstanceMethod(cls, selector), (IMP)bgr_should_terminate);
    previousShouldTerminate = before;
    installed = YES;
}

// The video takes the shape of the window's content when recording starts, as large as fits in
// the configured size, with even sides for H.264; a later resize is scaled to fit it, keeping its
// shape. Content too small to measure gets the configured size.
static void bgr_fit(int width, int height, double windowWidth, double windowHeight, int *outWidth, int *outHeight) {
    *outWidth = width;
    *outHeight = height;
    if (!(windowWidth > 0 && windowHeight > 0)) return;
    // The side that limits takes the whole size (even already); only the other is rounded.
    int fitWidth = width, fitHeight = height;
    if (windowWidth * height > windowHeight * width)
        fitHeight = (int)lround(windowHeight * width / windowWidth) & ~1;
    else
        fitWidth = (int)lround(windowWidth * height / windowHeight) & ~1;
    if (fitWidth < 2 || fitHeight < 2) return;
    *outWidth = fitWidth;
    *outHeight = fitHeight;
}

int bgr_is_main_thread(void) { return [NSThread isMainThread] ? 1 : 0; }
int bgr_preflight(void) { return CGPreflightScreenCaptureAccess() ? 1 : 0; }
int bgr_start(const char *path, const char *title, int width, int height, int fps, int audio) {
    NSCAssert([NSThread isMainThread], @"recorder must run on main thread");
    if (session) return -1;
    session = [BGRSession new];
    session.state = 1;
    bgr_guard_termination();
    if (!CGPreflightScreenCaptureAccess()) {
        [session fail:@"Screen recording permission is missing. Enable this game/launching terminal in System Settings > Privacy & Security > Screen & System Audio Recording, then restart. No permission was requested automatically."];
        return 0;
    }
    NSString *wanted = [NSString stringWithUTF8String:title];
    NSInteger windowID = 0;
    int matches = 0;
    for (NSWindow *window in NSApp.windows) {
        if ([window.title isEqualToString:wanted] && window.isVisible) { windowID = window.windowNumber; session.window = window; matches++; }
    }
    if (matches != 1) { [session fail:@"Expected exactly one visible game window with the configured title."]; return 0; }
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (session.state != 1) return; // Discovery may finish after cancellation.
            if (error) { [session fail:error.localizedDescription]; return; }
            SCWindow *target = nil;
            for (SCWindow *window in content.windows) {
                if (window.windowID == windowID && window.owningApplication.processID == getpid()) { target = window; break; }
            }
            if (!target) { [session fail:@"Game window is unavailable for capture."]; return; }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            // The content only: the title bar, with its state and macOS's capture indicator, stays
            // in the window for the player and out of the video (#6).
            CGRect content = session.window ? bgr_content(session.window.frame.size, session.window.contentLayoutRect) : CGRectNull;
            CGSize source = CGRectIsNull(content) ? target.frame.size : content.size;
            if (!CGRectIsNull(content)) config.sourceRect = content;
            int videoWidth, videoHeight;
            bgr_fit(width, height, source.width, source.height, &videoWidth, &videoHeight);
            config.width = videoWidth; config.height = videoHeight;
            config.minimumFrameInterval = CMTimeMake(1, fps);
            config.queueDepth = 3;
            config.scalesToFit = YES; config.preservesAspectRatio = YES;
            config.showsCursor = NO;
            config.ignoreShadowsSingleWindow = YES;
            config.capturesAudio = audio != 0;
            config.excludesCurrentProcessAudio = NO;
            config.captureMicrophone = NO;
            config.sampleRate = 48000; config.channelCount = 2;
            config.captureDynamicRange = SCCaptureDynamicRangeSDR;
            session.config = config;
            session.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:session];
            __weak BGRSession *tracked = session;
            session.resizeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification object:session.window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;
                [tracked track];
            }];
            SCRecordingOutputConfiguration *recording = [SCRecordingOutputConfiguration new];
            recording.outputURL = url; recording.videoCodecType = AVVideoCodecTypeH264; recording.outputFileType = AVFileTypeMPEG4;
            session.output = [[SCRecordingOutput alloc] initWithConfiguration:recording delegate:session];
            NSError *attachError = nil;
            if (![session.stream addRecordingOutput:session.output error:&attachError]) { [session fail:attachError.localizedDescription]; return; }
            [session.stream startCaptureWithCompletionHandler:^(NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (e) [session fail:e.localizedDescription];
                    // A timed-out/dropped owner must never leave a late start running.
                    else if (session.state == 5) [session.stream stopCaptureWithCompletionHandler:^(NSError *ignored) { (void)ignored; }];
                });
            }];
        });
    }];
    return 0;
}
int bgr_state(void) { return session ? session.state : 0; }
const char *bgr_error(void) { return session.error ? session.error.UTF8String : ""; }
void bgr_stop(void) { [session stop]; }
int bgr_take_quit_request(void) {
    if (!session.quitRequested) return 0;
    session.quitRequested = NO;
    return 1;
}

void bgr_abort(void) { [session fail:@"Recording owner cancelled or timed out; output may be incomplete."]; }
