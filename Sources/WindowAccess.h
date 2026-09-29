#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import "Layout.h"

@interface FSWindow : NSObject
@property(nonatomic,strong) id element;
@property(nonatomic) pid_t pid;
@property(nonatomic,copy) NSString *bundleID;
@property(nonatomic,copy) NSString *appName;
@property(nonatomic,copy) NSString *title;
- (AXUIElementRef)ax;
- (BOOL)readFrame:(FSRect *)frame;
- (BOOL)isUsable;
- (BOOL)isRestorable;
- (BOOL)restoreForLayout;
- (BOOL)raiseWindow;
- (BOOL)focusWindow;
- (BOOL)isOnScreen:(NSArray<NSDictionary *> *)rows;
- (BOOL)moveTo:(FSRect)frame error:(NSString **)error;
- (BOOL)sameWindow:(FSWindow *)other;
- (NSString *)label;
@end

NSArray<NSDictionary *> *FSOnScreenRows(void);
NSArray<FSWindow *> *FSAvailableWindows(void);
/* Explicit layout switches only; includes hidden/minimized ordinary windows. */
NSArray<FSWindow *> *FSRestorableWindows(NSSet<NSString *> *bundleIDs);
FSWindow *FSFocusedWindow(pid_t pid);
FSWindow *FSWindowAtPoint(CGPoint point);
/* Match the front WindowServer row under the pointer with its AX window.
   Returns the visible frame for drag-origin geometry and a diagnostic reason. */
FSWindow *FSWindowAtPointWithChrome(CGPoint point, FSRect *visibleFrame,
                                    BOOL *plainChrome, NSString **reason);
NSScreen *FSScreenForFrame(FSRect frame);
NSString *FSDisplayID(NSScreen *screen);
NSScreen *FSScreenWithID(NSString *identifier);
FSRect FSUsableFrame(NSScreen *screen);
