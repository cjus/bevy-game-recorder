// Pure lifecycle regression tests: no permission APIs or capture are invoked.
#import "recorder.m"
#include <assert.h>
@interface FakeStream : NSObject
@property int stops;
@end
@implementation FakeStream
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))handler {
    self.stops++;
    handler(nil);
}
@end
// Like winit's delegate: no applicationShouldTerminate: of its own.
@interface PlainDelegate : NSObject <NSApplicationDelegate>
@end
@implementation PlainDelegate
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    fputs("terminate: went through while a session was unfinished\n", stderr);
    _exit(1);
}
@end
static void drain(void) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
int main(void) {
    @autoreleasepool {
        session = [BGRSession new]; session.state = 1;
        bgr_abort();
        assert(bgr_state() == 5);
        SCRecordingOutput *token = (SCRecordingOutput *)(id)[NSObject new]; // Delegate argument is unused.
        [session recordingOutputDidStartRecording:token];
        [session recordingOutputDidFinishRecording:token];
        drain();
        assert(bgr_state() == 5); // Late callbacks cannot revive cancellation.

        session = [BGRSession new]; session.state = 1;
        bgr_stop();
        assert(bgr_state() == 5); // Cancel discovery before a stream exists.

        session = [BGRSession new]; session.state = 1;
        FakeStream *fake = [FakeStream new];
        session.stream = (SCStream *)(id)fake;
        bgr_abort();
        assert(fake.stops == 1); // Abort stops a starting stream immediately.
        bgr_abort();
        assert(fake.stops == 1); // Idempotent terminal handling.

        session = [BGRSession new]; session.state = 1;
        [session recordingOutputDidStartRecording:token];
        drain();
        assert(bgr_state() == 2); // Verify callbacks actually drain in this harness.
        FakeStream *active = [FakeStream new];
        session.stream = (SCStream *)(id)active;
        bgr_stop();
        assert(bgr_state() == 3 && active.stops == 1);
        [session recordingOutputDidFinishRecording:token];
        drain();
        assert(bgr_state() == 4);
        [session fail:@"late error"];
        assert(bgr_state() == 4);

        // ⌘Q, the Dock's Quit and logout (terminate:) wait for an unfinished session.
        [NSApplication sharedApplication];
        PlainDelegate *delegate = [PlainDelegate new];
        NSApp.delegate = delegate;
        session = [BGRSession new]; session.state = 2;
        bgr_guard_termination();
        assert(NSApp.delegate == delegate); // Untouched: AppKit finds the added method itself.
        [NSApp terminate:nil]; // Refused: it returns, and the request is noted.
        assert(bgr_take_quit_request() == 1);
        assert(bgr_take_quit_request() == 0); // Taken once.
        session.state = 3;
        [NSApp terminate:nil];
        assert(bgr_take_quit_request() == 1); // Still refused while finalizing.
        session.state = 4;
        assert([NSApp.delegate applicationShouldTerminate:NSApp] == NSTerminateNow);
        session.state = 5;
        assert([NSApp.delegate applicationShouldTerminate:NSApp] == NSTerminateNow);
        assert(bgr_take_quit_request() == 0);
        // The video takes the window's shape, as large as fits, with even sides.
        int w, h;
        bgr_fit(1920, 1080, 1600, 900, &w, &h);
        assert(w == 1920 && h == 1080); // 16:9 fills it.
        bgr_fit(1920, 1080, 1440, 932, &w, &h);
        assert(w == 1668 && h == 1080); // Solrac's window: no band.
        bgr_fit(1920, 1080, 2400, 900, &w, &h);
        assert(w == 1920 && h == 720); // Wider: full width.
        bgr_fit(1920, 1080, 801, 1201, &w, &h);
        assert(w == 720 && h == 1080); // Taller, odd: full height, an even width.
        bgr_fit(1920, 1080, 1441, 932, &w, &h);
        assert(w == 1670 && h == 1080); // 1669.8 rounds to 1670, already even.
        bgr_fit(1920, 1080, 1000, 648, &w, &h);
        assert(w == 1666 && h == 1080); // 1666.7 rounds to 1667, made even: 1666.
        bgr_fit(1920, 1080, 0, 900, &w, &h);
        assert(w == 1920 && h == 1080); // Unmeasurable: the configured size.
        bgr_fit(1920, 1080, 1, 100000, &w, &h);
        assert(w == 1920 && h == 1080); // Too thin to encode: the configured size.

        puts("Native lifecycle tests passed (no capture or permission requests).");
    }
    return 0;
}
