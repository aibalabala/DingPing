#import <Cocoa/Cocoa.h>
#import "WindowAccess.h"

@interface FSDragTarget : NSObject
@property(nonatomic,strong) FSWindow *window;
@property(nonatomic) FSRect frame;
@end

@interface FSDragGuard : NSObject
@property(nonatomic,copy) NSArray<FSDragTarget *> *targets;
@property(nonatomic,copy) BOOL (^mayIntercept)(void);
@property(nonatomic,copy) void (^onFailure)(NSString *message);
@property(nonatomic,readonly) BOOL running;
@property(nonatomic,readonly) BOOL faulted;
- (BOOL)start:(NSString **)error;
- (void)stop;
@end
