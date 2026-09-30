#import <Cocoa/Cocoa.h>
#import "../Sources/WindowCoordinator.h"
#include <stdio.h>
static void check(BOOL value,NSString *message) {if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static void pump(double seconds) {[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];}
@interface FakeWindow : FSWindow
@property(nonatomic,copy) NSString *identity;
@property(nonatomic) FSRect frame;
@property(nonatomic) BOOL alive;
@property(nonatomic) BOOL minimized;
@property(nonatomic) NSUInteger moveCount;
@property(nonatomic) NSUInteger raiseCount;
@end
@implementation FakeWindow
- (BOOL)sameWindow:(FSWindow *)w {return [w isKindOfClass:FakeWindow.class] && [self.identity isEqual:((FakeWindow *)w).identity];}
- (BOOL)isAlive {return self.alive;}
- (BOOL)isDefinitelyClosed {return !self.alive;}
- (BOOL)isRestorable {return self.alive;}
- (BOOL)isUsable {return self.alive && !self.minimized;}
- (BOOL)isMinimized {return self.minimized;}
- (BOOL)isHidden {return NO;}
- (BOOL)readFrame:(FSRect *)frame {if(!self.alive)return NO;*frame=self.frame;return YES;}
- (BOOL)moveTo:(FSRect)frame error:(NSString **)error {self.frame=frame;self.moveCount++;return self.alive;}
- (BOOL)restoreForLayout {self.minimized=NO;return self.alive;}
- (BOOL)raiseWindow {self.raiseCount++;return self.isUsable;}
- (BOOL)focusWindow {return [self raiseWindow];}
- (BOOL)isOnScreen:(NSArray *)rows {return self.isUsable;}
@end
@interface FakeEnvironment : FSWindowEnvironment
@property(nonatomic,strong) NSArray<FakeWindow *> *windows;
@end
@implementation FakeEnvironment
- (NSArray *)availableWindows {return self.windows;}
- (NSArray *)visibleRows {return @[];}
- (BOOL)trusted {return YES;}
- (int)zonesForProfile:(NSDictionary *)profile into:(FSRect *)zones {
    return FSBuildZones([profile[@"layout"] intValue],(FSRect){74,38,2486,1394},[profile[@"ratio"] doubleValue],8,zones);
}
- (BOOL)window:(FSWindow *)window onTargetOfProfile:(NSDictionary *)profile rows:(NSArray *)rows {return [window isUsable];}
@end
static FakeWindow *window(NSString *identity,NSString *bundle) {
    FakeWindow *w=[FakeWindow new];w.identity=identity;w.bundleID=bundle;w.appName=bundle;w.title=identity;w.alive=YES;
    w.frame=(FSRect){100,100,900,600};return w;
}
int main(void) {@autoreleasepool {
    FSWorkspaceStore *store=[[FSWorkspaceStore alloc] initWithConfig:nil defaultDisplay:@"test"];
    FSWindowCoordinator *engine=[[FSWindowCoordinator alloc] initWithStore:store];FakeEnvironment *env=[FakeEnvironment new];engine.environment=env;
    FakeWindow *a=window(@"Chrome A",@"chrome"),*b=window(@"Chrome B",@"chrome"),*c=window(@"Code",@"code"),*d=window(@"Finder",@"finder"),*e=window(@"Terminal",@"terminal");
    env.windows=@[a,b,c,d,e];NSMutableDictionary *p=store.activeProfile;p[@"layout"]=@2;p[@"ratio"]=@.5;
    check([engine activateProfile:p[@"id"] preferredWindow:a foreground:NO],@"activate base layout");pump(.25);
    check([p[@"windows"] count]==5,@"all five windows assigned into three zones");
    NSInteger aSlot=[engine slotForWindow:a],bSlot=[engine slotForWindow:b],cSlot=[engine slotForWindow:c];
    for(int i=0;i<30;i++){[engine observeFocusedWindow:a];[engine observeFocusedWindow:b];}
    check([engine slotForWindow:a]==aSlot && [engine slotForWindow:b]==bSlot,@"repeated clicks do not exchange Chrome windows");
    uint64_t drag=[engine beginDrag];check(drag && engine.dragging,@"drag acquires highest-priority gate");
    [engine observeFocusedWindow:c];NSMutableDictionary *other=[store builtin:1 name:@"三栏" display:@"test" layout:1 ratio:.5];
    check(![engine activateProfile:other[@"id"] preferredWindow:nil foreground:NO],@"layout request cannot cancel drag");
    check([engine releaseDrag:drag],@"mouse-up retains drag priority");[engine tick];[engine observeFocusedWindow:a];
    [engine finishDrag:drag window:b destination:0];
    check([engine slotForWindow:b]==0 && [engine slotForWindow:a]==aSlot && [engine slotForWindow:c]==cSlot,@"horizontal drag changes only source window, not destination occupant");
    check([[engine windowsInSlot:0] count]==3,@"destination keeps its existing two windows below dragged window");
    [engine observeFocusedWindow:b];pump(.8);[engine tick];
    check([engine slotForWindow:b]==0,@"immediate focus and maintenance retain drag result");
    [engine assignWindow:c toSlot:0];[engine assignWindow:b toSlot:0];
    check([engine topWindowInSlot:0]==b,@"dragged window becomes top");
    NSUInteger revealed=c.raiseCount;b.minimized=YES;pump(.8);[engine tick];
    check([engine topWindowInSlot:0]==c && c.raiseCount>revealed && [engine slotForWindow:b]==0,@"minimizing top reveals lower window without forgetting slot");
    b.minimized=NO;[engine observeFocusedWindow:b];check([engine topWindowInSlot:0]==b && [engine slotForWindow:b]==0,@"restored window stays in its zone");
    b.title=@"Changed tab";[engine observeFocusedWindow:b];pump(.8);[engine tick];check([engine slotForWindow:b]==0,@"title change cannot move live window");
    NSMutableDictionary *favorite=[engine saveFavorite:@"编程"];check(favorite!=nil,@"save favorite clones session membership");
    [engine assignWindow:b toSlot:2];
    check([engine activateProfile:p[@"id"] preferredWindow:nil foreground:NO],@"switch back to builtin");pump(.25);
    check([engine slotForWindow:b]==0,@"builtin position remains independent from favorite");
    check([engine activateProfile:favorite[@"id"] preferredWindow:nil foreground:NO],@"return to favorite");pump(.25);
    check([engine slotForWindow:b]==2,@"favorite restores its own saved position");
    /* A drag during the layout's delayed foreground stage invalidates that
       stage and its pending move checks; only the direct drop survives. */
    check([engine activateProfile:p[@"id"] preferredWindow:nil foreground:NO],@"begin layout stage");
    drag=[engine beginDrag];check(drag!=0,@"user drag preempts in-progress layout effects");
    [engine releaseDrag:drag];[engine finishDrag:drag window:b destination:1];pump(.55);
    check([engine slotForWindow:b]==1 && !engine.busy,@"stale layout completion cannot overwrite later drag");
    NSUInteger exposed=e.raiseCount;b.alive=NO;pump(.8);[engine tick];
    check([engine topWindowInSlot:1]==e && e.raiseCount>exposed && [p[@"windows"] count]==5,
          @"closing top reveals lower window and keeps its saved record");
    FakeWindow *reopened=window(@"new Chrome identity",@"chrome");reopened.title=@"Changed tab";
    env.windows=@[a,reopened,c,d,e];pump(.8);[engine tick];
    check([engine slotForWindow:reopened]==1 && [p[@"windows"] count]==5,@"reopened unique window reuses memory without replacing other windows");
    NSUInteger moves=b.moveCount;[engine setFreeMode];pump(.8);[engine tick];check(b.moveCount==moves,@"free mode stops movement");
    NSData *data=[NSJSONSerialization dataWithJSONObject:store.config options:0 error:NULL];
    FSWorkspaceStore *reload=[[FSWorkspaceStore alloc] initWithConfig:[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] defaultDisplay:@"test"];
    check(!reload.saveBlocked && [reload.config[@"mode"] isEqual:@"free"],@"startup keeps saved mode");
    puts("PASS: real coordinator with fake OS adapter: five-window stacks, two Chrome focus, horizontal drag, drag/layout priority, minimize/reveal, title edits, favorites, stale callbacks, free mode.");
}return 0;}
