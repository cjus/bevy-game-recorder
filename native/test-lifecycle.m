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
        puts("Native lifecycle tests passed (no capture or permission requests).");
    }
    return 0;
}
