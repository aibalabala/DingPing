#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import "WindowAccess.h"
#import "DragGuard.h"
#import "FocusObserver.h"
#import "WindowCoordinator.h"
#include "DragPolicy.h"
#include <math.h>
#include <unistd.h>

static NSString *const FSVersion=@"0.8.0";
static NSArray<NSString *> *layoutNames(void) {
    return @[@"左右两栏",@"三列等分",@"左主窗口＋右侧上下",@"四格布局",@"上下两栏",@"填满可用区域",
             @"左侧上下＋右主窗口",@"上主窗口＋下方左右",@"三行等分",@"左主窗口＋右侧三行"];
}
static NSArray<NSDictionary *> *quickPresets(void) {
    return @[@{@"name":@"左右平分",@"layout":@0,@"ratio":@.5},
             @{@"name":@"左宽右窄",@"layout":@0,@"ratio":@(2.0/3.0)},
             @{@"name":@"三栏平分",@"layout":@1,@"ratio":@.5},
             @{@"name":@"左大右上下",@"layout":@2,@"ratio":@(2.0/3.0)},
             @{@"name":@"四格平分",@"layout":@3,@"ratio":@.5},
             @{@"name":@"上下平分",@"layout":@4,@"ratio":@.5},
             @{@"name":@"右大左上下",@"layout":@(FSLayoutStackAndMain),@"ratio":@(1.0/3.0)},
             @{@"name":@"上大下左右",@"layout":@(FSLayoutMainTopAndColumns),@"ratio":@(2.0/3.0)},
             @{@"name":@"三行平分",@"layout":@(FSLayoutRows3),@"ratio":@.5},
             @{@"name":@"左大右三行",@"layout":@(FSLayoutMainAndThree),@"ratio":@(2.0/3.0)},
             @{@"name":@"左半·右上下",@"layout":@(FSLayoutMainAndStack),@"ratio":@.5,
               @"detail":@"左右各占半屏，右侧再分为上下两格"},
             @{@"name":@"左上下·右半",@"layout":@(FSLayoutStackAndMain),@"ratio":@.5,
               @"detail":@"左右各占半屏，左侧再分为上下两格"}];
}
static NSRect nsrect(FSRect r) { return NSMakeRect(r.x,r.y,r.width,r.height); }
static FSRect fsrect(NSRect r) { return (FSRect){r.origin.x,r.origin.y,r.size.width,r.size.height}; }
static CGPoint mouseAXPoint(NSEvent *event) {
    if(event.CGEvent)return CGEventGetLocation(event.CGEvent);
    NSPoint point=event.locationInWindow; /* Global mouse events use screen coordinates. */
    return CGPointMake(point.x,NSMaxY(NSScreen.screens.firstObject.frame)-point.y);
}
static NSTextField *label(NSString *text, NSRect frame, CGFloat size, BOOL bold) {
    NSTextField *v=[NSTextField labelWithString:text];
    v.frame=frame; v.font=bold?[NSFont systemFontOfSize:size weight:NSFontWeightSemibold]:[NSFont systemFontOfSize:size];
    v.lineBreakMode=NSLineBreakByTruncatingTail;
    return v;
}
static NSButton *button(NSString *title, NSRect frame, id target, SEL action) {
    NSButton *v=[NSButton buttonWithTitle:title target:target action:action];
    v.frame=frame; v.bezelStyle=NSBezelStyleRounded; return v;
}

static NSArray<NSString *> *positionNames(FSLayout layout) {
    switch(layout) {
        case FSLayoutColumns2:return @[@"左",@"右"];
        case FSLayoutColumns3:return @[@"左",@"中",@"右"];
        case FSLayoutMainAndStack:return @[@"左侧主窗",@"右上",@"右下"];
        case FSLayoutGrid:return @[@"左上",@"右上",@"左下",@"右下"];
        case FSLayoutRows2:return @[@"上",@"下"];
        case FSLayoutFill:return @[@"整屏"];
        case FSLayoutStackAndMain:return @[@"左上",@"左下",@"右侧主窗"];
        case FSLayoutMainTopAndColumns:return @[@"上方主窗",@"左下",@"右下"];
        case FSLayoutRows3:return @[@"上",@"中",@"下"];
        case FSLayoutMainAndThree:return @[@"左侧主窗",@"右上",@"右中",@"右下"];
        default:return @[];
    }
}
static NSImage *layoutIcon(NSDictionary *preset) {
    NSImage *icon=[[NSImage alloc] initWithSize:NSMakeSize(72,44)];
    [icon lockFocus];[NSColor.labelColor setFill];
    FSRect zones[4];int n=FSBuildZones([preset[@"layout"] intValue],(FSRect){0,0,72,44},[preset[@"ratio"] doubleValue],3,zones);
    for(int i=0;i<n;i++) {
        FSRect r=zones[i];NSRect f=NSMakeRect(r.x,44-r.y-r.height,r.width,r.height);
        [[NSBezierPath bezierPathWithRoundedRect:f xRadius:2 yRadius:2] fill];
    }
    [icon unlockFocus];icon.template=YES;return icon;
}

@interface FSFlippedView : NSView @end
@implementation FSFlippedView
- (BOOL)isFlipped {return YES;}
@end
@interface FSCard : FSFlippedView @end
@implementation FSCard
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.controlBackgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12 yRadius:12] fill];
}
@end

@interface FSPreview : NSView
@property(nonatomic) FSLayout layout;
@property(nonatomic) double ratio;
@property(nonatomic) double gap;
@property(nonatomic) double aspect;
@property(nonatomic,copy) NSArray<NSString *> *names;
@property(nonatomic) BOOL freeMode;
@property(nonatomic) NSInteger activeSlot;
@property(nonatomic,copy) void (^onSelectSlot)(NSInteger slot);
@end
@implementation FSPreview
- (BOOL)isFlipped { return YES; }
- (int)buildPreviewZones:(FSRect *)zones {
    NSRect outer=NSInsetRect(self.bounds,12,12);
    double aspect=self.aspect>0?self.aspect:16.0/9.0;
    double width=outer.size.width,height=width/aspect;
    if(height>outer.size.height) {height=outer.size.height;width=height*aspect;}
    FSRect area={outer.origin.x+(outer.size.width-width)/2,outer.origin.y+(outer.size.height-height)/2,width,height};
    return FSBuildZones(self.layout,area,self.ratio,5,zones);
}
- (void)mouseDown:(NSEvent *)event {
    if(self.freeMode)return;
    NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
    FSRect zones[4];int n=[self buildPreviewZones:zones];
    for(int i=0;i<n;i++)if(NSPointInRect(point,nsrect(zones[i])) && self.onSelectSlot){self.onSelectSlot(i);break;}
}
- (void)resetCursorRects {[self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];}
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor controlBackgroundColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12 yRadius:12] fill];
    if(self.freeMode) {
        NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];style.alignment=NSTextAlignmentCenter;
        [@"自由模式\n窗口按你自己的方式摆放" drawInRect:NSInsetRect(self.bounds,20,48)
            withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:15],NSForegroundColorAttributeName:NSColor.secondaryLabelColor,NSParagraphStyleAttributeName:style}];
        return;
    }
    FSRect zones[4];int n=[self buildPreviewZones:zones];
    NSArray *colors=@[NSColor.systemBlueColor,NSColor.systemTealColor,NSColor.systemPurpleColor,NSColor.systemOrangeColor];
    for(int i=0;i<n;i++) {
        NSRect r=nsrect(zones[i]);
        [colors[i] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:7 yRadius:7] fill];
        if(i==self.activeSlot) {
            [NSColor.labelColor setStroke];NSBezierPath *border=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r,2,2) xRadius:6 yRadius:6];
            border.lineWidth=3;[border stroke];
        }
        NSString *name=((NSUInteger)i<self.names.count && self.names[i].length)?self.names[i]:@"空闲分区";
        NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];
        style.alignment=NSTextAlignmentCenter; style.lineBreakMode=NSLineBreakByTruncatingTail;
        NSDictionary *a=@{NSFontAttributeName:[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold],
                           NSForegroundColorAttributeName:NSColor.whiteColor,NSParagraphStyleAttributeName:style};
        [[NSString stringWithFormat:@"%d",i+1] drawInRect:NSMakeRect(r.origin.x+3,NSMidY(r)-28,r.size.width-6,32) withAttributes:a];
        a=@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName:NSColor.whiteColor,NSParagraphStyleAttributeName:style};
        [name drawInRect:NSMakeRect(r.origin.x+6,NSMidY(r)+8,r.size.width-12,18) withAttributes:a];
    }
}
@end

