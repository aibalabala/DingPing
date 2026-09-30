#import <Cocoa/Cocoa.h>
#import "WindowAccess.h"
#import "WorkspaceStore.h"
#include "WorkspacePolicy.h"

/* The native adapter is replaceable in integration tests, so event sequences
   run through the same coordinator without moving the CI machine's windows. */
@interface FSWindowEnvironment : NSObject
- (NSArray<FSWindow *> *)availableWindows;
- (NSArray *)visibleRows;
- (BOOL)trusted;
- (int)zonesForProfile:(NSDictionary *)profile into:(FSRect *)zones;
- (BOOL)window:(FSWindow *)window onTargetOfProfile:(NSDictionary *)profile rows:(NSArray *)rows;
@end

@interface FSWindowCoordinator : NSObject
@property(nonatomic,strong,readonly) FSWorkspaceStore *store;
@property(nonatomic,strong) FSWindowEnvironment *environment;
@property(nonatomic,readonly) BOOL enabled;
@property(nonatomic,readonly) BOOL busy;
@property(nonatomic,readonly) BOOL dragging;
@property(nonatomic,readonly) NSUInteger generation;
@property(nonatomic) NSInteger activeSlot;
@property(nonatomic,copy) void (^onChange)(void);
@property(nonatomic,copy) void (^onMessage)(NSString *message);
@property(nonatomic,copy) void (^onIdle)(void);
- (instancetype)initWithStore:(FSWorkspaceStore *)store;
- (void)setFreeMode;
- (void)pause;
- (void)tick;
- (BOOL)activateProfile:(NSString *)identifier preferredWindow:(FSWindow *)window foreground:(BOOL)foreground;
- (void)observeFocusedWindow:(FSWindow *)window;
- (uint64_t)beginDrag;
- (BOOL)releaseDrag:(uint64_t)token;
- (void)finishDrag:(uint64_t)token window:(FSWindow *)window destination:(NSInteger)destination;
- (void)assignWindow:(FSWindow *)window toSlot:(NSInteger)slot;
- (NSInteger)slotForWindow:(FSWindow *)window;
- (NSArray<FSWindow *> *)windowsInSlot:(NSInteger)slot;
- (NSArray<FSWindow *> *)availableWindows;
- (FSWindow *)topWindowInSlot:(NSInteger)slot;
- (void)focusSlot:(NSInteger)slot;
- (void)togglePinInSlot:(NSInteger)slot;
- (BOOL)topWindowPinned:(NSInteger)slot;
- (NSMutableDictionary *)saveFavorite:(NSString *)name;
- (void)save;
- (NSString *)diagnostic;
- (void)restoreOriginalPositions;
@end
