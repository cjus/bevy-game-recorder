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
@property SCRecordingOutput *output;
@property NSString *error;
@property int state;
@property BOOL stopRequested;
@property BOOL quitRequested;
- (void)fail:(NSString *)message;
- (void)stop;
@end
@implementation BGRSession
- (void)fail:(NSString *)message {
    if (self.state >= 4) return; // Terminal outcomes are immutable.
    self.error = message;
    self.state = 5;
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
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output {
    (void)output;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.state != 1) return;
        self.state = 2;
        if (self.stopRequested) [self stop];
    });
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output {
    (void)output;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.state != 5) self.state = 4; });
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
static void bgr_guard_termination(void) {
    static BOOL installed;
    id<NSApplicationDelegate> delegate = NSApp.delegate;
    if (installed || !delegate) return;
    Class cls = object_getClass(delegate);
    SEL selector = @selector(applicationShouldTerminate:);
    const char *types = protocol_getMethodDescription(@protocol(NSApplicationDelegate), selector, NO, YES).types;
    Method inherited = class_getInstanceMethod(cls, selector);
    IMP before = inherited ? method_getImplementation(inherited) : NULL;
    if (!class_addMethod(cls, selector, (IMP)bgr_should_terminate, types))
        before = method_setImplementation(class_getInstanceMethod(cls, selector), (IMP)bgr_should_terminate);
    previousShouldTerminate = before;
    // AppKit may note which optional methods a delegate answers when it is set: set it again.
    NSApp.delegate = nil;
    NSApp.delegate = delegate;
    installed = YES;
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
        if ([window.title isEqualToString:wanted] && window.isVisible) { windowID = window.windowNumber; matches++; }
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
            config.width = width; config.height = height;
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
            session.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:session];
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