@interface FSDragOverlayView : FSFlippedView
@property(nonatomic,copy) NSArray<NSValue *> *zoneRects;
@property(nonatomic) NSInteger sourceSlot;
@property(nonatomic) NSInteger targetSlot;
@end
@implementation FSDragOverlayView
- (void)drawRect:(NSRect)dirtyRect {
    for(NSUInteger i=0;i<self.zoneRects.count;i++) {
        NSRect r=NSInsetRect(self.zoneRects[i].rectValue,5,5);if(NSWidth(r)<50 || NSHeight(r)<40)continue;
        BOOL selected=(NSInteger)i==self.targetSlot;
        NSColor *color=NSColor.systemTealColor;
        NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:r xRadius:12 yRadius:12];
        [[color colorWithAlphaComponent:selected?.23:.065] setFill];[path fill];
        [[color colorWithAlphaComponent:selected?.95:.5] setStroke];path.lineWidth=selected?4:2;[path stroke];
        NSString *caption=selected?[NSString stringWithFormat:@"松手移入 %lu · 原窗口留在下层",(unsigned long)i+1]:
            [NSString stringWithFormat:@"分区 %lu%@",(unsigned long)i+1,(NSInteger)i==self.sourceSlot?@" · 原位置":@""];
        NSRect badge=NSMakeRect(NSMinX(r)+12,NSMinY(r)+12,MIN(NSWidth(r)-24,244),30);
        [[color colorWithAlphaComponent:.95] setFill];[[NSBezierPath bezierPathWithRoundedRect:badge xRadius:8 yRadius:8] fill];
        [caption drawInRect:NSInsetRect(badge,8,6) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:NSColor.whiteColor}];
    }
}
@end

@interface FSApp : NSObject<NSApplicationDelegate,NSMenuDelegate,NSWindowDelegate> {
    EventHotKeyRef _hotKeys[10];
    EventHandlerRef _hotHandler;
}
@property(nonatomic,strong) FSWorkspaceStore *store;
@property(nonatomic,strong) FSWindowCoordinator *coordinator;
@property(nonatomic,strong) FSFocusObserver *observer;
@property(nonatomic,strong) FSDragGuard *guard;
@property(nonatomic,strong) NSStatusItem *statusItem;
@property(nonatomic,strong) NSWindow *settingsWindow;
@property(nonatomic,strong) FSFlippedView *mainView;
@property(nonatomic,strong) FSFlippedView *advancedView;
@property(nonatomic,strong) FSPreview *preview;
@property(nonatomic,strong) NSTextField *stateLabel;
@property(nonatomic,strong) NSTextField *statusLabel;
@property(nonatomic,strong) NSTextField *permissionLabel;
@property(nonatomic,strong) NSTextField *ratioLabel;
@property(nonatomic,strong) NSTextField *gapLabel;
@property(nonatomic,strong) NSButton *freeButton;
@property(nonatomic,strong) NSMutableArray<NSButton *> *presetButtons;
@property(nonatomic,strong) NSMutableArray<NSButton *> *favoriteButtons;
@property(nonatomic,strong) NSPopUpButton *favoritePopup;
@property(nonatomic,strong) NSPopUpButton *managePopup;
@property(nonatomic,strong) NSPopUpButton *screenPopup;
@property(nonatomic,strong) NSPopUpButton *layoutPopup;
@property(nonatomic,strong) NSSlider *ratioSlider;
@property(nonatomic,strong) NSSlider *gapSlider;
@property(nonatomic,strong) NSButton *newWindowCheckbox;
@property(nonatomic,strong) NSButton *restoreMinCheckbox;
@property(nonatomic,strong) NSButton *preventDragCheckbox;
@property(nonatomic,strong) NSMutableArray<NSPopUpButton *> *stackPopups;
@property(nonatomic,strong) NSMutableArray<NSTextField *> *stackLabels;
@property(nonatomic,strong) NSMutableArray<NSButton *> *pinButtons;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) id monitor;
@property(nonatomic,strong) NSPanel *overlay;
@property(nonatomic,strong) FSDragOverlayView *overlayView;
@property(nonatomic,strong) FSWindow *dragWindow;
@property(nonatomic) FSRect dragFrame;
@property(nonatomic) FSRect dragVisibleFrame;
@property(nonatomic) FSRect dragMovedFrame;
@property(nonatomic) CGPoint dragStart;
@property(nonatomic) CGPoint dragPoint;
@property(nonatomic) uint64_t dragToken;
@property(nonatomic) BOOL dragMotion;
@property(nonatomic) BOOL dragMoved;
@property(nonatomic) BOOL dragPlainChrome;
@property(nonatomic) BOOL pendingDrop;
@property(nonatomic) NSInteger dragSource;
@property(nonatomic,copy) NSString *dragResult;
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,copy) void (^deferredCommand)(void);
@property(nonatomic) BOOL suspended;
@property(nonatomic) BOOL menuOpen;
@property(nonatomic) BOOL refreshing;
@property(nonatomic) BOOL permissionPromptShown;
@property(nonatomic) BOOL moreExpanded;
@property(nonatomic) pid_t lastExternalPID;
@property(nonatomic) NSTimeInterval nextUIRefresh;
- (void)handleHotKey:(UInt32)identifier;
- (void)refreshControls;
- (void)runDeferredCommand;
- (void)completeDrop;
@end
static OSStatus hotKeyCallback(EventHandlerCallRef next,EventRef event,void *context) {
    EventHotKeyID identifier;OSStatus result=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(identifier),NULL,&identifier);
    if(result==noErr)[(__bridge FSApp *)context handleHotKey:identifier.id];return noErr;
}

