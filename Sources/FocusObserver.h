#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

/* Observe only the frontmost application. A slow polling fallback lives in FSApp. */
@interface FSFocusObserver : NSObject
@property(nonatomic,copy) void (^onChange)(void);
@property(nonatomic,copy) void (^onCreated)(id windowElement, pid_t pid);
- (void)watchPID:(pid_t)pid;
- (void)stop;
@end
