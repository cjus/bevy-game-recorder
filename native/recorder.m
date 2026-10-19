#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <unistd.h>

// All state and public entry points live on the macOS main thread. Framework
// callbacks hop to it; no frame data crosses the FFI and no pipe can block Bevy.
@interface BGRSession : NSObject <SCStreamDelegate, SCRecordingOutputDelegate>
@property SCStream *stream;
@property SCRecordingOutput *output;
@property NSString *error;
@property int state;
@property BOOL stopRequested;
- (void)fail:(NSString *)message;
- (void)stop;
@end
@implementation BGRSession
- (void)fail:(NSString *)message {
    self.error = message;
    self.state = 5;
    if (self.stream) [self.stream stopCaptureWithCompletionHandler:^(NSError *e) { (void)e; }];
}
- (void)stop {
    self.stopRequested = YES;
    if (self.state != 2) return; // Starting callback honors pending stop.
    self.state = 3;
    [self.stream stopCaptureWithCompletionHandler:^(NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (e && self.state != 5) [self fail:e.localizedDescription]; });
    }];
}
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output {
    (void)output;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.state == 5) return;
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

int bgr_is_main_thread(void) { return [NSThread isMainThread] ? 1 : 0; }
int bgr_preflight(void) { return CGPreflightScreenCaptureAccess() ? 1 : 0; }
int bgr_start(const char *path, const char *title, int width, int height, int fps, int audio) {
    NSCAssert([NSThread isMainThread], @"recorder must run on main thread");
    if (session) return -1;
    session = [BGRSession new];
    session.state = 1;
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
                dispatch_async(dispatch_get_main_queue(), ^{ if (e) [session fail:e.localizedDescription]; });
            }];
        });
    }];
    return 0;
}
int bgr_state(void) { return session ? session.state : 0; }
const char *bgr_error(void) { return session.error ? session.error.UTF8String : ""; }
void bgr_stop(void) { [session stop]; }