@implementation FSApp
- (NSMutableDictionary *)profile {return self.store.activeProfile;}
- (NSArray<NSMutableDictionary *> *)favorites {
    NSMutableArray *array=[NSMutableArray new];for(NSMutableDictionary *p in self.store.config[@"profiles"])if([p[@"favorite"] boolValue])[array addObject:p];return array;
}
- (int)zoneCount {
    FSRect zones[4];return FSBuildZones([self.profile[@"layout"] intValue],(FSRect){0,0,1000,700},.5,8,zones);
}
- (void)message:(NSString *)message {self.statusText=message;if(self.statusLabel)self.statusLabel.stringValue=message;}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *display=NSScreen.screens.count?FSDisplayID(NSScreen.mainScreen?:NSScreen.screens.firstObject):@"";
    NSURL *directory=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    self.store=[[FSWorkspaceStore alloc] initWithURL:[[directory URLByAppendingPathComponent:@"定屏"] URLByAppendingPathComponent:@"layouts.json"] defaultDisplay:display];
    self.coordinator=[[FSWindowCoordinator alloc] initWithStore:self.store];self.observer=[FSFocusObserver new];self.guard=[FSDragGuard new];
    self.lastExternalPID=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    self.dragResult=@"尚未拖动";self.statusText=self.store.loadNote?:@"点击布局开始；拖动保存位置；常用方案独立记忆。";
    __weak FSApp *weakSelf=self;
    self.coordinator.onMessage=^(NSString *text){[weakSelf message:text];};
    self.coordinator.onChange=^{FSApp *app=weakSelf;if(app.settingsWindow.visible && !app.menuOpen)[app refreshControls];};
    self.coordinator.onIdle=^{[weakSelf runDeferredCommand];};
    self.observer.onChange=^{FSApp *app=weakSelf;if(app && !app.suspended && !app.menuOpen && !NSApp.modalWindow)
        [app.coordinator observeFocusedWindow:FSFocusedWindow(app.lastExternalPID)];};
    self.guard.mayIntercept=^BOOL{FSApp *app=weakSelf;return app && app.coordinator.enabled && !app.coordinator.busy &&
        [app.profile[@"preventDrag"] boolValue] && !app.suspended && !app.menuOpen && !NSApp.modalWindow;};
    self.guard.onFailure=^(NSString *text){[weakSelf message:text];};
    self.monitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp handler:^(NSEvent *event){
        FSApp *app=weakSelf;if(!app)return;
        if(event.type==NSEventTypeLeftMouseDown)[app beginWindowDrag:event];
        else if(event.type==NSEventTypeLeftMouseDragged)[app updateWindowDrag:event];
        else [app releaseWindowDrag:event];
    }];
    self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image=[NSImage imageWithSystemSymbolName:@"rectangle.split.2x1" accessibilityDescription:@"定屏"];
    self.statusItem.button.image.template=YES;if(!self.statusItem.button.image)self.statusItem.button.title=@"定屏";
    NSMenu *menu=[NSMenu new];menu.delegate=self;self.statusItem.menu=menu;
    NSNotificationCenter *nc=NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self selector:@selector(appActivated:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    for(NSString *name in @[NSWorkspaceActiveSpaceDidChangeNotification,NSWorkspaceWillSleepNotification,NSWorkspaceSessionDidResignActiveNotification])
        [nc addObserver:self selector:@selector(pauseSession:) name:name object:nil];
    for(NSString *name in @[NSWorkspaceDidWakeNotification,NSWorkspaceSessionDidBecomeActiveNotification])
        [nc addObserver:self selector:@selector(resumeSession:) name:name object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [self registerHotKeys];
    self.timer=[NSTimer timerWithTimeInterval:.35 target:self selector:@selector(tick:) userInfo:nil repeats:YES];self.timer.tolerance=.06;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self.store save:NULL];
    BOOL newVersion=![[NSUserDefaults.standardUserDefaults stringForKey:@"lastShownVersion"] isEqual:FSVersion];
    if(newVersion || !AXIsProcessTrusted())[self showSettings:nil];
    /* Startup arranges in the background and keeps minimized windows minimized. */
    if(self.coordinator.enabled && AXIsProcessTrusted() && FSScreenWithID(self.profile[@"display"]))
        [self.coordinator activateProfile:self.profile[@"id"] preferredWindow:nil foreground:NO];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.coordinator save];[self.guard stop];[self.observer stop];[self.timer invalidate];
    if(self.monitor)[NSEvent removeMonitor:self.monitor];for(int i=0;i<10;i++)if(_hotKeys[i])UnregisterEventHotKey(_hotKeys[i]);
    if(_hotHandler)RemoveEventHandler(_hotHandler);
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {[self showSettings:nil];return NO;}
- (BOOL)windowShouldClose:(NSWindow *)window {[window orderOut:nil];return NO;}
- (void)appActivated:(NSNotification *)note {
    NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];
    if(app.processIdentifier!=getpid() && app.activationPolicy==NSApplicationActivationPolicyRegular) {
        self.lastExternalPID=app.processIdentifier;if(self.coordinator.enabled)[self.observer watchPID:app.processIdentifier];
        [self.coordinator observeFocusedWindow:FSFocusedWindow(app.processIdentifier)];
    }
}
- (void)pauseSession:(NSNotification *)note {
    [self cancelInput];[self.coordinator pause];[self.observer stop];
    self.suspended=![note.name isEqual:NSWorkspaceActiveSpaceDidChangeNotification];
    if(!self.suspended)self.nextUIRefresh=NSDate.timeIntervalSinceReferenceDate+1;
}
- (void)resumeSession:(NSNotification *)note {self.suspended=NO;[self.coordinator pause];}
- (void)screensChanged:(NSNotification *)note {[self cancelInput];[self.coordinator pause];[self refreshControls];}
- (void)tick:(NSTimer *)timer {
    if(self.dragToken && !self.pendingDrop && !CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft) && NSEvent.pressedMouseButtons==0)
        [self releaseWindowDrag:nil]; /* Recover a missed global mouse-up. */
    if(!AXIsProcessTrusted()) {[self.guard stop];[self.observer stop];return;}
    if(self.suspended || self.menuOpen || NSApp.modalWindow)return;
    [self.coordinator tick];
    if(self.coordinator.enabled && !self.coordinator.busy && NSEvent.pressedMouseButtons==0) {
        NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
        if(front.processIdentifier!=getpid()) {
            self.lastExternalPID=front.processIdentifier;[self.observer watchPID:front.processIdentifier];
            [self.coordinator observeFocusedWindow:FSFocusedWindow(front.processIdentifier)];
        }
    }
    [self syncGuard];
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    if(self.settingsWindow.visible && now>=self.nextUIRefresh){self.nextUIRefresh=now+1;[self refreshControls];}
}
- (void)performWhenIdle:(void (^)(void))command {
    if(self.coordinator.busy || self.dragToken) {self.deferredCommand=command;[self message:@"操作已排队，将在当前拖放或布局切换完成后执行。"];}else command();
}
- (void)runDeferredCommand {
    if(!self.deferredCommand || self.coordinator.busy || self.dragToken)return;
    void (^command)(void)=self.deferredCommand;self.deferredCommand=nil;command();
}
- (BOOL)requirePermission {
    if(AXIsProcessTrusted())return YES;
    if(!self.permissionPromptShown) {self.permissionPromptShown=YES;
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});}
    [self message:[NSString stringWithFormat:@"当前这份程序尚未授权：%@。请在辅助功能列表添加此路径。",NSBundle.mainBundle.bundlePath]];
    [self showSettings:nil];return NO;
}
- (void)activateProfileID:(NSString *)identifier {
    if(![self requirePermission])return;
    __weak FSApp *weakSelf=self;
    [self performWhenIdle:^{FSApp *app=weakSelf;if(!app)return;NSMutableDictionary *p=[app.store profileWithID:identifier];
        if(!p)return;if(!FSScreenWithID(p[@"display"])) {[app message:@"方案的显示器未连接，请在更多设置中选择显示器。"];
            app.store.config[@"active"]=identifier;[app.coordinator pause];[app.coordinator save];[app showSettings:nil];return;}
        FSWindow *preferred=FSFocusedWindow(app.lastExternalPID);
        [app.coordinator activateProfile:identifier preferredWindow:preferred foreground:YES];[app syncGuard];
    }];
}
- (void)activatePreset:(NSInteger)index {
    if(index<0 || (NSUInteger)index>=quickPresets().count || ![self requirePermission])return;
    __weak FSApp *weakSelf=self;
    [self performWhenIdle:^{FSApp *app=weakSelf;if(!app)return;
        NSString *display=app.profile[@"display"];
        if(!FSScreenWithID(display))display=NSScreen.screens.count?FSDisplayID(NSScreen.mainScreen?:NSScreen.screens.firstObject):@"";
        NSDictionary *preset=quickPresets()[index];
        NSMutableDictionary *p=[app.store builtin:index name:preset[@"name"] display:display layout:[preset[@"layout"] integerValue] ratio:[preset[@"ratio"] doubleValue]];
        [app activateProfileID:p[@"id"]];
    }];
}
- (void)presetFromButton:(NSButton *)sender {[self activatePreset:sender.tag];}
- (void)presetFromMenu:(NSMenuItem *)sender {[self activatePreset:[sender.representedObject integerValue]];}
- (void)profileFromMenu:(NSMenuItem *)sender {[self activateProfileID:sender.representedObject];}
- (void)favoriteFromButton:(NSButton *)sender {NSArray *list=self.favorites;if((NSUInteger)sender.tag<list.count)[self activateProfileID:list[sender.tag][@"id"]];}
- (void)applyCurrent:(id)sender {[self activateProfileID:self.profile[@"id"]];}
- (void)freeMode:(id)sender {self.deferredCommand=nil;[self cancelInput];[self.coordinator setFreeMode];[self.guard stop];[self.observer stop];[self refreshControls];}
- (NSString *)askName:(NSString *)title initial:(NSString *)initial {
    NSAlert *alert=[NSAlert new];alert.messageText=title;alert.informativeText=@"分区形状、窗口位置和叠放顺序一起保存。";
    NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,300,26)];field.stringValue=initial;
    alert.accessoryView=field;[alert addButtonWithTitle:@"保存"];[alert addButtonWithTitle:@"取消"];[NSApp activateIgnoringOtherApps:YES];
    [alert.window setInitialFirstResponder:field];if([alert runModal]!=NSAlertFirstButtonReturn)return nil;
    NSString *value=[field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return value.length?[value substringToIndex:MIN(value.length,(NSUInteger)48)]:nil;
}
- (void)saveFavorite:(id)sender {
    __weak FSApp *weakSelf=self;[self performWhenIdle:^{FSApp *app=weakSelf;if(!app)return;
        if(app.coordinator.enabled)[app.coordinator tick];
        NSString *name=[app askName:@"保存为常用方案" initial:[app.profile[@"favorite"] boolValue]?[app.profile[@"name"] stringByAppendingString:@" 副本"]:app.profile[@"name"]];
        if(name){[app.coordinator saveFavorite:name];[app refreshControls];}
    }];
}
- (void)renameFavorite:(id)sender {
    if(![self.profile[@"favorite"] boolValue]){[self message:@"先点「保存为常用方案」，再为这份方案重命名。 "];return;}
    __weak FSApp *weakSelf=self;[self performWhenIdle:^{FSApp *app=weakSelf;if(!app)return;
        NSString *name=[app askName:@"重命名当前方案" initial:app.profile[@"name"]];
        if(name){app.profile[@"name"]=name;[app.coordinator save];}
    }];
}
- (void)deleteFavorite:(id)sender {
    if(![self.profile[@"favorite"] boolValue])return;
    __weak FSApp *weakSelf=self;[self performWhenIdle:^{FSApp *app=weakSelf;if(!app)return;
        NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:@"删除方案「%@」？",app.profile[@"name"]];
        alert.informativeText=@"只删除这份方案的记忆，窗口保持打开。";[alert addButtonWithTitle:@"删除方案"];[alert addButtonWithTitle:@"取消"];
        if([alert runModal]!=NSAlertFirstButtonReturn)return;
        NSString *removed=app.profile[@"id"],*display=app.profile[@"display"];
        NSMutableDictionary *fallback=[app.store builtin:0 name:@"左右平分" display:display layout:0 ratio:.5];
        app.store.config[@"active"]=fallback[@"id"];[app.store deleteFavorite:removed];
        [app.coordinator setFreeMode];[app refreshControls];[app message:@"方案已删除，已进入自由模式；窗口保持当前位置。"];
    }];
}
- (void)nextFavorite:(id)sender {
    NSArray *list=self.favorites;if(!list.count){[self message:@"先将当前布局保存为常用方案。 "];return;}
    NSUInteger current=NSNotFound;for(NSUInteger i=0;i<list.count;i++)if([list[i][@"id"] isEqual:self.profile[@"id"]])current=i;
    [self activateProfileID:list[current==NSNotFound?0:(current+1)%list.count][@"id"]];
}
- (void)focusWindowFromMenu:(NSMenuItem *)sender {
    FSWindow *w=sender.representedObject;if(![self requirePermission] || self.coordinator.busy)return;
    [w restoreForLayout];[w focusWindow];[self.coordinator observeFocusedWindow:w];
}
- (void)moveWindowFromMenu:(NSMenuItem *)sender {
    NSDictionary *value=sender.representedObject;if(![self requirePermission])return;
    FSWindow *w=value[@"window"];NSInteger slot=[value[@"slot"] integerValue];
    __weak FSApp *weakSelf=self;[self performWhenIdle:^{FSApp *app=weakSelf;if(!app)return;
        if(!app.coordinator.enabled){[app message:@"先点击一个布局，再选择移入的窗口。 "];return;}
        [w restoreForLayout];[app.coordinator assignWindow:w toSlot:slot];[w focusWindow];
    }];
}
- (void)togglePin:(NSButton *)sender {[self.coordinator togglePinInSlot:sender.tag];}
- (void)refreshWindows:(id)sender {[self.coordinator tick];[self refreshControls];}
- (void)geometryChanged {
    [self.coordinator save];if(self.coordinator.enabled)[self activateProfileID:self.profile[@"id"]];else [self refreshControls];
}
- (void)screenChanged:(NSPopUpButton *)sender {if(self.refreshing)return;self.profile[@"display"]=sender.selectedItem.representedObject;[self geometryChanged];}
- (void)layoutChanged:(NSPopUpButton *)sender {if(self.refreshing)return;self.profile[@"layout"]=@(sender.indexOfSelectedItem);[self geometryChanged];}
- (void)ratioChanged:(NSSlider *)sender {if(self.refreshing)return;self.profile[@"ratio"]=@(round(sender.doubleValue)/100.0);[self geometryChanged];}
- (void)gapChanged:(NSSlider *)sender {if(self.refreshing)return;self.profile[@"gap"]=@(round(sender.doubleValue));[self geometryChanged];}
- (void)optionChanged:(NSButton *)sender {
    if(self.refreshing)return;NSString *key=sender==self.newWindowCheckbox?@"newWindowInActiveSlot":sender==self.restoreMinCheckbox?@"restoreMinimized":@"preventDrag";
    self.profile[key]=@(sender.state==NSControlStateValueOn);[self.coordinator save];[self syncGuard];
}
- (void)syncGuard {
    if(!self.coordinator.enabled || self.coordinator.busy || self.suspended || ![self.profile[@"preventDrag"] boolValue] || !AXIsProcessTrusted()) {
        self.guard.targets=@[];if(!CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft))[self.guard stop];return;
    }
    if(!self.guard.running && !self.guard.faulted){NSString *error=nil;if(![self.guard start:&error])[self message:error?:@"禁止拖动暂不可用。 "];}
    NSMutableArray *targets=[NSMutableArray new];NSArray *rows=FSOnScreenRows();
    for(int i=0;i<self.zoneCount;i++)for(FSWindow *w in [self.coordinator windowsInSlot:i]) {
        FSRect frame;if(![w isUsable] || ![w isOnScreen:rows] || ![w readFrame:&frame])continue;
        FSDragTarget *target=[FSDragTarget new];target.window=w;target.frame=frame;[targets addObject:target];
    }
    self.guard.targets=targets;
}
- (void)beginWindowDrag:(NSEvent *)event {
    if(self.pendingDrop)[self completeDrop];
    if(!self.coordinator.enabled || self.suspended || [self.profile[@"preventDrag"] boolValue] || !AXIsProcessTrusted() || NSApp.modalWindow)return;
    CGPoint point=mouseAXPoint(event);FSRect visible={0},frame={0};BOOL plain=NO;NSString *reason=nil;
    FSWindow *w=FSWindowAtPointWithChrome(point,&visible,&plain,&reason);
    if(!w){self.dragResult=reason?:@"没有识别起点窗口";return;}
    if(!FSPassiveDragCandidate(visible,point.x,point.y) || ![w readFrame:&frame])return;
    uint64_t token=[self.coordinator beginDrag];if(!token)return;
    self.dragWindow=w;self.dragFrame=frame;self.dragVisibleFrame=visible;self.dragStart=point;self.dragPoint=point;
    self.dragSource=[self.coordinator slotForWindow:w];self.dragPlainChrome=plain;self.dragToken=token;self.dragMotion=NO;self.dragMoved=NO;
    self.dragResult=@"已锁定起点窗口，等待标题栏移动";
}
- (void)updateWindowDrag:(NSEvent *)event {
    if(!self.dragToken || self.pendingDrop)return;self.dragMotion=YES;self.dragPoint=mouseAXPoint(event);
    FSRect actual={0};if([self.dragWindow readFrame:&actual] &&
        (FSWindowWasDragged(self.dragFrame,actual) || FSWindowTitleMovedFromVisible(self.dragFrame,actual,self.dragVisibleFrame,self.dragStart.x,self.dragStart.y))) {
        self.dragMoved=YES;self.dragMovedFrame=actual;
    }
    BOOL pointer=FSVisibleFrameMatch(self.dragFrame,self.dragVisibleFrame) &&
        FSPointerDragIntent(self.dragVisibleFrame,(int)self.dragSource,self.dragPlainChrome,self.dragStart.x,self.dragStart.y,self.dragPoint.x,self.dragPoint.y);
    if(!self.dragMoved && !pointer)return;
    if(!self.dragMoved){actual=self.dragFrame;actual.x+=self.dragPoint.x-self.dragStart.x;actual.y+=self.dragPoint.y-self.dragStart.y;}
    else actual=self.dragMovedFrame;
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);if(!screen)return;FSRect area=FSUsableFrame(screen),zones[4];
    int count=FSBuildZones([self.profile[@"layout"] intValue],area,[self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones);
    NSInteger target=FSDropDestination(zones,count,(int)self.dragSource,self.dragPoint.x,self.dragPoint.y,actual);
    NSRect frame=screen.visibleFrame;
    if(!self.overlay) {
        self.overlay=[[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        self.overlay.opaque=NO;self.overlay.backgroundColor=NSColor.clearColor;self.overlay.hasShadow=NO;self.overlay.ignoresMouseEvents=YES;
        self.overlay.hidesOnDeactivate=NO;self.overlay.level=NSFloatingWindowLevel;
        self.overlay.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorTransient;
        self.overlayView=[[FSDragOverlayView alloc] initWithFrame:NSMakeRect(0,0,NSWidth(frame),NSHeight(frame))];self.overlay.contentView=self.overlayView;
    }
    [self.overlay setFrame:frame display:NO];self.overlayView.frame=NSMakeRect(0,0,NSWidth(frame),NSHeight(frame));
    NSMutableArray *rects=[NSMutableArray new];for(int i=0;i<count;i++)[rects addObject:[NSValue valueWithRect:NSMakeRect(zones[i].x-area.x,zones[i].y-area.y,zones[i].width,zones[i].height)]];
    self.overlayView.zoneRects=rects;self.overlayView.sourceSlot=self.dragSource;self.overlayView.targetSlot=target;self.overlayView.needsDisplay=YES;
    [self.overlay orderFrontRegardless];
}
- (void)releaseWindowDrag:(NSEvent *)event {
    if(!self.dragToken || self.pendingDrop)return;if(event)self.dragPoint=mouseAXPoint(event);[self.overlay orderOut:nil];
    if(![self.coordinator releaseDrag:self.dragToken]){[self cancelInput];return;}
    self.pendingDrop=YES;uint64_t token=self.dragToken;__weak FSApp *weakSelf=self;
    /* The high-priority gate remains closed through native mouse-up delivery. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.12*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        FSApp *app=weakSelf;if(app.dragToken==token && app.pendingDrop)[app completeDrop];
    });
}
- (void)completeDrop {
    if(!self.dragToken)return;FSWindow *w=self.dragWindow;uint64_t token=self.dragToken;FSRect actual={0};BOOL moved=NO;
    if(self.dragMotion && [w readFrame:&actual])moved=FSWindowWasDragged(self.dragFrame,actual) ||
        FSWindowTitleMovedFromVisible(self.dragFrame,actual,self.dragVisibleFrame,self.dragStart.x,self.dragStart.y) || self.dragMoved;
    BOOL pointer=self.dragMotion && FSVisibleFrameMatch(self.dragFrame,self.dragVisibleFrame) &&
        FSPointerDragIntent(self.dragVisibleFrame,(int)self.dragSource,self.dragPlainChrome,self.dragStart.x,self.dragStart.y,self.dragPoint.x,self.dragPoint.y);
    NSInteger destination=-1;NSScreen *screen=FSScreenWithID(self.profile[@"display"]);
    if((moved || pointer) && screen && [w isUsable]) {
        if(self.dragMoved)actual=self.dragMovedFrame;
        else if(!moved){actual=self.dragFrame;actual.x+=self.dragPoint.x-self.dragStart.x;actual.y+=self.dragPoint.y-self.dragStart.y;}
        FSRect zones[4];int count=FSBuildZones([self.profile[@"layout"] intValue],FSUsableFrame(screen),[self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones);
        destination=FSDropDestination(zones,count,(int)self.dragSource,self.dragPoint.x,self.dragPoint.y,actual);
    }
    self.dragResult=destination>=0?[NSString stringWithFormat:@"手动拖入分区 %ld；原窗口留在下层，位置已记忆。",(long)destination+1]:
        ((moved || pointer)?@"落点不在目标分区内，归属记录保留。":@"本次为点击或内容拖拽，分区归属未变。 ");
    self.dragToken=0;self.pendingDrop=NO;self.dragWindow=nil;
    [self.coordinator finishDrag:token window:destination>=0?w:nil destination:destination];[self syncGuard];[self runDeferredCommand];
}
- (void)cancelInput {
    [self.overlay orderOut:nil];self.dragToken=0;self.pendingDrop=NO;self.dragWindow=nil;self.deferredCommand=nil;
}
- (NSMenuItem *)item:(NSString *)title action:(SEL)action value:(id)value {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];item.target=self;item.representedObject=value;return item;
}
- (void)menuWillOpen:(NSMenu *)menu {self.menuOpen=YES;}
- (void)menuDidClose:(NSMenu *)menu {self.menuOpen=NO;}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if(menu!=self.statusItem.menu)return;[menu removeAllItems];
    [menu addItem:[self item:[NSString stringWithFormat:@"定屏 · %@ · %@",self.coordinator.enabled?@"自动分屏":@"自由模式",self.profile[@"name"]] action:NULL value:nil]];
    [menu addItem:[self item:@"打开定屏" action:@selector(showSettings:) value:nil]];
    [menu addItem:[self item:@"自由模式" action:@selector(freeMode:) value:nil]];
    NSMenu *saved=[NSMenu new];saved.delegate=self;
    for(NSDictionary *p in self.favorites){NSMenuItem *i=[self item:p[@"name"] action:@selector(profileFromMenu:) value:p[@"id"]];
        i.state=self.coordinator.enabled && [p[@"id"] isEqual:self.profile[@"id"]]?NSControlStateValueOn:NSControlStateValueOff;[saved addItem:i];}
    if(!saved.numberOfItems)[saved addItem:[self item:@"还没有常用方案" action:NULL value:nil]];
    NSMenuItem *savedItem=[self item:@"常用方案" action:NULL value:nil];savedItem.submenu=saved;[menu addItem:savedItem];
    [menu addItem:[self item:@"保存为常用方案…" action:@selector(saveFavorite:) value:nil]];
    NSMenu *layouts=[NSMenu new];layouts.delegate=self;NSInteger index=0;
    for(NSDictionary *p in quickPresets())[layouts addItem:[self item:p[@"name"] action:@selector(presetFromMenu:) value:@(index++)]];
    NSMenuItem *layoutItem=[self item:@"切换布局" action:NULL value:nil];layoutItem.submenu=layouts;[menu addItem:layoutItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self item:@"权限与窗口诊断" action:@selector(showDiagnostics:) value:nil]];
    [menu addItem:[self item:@"打开辅助功能设置" action:@selector(openPermission:) value:nil]];
    [menu addItem:[self item:@"使用说明" action:@selector(showHelp:) value:nil]];
    [menu addItem:[self item:@"退出定屏" action:@selector(quit:) value:nil]];
}
- (void)buildUI {
    self.settingsWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,980,610)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title=@"定屏 · 布局与常用方案";self.settingsWindow.delegate=self;self.settingsWindow.releasedWhenClosed=NO;
    [self.settingsWindow center];NSView *root=self.settingsWindow.contentView;
    self.mainView=[[FSFlippedView alloc] initWithFrame:NSMakeRect(0,0,980,610)];[root addSubview:self.mainView];
    self.advancedView=[[FSFlippedView alloc] initWithFrame:NSMakeRect(0,0,980,610)];self.advancedView.hidden=YES;[root addSubview:self.advancedView];
    NSView *v=self.mainView;
    [v addSubview:label(@"定屏",NSMakeRect(24,12,120,30),25,YES)];
    [v addSubview:label(@"点击只置前 · 拖动记位置 · 每种布局独立保存",NSMakeRect(151,21,520,20),12,NO)];
    self.stateLabel=label(@"",NSMakeRect(680,17,276,23),12,YES);self.stateLabel.alignment=NSTextAlignmentRight;[v addSubview:self.stateLabel];
    [v addSubview:label(@"常用方案",NSMakeRect(25,70,78,22),12,YES)];self.favoriteButtons=[NSMutableArray new];
    for(int i=0;i<3;i++){NSButton *b=button(@"",NSMakeRect(103+158*i,64,152,32),self,@selector(favoriteFromButton:));b.tag=i;
        [b setButtonType:NSButtonTypePushOnPushOff];[v addSubview:b];[self.favoriteButtons addObject:b];}
    self.favoritePopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(580,66,190,29) pullsDown:YES];
    self.favoritePopup.menu.delegate=self;[v addSubview:self.favoritePopup];
    [v addSubview:button(@"保存为常用方案",NSMakeRect(784,64,172,32),self,@selector(saveFavorite:))];
    [v addSubview:label(@"选择布局（点击立即生效）",NSMakeRect(25,111,330,20),13,YES)];
    self.freeButton=button(@"自由模式",NSMakeRect(24,137,128,52),self,@selector(freeMode:));
    [self.freeButton setButtonType:NSButtonTypePushOnPushOff];self.freeButton.bezelStyle=NSBezelStyleRegularSquare;
    self.freeButton.image=[NSImage imageWithSystemSymbolName:@"macwindow" accessibilityDescription:@"自由模式"];
    self.freeButton.imagePosition=NSImageAbove;self.freeButton.font=[NSFont systemFontOfSize:11];[v addSubview:self.freeButton];
    self.presetButtons=[NSMutableArray new];NSInteger index=0;
    for(NSDictionary *preset in quickPresets()) {
        NSInteger tile=index+1,row=tile/7,column=tile%7;
        NSButton *b=button(preset[@"name"],NSMakeRect(24+134*column,137+58*row,128,52),self,@selector(presetFromButton:));
        b.tag=index++;[b setButtonType:NSButtonTypePushOnPushOff];b.bezelStyle=NSBezelStyleRegularSquare;
        b.image=layoutIcon(preset);b.image.size=NSMakeSize(44,29);b.imagePosition=NSImageAbove;b.font=[NSFont systemFontOfSize:11];
        b.toolTip=[NSString stringWithFormat:@"%@；恢复这份布局自己的窗口位置，不覆盖常用方案。",preset[@"detail"]?:preset[@"name"]];
        [v addSubview:b];[self.presetButtons addObject:b];
    }
    self.preview=[[FSPreview alloc] initWithFrame:NSMakeRect(24,271,315,201)];
    self.preview.toolTip=@"点击分区操作该格最前面的窗口。每格可以叠放多个窗口。";
    __weak FSApp *weakSelf=self;self.preview.onSelectSlot=^(NSInteger slot){[weakSelf.coordinator focusSlot:slot];};[v addSubview:self.preview];
    [v addSubview:label(@"分区中的窗口（可选择下层窗口置前）",NSMakeRect(360,267,470,22),13,YES)];
    [v addSubview:button(@"更新列表",NSMakeRect(836,262,120,30),self,@selector(refreshWindows:))];
    self.stackLabels=[NSMutableArray new];self.stackPopups=[NSMutableArray new];self.pinButtons=[NSMutableArray new];
    for(int i=0;i<4;i++) {
        CGFloat y=302+40*i;NSTextField *l=label(@"",NSMakeRect(360,y+4,106,22),11,YES);[v addSubview:l];[self.stackLabels addObject:l];
        NSPopUpButton *p=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(468,y,356,30) pullsDown:YES];p.menu.delegate=self;p.tag=i;
        [v addSubview:p];[self.stackPopups addObject:p];
        NSButton *pin=[NSButton checkboxWithTitle:@"固定位置" target:self action:@selector(togglePin:)];pin.tag=i;pin.frame=NSMakeRect(839,y+3,117,24);
        pin.toolTip=@"位置固定在这个分区；手动拖动会更新位置。叠放不删除该窗口，不代表永久置顶。";
        [v addSubview:pin];[self.pinButtons addObject:pin];
    }
    [v addSubview:label(@"拖入有窗口的分区会叠放；关闭或最小化最前面的窗口，就显示下面的窗口。",NSMakeRect(25,486,929,20),12,NO)];
    self.statusLabel=label(@"",NSMakeRect(25,516,929,38),12,NO);self.statusLabel.maximumNumberOfLines=2;
    self.statusLabel.lineBreakMode=NSLineBreakByWordWrapping;[self.statusLabel.cell setUsesSingleLineMode:NO];[v addSubview:self.statusLabel];
    [v addSubview:button(@"启用当前方案",NSMakeRect(24,563,151,32),self,@selector(applyCurrent:))];
    [v addSubview:button(@"打开权限设置",NSMakeRect(184,563,151,32),self,@selector(openPermission:))];
    [v addSubview:button(@"权限与窗口诊断",NSMakeRect(344,563,166,32),self,@selector(showDiagnostics:))];
    self.managePopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(520,565,168,29) pullsDown:YES];
    [self.managePopup addItemWithTitle:@"管理当前方案"];self.managePopup.menu.delegate=self;
    [self.managePopup.menu addItem:[self item:@"另存为新方案…" action:@selector(saveFavorite:) value:nil]];
    [self.managePopup.menu addItem:[self item:@"重命名当前方案…" action:@selector(renameFavorite:) value:nil]];
    [self.managePopup.menu addItem:[self item:@"删除当前方案…" action:@selector(deleteFavorite:) value:nil]];[v addSubview:self.managePopup];
    [v addSubview:button(@"使用说明",NSMakeRect(699,563,110,32),self,@selector(showHelp:))];
    [v addSubview:button(@"更多设置 →",NSMakeRect(820,563,136,32),self,@selector(toggleMore:))];
    NSView *a=self.advancedView;
    [a addSubview:label(@"当前方案设置",NSMakeRect(25,20,420,32),24,YES)];
    [a addSubview:button(@"← 返回布局",NSMakeRect(790,22,166,34),self,@selector(toggleMore:))];
    [a addSubview:label(@"修改会自动保存到当前方案；其他常用方案和内置布局各自保留。",NSMakeRect(25,61,929,22),12,NO)];
    [a addSubview:label(@"目标显示器",NSMakeRect(25,112,145,24),13,YES)];
    self.screenPopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(172,106,784,30) pullsDown:NO];
    self.screenPopup.target=self;self.screenPopup.action=@selector(screenChanged:);self.screenPopup.menu.delegate=self;[a addSubview:self.screenPopup];
    [a addSubview:label(@"分区形状",NSMakeRect(25,159,145,24),13,YES)];
    self.layoutPopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(172,153,784,30) pullsDown:NO];[self.layoutPopup addItemsWithTitles:layoutNames()];
    self.layoutPopup.target=self;self.layoutPopup.action=@selector(layoutChanged:);[a addSubview:self.layoutPopup];
    self.ratioLabel=label(@"",NSMakeRect(25,214,438,23),12,YES);[a addSubview:self.ratioLabel];
    self.ratioSlider=[NSSlider sliderWithValue:50 minValue:20 maxValue:80 target:self action:@selector(ratioChanged:)];self.ratioSlider.frame=NSMakeRect(25,244,438,26);self.ratioSlider.continuous=NO;[a addSubview:self.ratioSlider];
    self.gapLabel=label(@"",NSMakeRect(515,214,438,23),12,YES);[a addSubview:self.gapLabel];
    self.gapSlider=[NSSlider sliderWithValue:8 minValue:0 maxValue:40 target:self action:@selector(gapChanged:)];self.gapSlider.frame=NSMakeRect(515,244,438,26);self.gapSlider.continuous=NO;[a addSubview:self.gapSlider];
    self.newWindowCheckbox=[NSButton checkboxWithTitle:@"新窗口叠放在当前操作的分区（关闭后：空格优先，再选窗口最少的分区）" target:self action:@selector(optionChanged:)];
    self.newWindowCheckbox.frame=NSMakeRect(25,301,929,26);[a addSubview:self.newWindowCheckbox];
    self.restoreMinCheckbox=[NSButton checkboxWithTitle:@"切换方案时恢复最小化窗口（默认关闭，最小化状态会保留）" target:self action:@selector(optionChanged:)];
    self.restoreMinCheckbox.frame=NSMakeRect(25,340,929,26);[a addSubview:self.restoreMinCheckbox];
    self.preventDragCheckbox=[NSButton checkboxWithTitle:@"禁止标题栏拖动（开启后关闭拖动分配，内容拖拽仍可用）" target:self action:@selector(optionChanged:)];
    self.preventDragCheckbox.frame=NSMakeRect(25,379,929,26);[a addSubview:self.preventDragCheckbox];
    self.permissionLabel=label(@"",NSMakeRect(25,428,929,40),12,NO);self.permissionLabel.maximumNumberOfLines=2;
    self.permissionLabel.lineBreakMode=NSLineBreakByWordWrapping;[self.permissionLabel.cell setUsesSingleLineMode:NO];[a addSubview:self.permissionLabel];
    [a addSubview:button(@"修复旧版授权",NSMakeRect(25,484,210,32),self,@selector(repairOldPermission:))];
    [a addSubview:button(@"在 Finder 显示程序",NSMakeRect(265,484,210,32),self,@selector(revealApp:))];
    [a addSubview:button(@"打开方案文件夹",NSMakeRect(505,484,210,32),self,@selector(openConfigFolder:))];
    [a addSubview:button(@"设置开机启动",NSMakeRect(745,484,210,32),self,@selector(openLoginSettings:))];
    [a addSubview:button(@"恢复分屏前位置并进入自由模式",NSMakeRect(25,548,460,34),self,@selector(restoreOriginal:))];
    [a addSubview:label([NSString stringWithFormat:@"v%@ · 构建 %@",FSVersion,[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]],NSMakeRect(620,556,334,22),12,NO)];
}
- (void)refreshControls {
    if(!self.settingsWindow || self.refreshing)return;self.refreshing=YES;
    NSMutableDictionary *p=self.profile;NSArray *favorites=self.favorites;BOOL enabled=self.coordinator.enabled;
    self.stateLabel.stringValue=[NSString stringWithFormat:@"%@ · %@",enabled?@"自动分屏":@"自由模式",p[@"name"]];
    self.freeButton.state=enabled?NSControlStateValueOff:NSControlStateValueOn;
    for(NSButton *b in self.presetButtons)b.state=enabled && p[@"preset"] && ![p[@"favorite"] boolValue] && [p[@"preset"] integerValue]==b.tag?NSControlStateValueOn:NSControlStateValueOff;
    for(NSButton *b in self.favoriteButtons){BOOL exists=(NSUInteger)b.tag<favorites.count;b.hidden=!exists;
        if(exists){NSString *name=favorites[b.tag][@"name"];b.title=name;b.toolTip=[@"点击恢复常用方案：" stringByAppendingString:name];
            b.state=enabled && [favorites[b.tag][@"id"] isEqual:p[@"id"]]?NSControlStateValueOn:NSControlStateValueOff;}}
    [self.favoritePopup removeAllItems];[self.favoritePopup addItemWithTitle:favorites.count?@"全部常用方案…":@"保存后显示在左侧"];
    for(NSDictionary *saved in favorites)[self.favoritePopup.menu addItem:[self item:saved[@"name"] action:@selector(profileFromMenu:) value:saved[@"id"]]];
    self.favoritePopup.enabled=favorites.count>0;
    NSArray *positions=positionNames([p[@"layout"] intValue]);NSMutableArray *names=[NSMutableArray new];
    NSArray *available=AXIsProcessTrusted()?[self.coordinator availableWindows]:@[];
    for(int slot=0;slot<4;slot++) {
        BOOL visible=slot<self.zoneCount;self.stackLabels[slot].hidden=!visible;self.stackPopups[slot].hidden=!visible;self.pinButtons[slot].hidden=!visible;
        if(!visible)continue;NSArray *stack=[self.coordinator windowsInSlot:slot];FSWindow *top=[self.coordinator topWindowInSlot:slot];
        [names addObject:top?[NSString stringWithFormat:@"%@ · %lu 窗口",top.appName,(unsigned long)stack.count]:@"空闲分区"];
        self.stackLabels[slot].stringValue=[NSString stringWithFormat:@"%d · %@",slot+1,positions[slot]];
        NSPopUpButton *popup=self.stackPopups[slot];[popup removeAllItems];
        [popup addItemWithTitle:top?[NSString stringWithFormat:@"%@（%lu 个窗口）",top.label,(unsigned long)stack.count]:(stack.count?@"窗口已最小化或隐藏":@"空分区 · 可拖入窗口")];
        for(FSWindow *w in stack.reverseObjectEnumerator) {
            NSString *suffix=[w isMinimized]?@" · 最小化":([w isHidden]?@" · 已隐藏":@"");
            [popup.menu addItem:[self item:[NSString stringWithFormat:@"置前：%@%@",w.label,suffix] action:@selector(focusWindowFromMenu:) value:w]];
        }
        NSMenu *other=[NSMenu new];other.delegate=self;
        for(FSWindow *w in available)if([self.coordinator slotForWindow:w]!=slot)
            [other addItem:[self item:w.label action:@selector(moveWindowFromMenu:) value:@{@"window":w,@"slot":@(slot)}]];
        if(other.numberOfItems){[popup.menu addItem:[NSMenuItem separatorItem]];NSMenuItem *move=[self item:@"移入其他窗口（叠放）" action:NULL value:nil];move.submenu=other;[popup.menu addItem:move];}
        self.pinButtons[slot].enabled=enabled && top!=nil;self.pinButtons[slot].state=[self.coordinator topWindowPinned:slot]?NSControlStateValueOn:NSControlStateValueOff;
    }
    self.preview.layout=[p[@"layout"] intValue];self.preview.ratio=[p[@"ratio"] doubleValue];self.preview.gap=[p[@"gap"] doubleValue];
    NSScreen *screen=FSScreenWithID(p[@"display"]);self.preview.aspect=screen?NSWidth(screen.visibleFrame)/NSHeight(screen.visibleFrame):16.0/9.0;
    self.preview.names=names;self.preview.freeMode=!enabled;self.preview.activeSlot=self.coordinator.activeSlot;self.preview.needsDisplay=YES;
    [self.screenPopup removeAllItems];
    for(NSScreen *s in NSScreen.screens){[self.screenPopup addItemWithTitle:s.localizedName];self.screenPopup.lastItem.representedObject=FSDisplayID(s);
        if([FSDisplayID(s) isEqual:p[@"display"]])[self.screenPopup selectItem:self.screenPopup.lastItem];}
    if(!screen){[self.screenPopup addItemWithTitle:@"已保存的显示器未连接"];self.screenPopup.lastItem.representedObject=p[@"display"];[self.screenPopup selectItem:self.screenPopup.lastItem];}
    [self.layoutPopup selectItemAtIndex:[p[@"layout"] integerValue]];self.ratioSlider.doubleValue=[p[@"ratio"] doubleValue]*100;
    self.gapSlider.doubleValue=[p[@"gap"] doubleValue];self.ratioLabel.stringValue=[NSString stringWithFormat:@"主分区比例：%.0f%%",self.ratioSlider.doubleValue];
    self.gapLabel.stringValue=[NSString stringWithFormat:@"分区间距：%.0f",self.gapSlider.doubleValue];
    self.newWindowCheckbox.state=[p[@"newWindowInActiveSlot"] boolValue]?NSControlStateValueOn:NSControlStateValueOff;
    self.restoreMinCheckbox.state=[p[@"restoreMinimized"] boolValue]?NSControlStateValueOn:NSControlStateValueOff;
    self.preventDragCheckbox.state=[p[@"preventDrag"] boolValue]?NSControlStateValueOn:NSControlStateValueOff;
    self.permissionLabel.stringValue=[NSString stringWithFormat:@"辅助功能：%@；当前程序：%@",AXIsProcessTrusted()?@"已授权":@"未授权",NSBundle.mainBundle.bundlePath];
    self.statusLabel.stringValue=self.statusText?:@"";self.statusItem.button.toolTip=[NSString stringWithFormat:@"定屏 · %@",p[@"name"]];self.refreshing=NO;
}
- (void)showSettings:(id)sender {
    if(!self.settingsWindow)[self buildUI];[self refreshControls];[NSApp activateIgnoringOtherApps:YES];[self.settingsWindow makeKeyAndOrderFront:nil];
    [NSUserDefaults.standardUserDefaults setObject:FSVersion forKey:@"lastShownVersion"];
}
- (void)toggleMore:(id)sender {self.moreExpanded=!self.moreExpanded;self.mainView.hidden=self.moreExpanded;self.advancedView.hidden=!self.moreExpanded;[self refreshControls];}
- (void)restoreOriginal:(id)sender {[self cancelInput];[self.coordinator restoreOriginalPositions];[self.guard stop];[self refreshControls];}
- (void)openPermission:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    [self message:@"在辅助功能中添加并开启当前 /Applications/定屏.app；返回后点击一个布局。 "];
}
- (void)repairOldPermission:(id)sender {
    if(AXIsProcessTrusted()){[self message:@"当前程序已授权。 "];return;}
    NSURL *tool=[NSBundle.mainBundle URLForResource:@"修复定屏授权" withExtension:@"command"];
    if(tool && [NSWorkspace.sharedWorkspace openURL:tool])[NSApp terminate:nil];else [self message:@"请使用 DMG「高级安装」中的授权修复工具。 "];
}
- (void)revealApp:(id)sender {[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[NSBundle.mainBundle.bundleURL]];}
- (void)openConfigFolder:(id)sender {
    NSURL *dir=self.store.url.URLByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];[NSWorkspace.sharedWorkspace openURL:dir];
}
- (void)openLoginSettings:(id)sender {[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]];}
- (void)showDiagnostics:(id)sender {
    __weak FSApp *weakSelf=self;[self performWhenIdle:^{FSApp *app=weakSelf;if(!app)return;
        NSString *diagnostic=[NSString stringWithFormat:@"版本：%@（构建 %@）\n辅助功能：%@\n当前模式：%@；鼠标监听：%@\n拖动诊断：%@\n应用标识：%@\n正在运行的应用：\n%@\n\n%@\n\n最近窗口检查：%@\n配置：%@",
            FSVersion,[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"],AXIsProcessTrusted()?@"已授权":@"未授权",
            app.coordinator.enabled?@"自动分屏":@"自由模式",app.monitor?@"正常":@"不可用",app.dragResult,
            NSBundle.mainBundle.bundleIdentifier,NSBundle.mainBundle.bundlePath,[app.coordinator diagnostic],
            AXIsProcessTrusted()?FSFocusedWindowDiagnostic(app.lastExternalPID):@"请授权当前安装路径",app.store.url.path];
        if([NSBundle.mainBundle.bundlePath containsString:@"/AppTranslocation/"])diagnostic=[diagnostic stringByAppendingString:@"\n当前为临时隔离副本，请通过 .pkg 安装到 /Applications 后启动。"];
        NSAlert *alert=[NSAlert new];alert.messageText=@"定屏 · 权限与窗口诊断";
        /* Keep the dialog bounded. The full text is available with one copy action. */
        alert.informativeText=[NSString stringWithFormat:@"v%@ · %@\n%@\n当前程序：%@\n\n点击「复制完整诊断」可复制所有分区坐标和最近事件。",FSVersion,
            AXIsProcessTrusted()?@"已授权":@"未授权",app.dragResult,NSBundle.mainBundle.bundlePath];
        [alert addButtonWithTitle:@"复制完整诊断"];[alert addButtonWithTitle:@"关闭"];[alert addButtonWithTitle:@"在 Finder 显示"];
        [NSApp activateIgnoringOtherApps:YES];NSModalResponse result=[alert runModal];
        if(result==NSAlertFirstButtonReturn){[NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard setString:diagnostic forType:NSPasteboardTypeString];[app message:@"完整诊断已复制。 "];}
        else if(result==NSAlertThirdButtonReturn)[app revealApp:nil];
    }];
}
- (void)showHelp:(id)sender {
    NSAlert *alert=[NSAlert new];alert.messageText=@"拖动定位置，点击只置前";
    alert.informativeText=@"点击布局：全部普通窗口进入分区；每格可叠放多窗。\n拖动标题栏到目标格：窗口移入并置前，原窗口留在下层，位置自动保存。\n点击或切换窗口：只在自己的分区置前。关闭、最小化后露出下面的窗口。\n常用方案：顶部点「保存为常用方案」，以后点名称一键恢复；各方案、各内置布局独立记忆。\n固定位置：固定分区归属，手动拖动仍可更新，不代表永久置顶。\n更多设置：新窗口落点、恢复最小化、禁止拖动、比例、间距。\n自由模式：停止归位，保存的方案仍保留。\n快捷键：⌃⌥⌘0 自由；1～6 常用布局；R 当前方案；Tab 下一常用方案；P 打开定屏。";
    [alert addButtonWithTitle:@"知道了"];[alert addButtonWithTitle:@"完整说明"];
    if([alert runModal]==NSAlertSecondButtonReturn){NSURL *url=[NSBundle.mainBundle URLForResource:@"使用说明" withExtension:@"md"];if(url)[NSWorkspace.sharedWorkspace openURL:url];}
}
- (void)registerHotKeys {
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    if(InstallEventHandler(GetApplicationEventTarget(),hotKeyCallback,1,&type,(__bridge void *)self,&_hotHandler)!=noErr)return;
    UInt32 codes[]={kVK_ANSI_0,kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4,kVK_ANSI_5,kVK_ANSI_6,kVK_ANSI_R,kVK_Tab,kVK_ANSI_P};
    for(int i=0;i<10;i++){EventHotKeyID key={'DFSP',(UInt32)i+1};RegisterEventHotKey(codes[i],controlKey|optionKey|cmdKey,key,GetApplicationEventTarget(),0,&_hotKeys[i]);}
}
- (void)handleHotKey:(UInt32)identifier {
    if(identifier==1)[self freeMode:nil];else if(identifier>=2 && identifier<=7)[self activatePreset:identifier-2];
    else if(identifier==8)[self applyCurrent:nil];else if(identifier==9)[self nextFavorite:nil];else if(identifier==10)[self showSettings:nil];
}
- (void)quit:(id)sender {[NSApp terminate:nil];}
@end
int main(int argc,const char *argv[]) {
    @autoreleasepool {NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        static FSApp *delegate;delegate=[FSApp new];app.delegate=delegate;[app run];}return 0;
}
