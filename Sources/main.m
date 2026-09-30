#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import "WindowAccess.h"
#import "DragGuard.h"
#import "FocusObserver.h"
#import "BindingStore.h"
#include "DragPolicy.h"
#include "PlacementPolicy.h"
#include "BindingPolicy.h"
#include <math.h>
#include <unistd.h>

static NSString *const FSVersion=@"0.7.0";
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
static NSMutableDictionary *FSWindowBinding(FSWindow *window) {
    NSMutableDictionary *binding=[@{@"bundle":window.bundleID,@"app":window.appName,
                                   @"title":window.title} mutableCopy];
    if(window.document.length)binding[@"document"]=window.document;
    return binding;
}
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
@property(nonatomic) unsigned pinnedMask;
@property(nonatomic) NSInteger sourceSlot;
@property(nonatomic) NSInteger targetSlot;
@property(nonatomic) BOOL sourcePinned;
@end
@implementation FSDragOverlayView
- (void)drawRect:(NSRect)dirtyRect {
    for(NSUInteger i=0;i<self.zoneRects.count;i++) {
        NSRect r=NSInsetRect(self.zoneRects[i].rectValue,5,5);
        if(r.size.width<=12 || r.size.height<=12)continue;
        BOOL targetPinned=(self.pinnedMask & (1u<<i))!=0;
        BOOL fixed=self.sourcePinned || targetPinned;
        BOOL selected=(NSInteger)i==self.targetSlot;
        NSColor *color=fixed?NSColor.systemOrangeColor:NSColor.systemTealColor;
        NSBezierPath *outline=[NSBezierPath bezierPathWithRoundedRect:r xRadius:12 yRadius:12];
        [[color colorWithAlphaComponent:selected ? .23 : .075] setFill];[outline fill];
        [[color colorWithAlphaComponent:selected ? .95 : .55] setStroke];
        outline.lineWidth=selected?4:2;[outline stroke];
        NSString *caption=targetPinned?[NSString stringWithFormat:@"%lu · 已固定",(unsigned long)i+1]:
            (self.sourcePinned?[NSString stringWithFormat:@"%lu · 来源已固定",(unsigned long)i+1]:
            (selected?[NSString stringWithFormat:@"松手放到区域 %lu",(unsigned long)i+1]:
             ((NSInteger)i==self.sourceSlot?[NSString stringWithFormat:@"当前区域 %lu",(unsigned long)i+1]:
              [NSString stringWithFormat:@"区域 %lu",(unsigned long)i+1])));
        NSRect badge=NSMakeRect(NSMinX(r)+12,NSMinY(r)+12,MIN(NSWidth(r)-24,168),30);
        if(badge.size.width<60)continue;
        [[color colorWithAlphaComponent:.93] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:badge xRadius:9 yRadius:9] fill];
        [caption drawInRect:NSInsetRect(badge,8,6) withAttributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName:NSColor.whiteColor}];
    }
}
@end

@interface FSRestore : NSObject
@property(nonatomic,strong) FSWindow *window;
@property(nonatomic) FSRect frame;
@end
@implementation FSRestore @end

@interface FSDragSnapshot : NSObject
@property(nonatomic,strong) FSWindow *window;
@property(nonatomic) FSRect frame;
@property(nonatomic) FSRect visibleFrame;
@property(nonatomic) FSRect movedFrame;
@property(nonatomic) BOOL movedDuringDrag;
@property(nonatomic) BOOL pointerEligible;
@property(nonatomic) BOOL plainChrome;
@end
@implementation FSDragSnapshot @end

@interface FSAssignment : NSObject
@property(nonatomic,strong) FSWindow *window;
@property(nonatomic) NSInteger slot;
@end
@implementation FSAssignment @end

@interface FSNewWindow : NSObject
@property(nonatomic,strong) id element;
@property(nonatomic) pid_t pid;
@property(nonatomic) NSInteger activeSlot;
@property(nonatomic) NSTimeInterval createdAt;
@property(nonatomic,copy) NSString *profileID;
@property(nonatomic,strong) FSWindow *parent;
@end
@implementation FSNewWindow @end

@interface FSApp : NSObject<NSApplicationDelegate,NSMenuDelegate,NSWindowDelegate> {
    EventHotKeyRef _hotKeys[15];
    EventHandlerRef _hotHandler;
    FSPlacementState _placement;
    FSPostDragState _postDrag;
}
@property(nonatomic,strong) NSStatusItem *statusItem;
@property(nonatomic,strong) NSWindow *settingsWindow;
@property(nonatomic,strong) NSMutableDictionary *config;
@property(nonatomic,strong) NSURL *configURL;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,FSWindow *> *runtime;
/* A fixed target and the temporary window occupying its empty slot are distinct. */
@property(nonatomic,strong) NSMutableIndexSet *borrowedSlots;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSNumber *> *failures;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSValue *> *targets;
@property(nonatomic,strong) NSMutableIndexSet *suspended;
@property(nonatomic,strong) NSMutableIndexSet *pending;
@property(nonatomic,strong) NSMutableArray<FSRestore *> *originals;
@property(nonatomic,strong) NSArray<FSWindow *> *windowChoices;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) id activity;
@property(nonatomic,strong) FSDragGuard *dragGuard;
@property(nonatomic,strong) FSFocusObserver *focusObserver;
@property(nonatomic,strong) id inputMonitor;
@property(nonatomic,strong) id localInputMonitor;
@property(nonatomic,strong) FSWindow *observedWindow;
@property(nonatomic,copy) NSArray<FSDragSnapshot *> *dragSnapshots;
@property(nonatomic,copy) NSArray<FSDragSnapshot *> *pendingDropSnapshots;
@property(nonatomic,copy) NSString *pendingDropProfileID;
@property(nonatomic) NSUInteger pendingDropEpoch;
@property(nonatomic) NSTimeInterval pendingDropReadyAt;
@property(nonatomic) CGPoint pendingDropPoint;
@property(nonatomic) CGPoint pendingDropStart;
@property(nonatomic,strong) NSPanel *dragOverlay;
@property(nonatomic,strong) FSDragOverlayView *dragOverlayView;
@property(nonatomic) BOOL dragMotionSeen;
@property(nonatomic) CGPoint dragStartPoint;
@property(nonatomic,copy) NSString *dragProfileID;
@property(nonatomic) NSUInteger dragGeneration;
@property(nonatomic) NSTimeInterval lastDragOverlayUpdate;
@property(nonatomic,copy) NSString *lastDragResult;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableArray<FSAssignment *> *> *histories;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary<NSNumber *,FSWindow *> *> *ownerCache;
@property(nonatomic,strong) NSMutableArray<FSNewWindow *> *createdWindowMarkers;
@property(nonatomic) NSUInteger focusGeneration;
@property(nonatomic) NSTimeInterval lastMaintenance;
@property(nonatomic,strong) NSButton *freeButton;
@property(nonatomic) BOOL locked;
@property(nonatomic) BOOL sleeping;
@property(nonatomic) BOOL sessionInactive;
@property(nonatomic) BOOL menuOpen;
@property(nonatomic) BOOL refreshing;
@property(nonatomic) BOOL saveBlocked;
@property(nonatomic) NSUInteger epoch;
@property(nonatomic) pid_t lastExternalPID;
@property(nonatomic) NSTimeInterval lastMouseDown;
@property(nonatomic) NSTimeInterval quietUntil;
@property(nonatomic) NSTimeInterval lastResolve;
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,copy) NSString *hotkeyWarning;
@property(nonatomic,strong) NSValue *lastUsable;
@property(nonatomic,strong) NSTextField *permissionLabel;
@property(nonatomic,strong) NSTextField *statusLabel;
@property(nonatomic,strong) NSTextField *ratioLabel;
@property(nonatomic,strong) NSTextField *gapLabel;
@property(nonatomic,strong) NSButton *permissionButton;
@property(nonatomic,strong) NSButton *lockButton;
@property(nonatomic,strong) NSButton *restoreButton;
@property(nonatomic,strong) NSPopUpButton *lockModePopup;
@property(nonatomic,strong) NSTextField *guardStatusLabel;
@property(nonatomic,strong) NSMutableArray<NSButton *> *presetButtons;
@property(nonatomic,strong) NSPopUpButton *profilePopup;
@property(nonatomic,strong) NSPopUpButton *screenPopup;
@property(nonatomic,strong) NSPopUpButton *layoutPopup;
@property(nonatomic,strong) NSSlider *ratioSlider;
@property(nonatomic,strong) NSSlider *gapSlider;
@property(nonatomic,strong) FSPreview *preview;
@property(nonatomic,strong) NSMutableArray<NSPopUpButton *> *bindingPopups;
@property(nonatomic,strong) NSMutableArray<NSTextField *> *bindingLabels;
@property(nonatomic,strong) NSMutableArray<NSButton *> *pickButtons;
@property(nonatomic,strong) NSMutableArray<NSButton *> *pinButtons;
@property(nonatomic,strong) NSTextField *guideTitle;
@property(nonatomic,strong) NSTextField *guideDetail;
@property(nonatomic,strong) NSTextField *stateLabel;
@property(nonatomic,strong) NSButton *guideButton;
@property(nonatomic,strong) NSButton *repairButton;
@property(nonatomic,strong) NSButton *fillButton;
@property(nonatomic,strong) NSButton *rotateButton;
@property(nonatomic,strong) NSButton *moreButton;
@property(nonatomic,strong) NSButton *launchCheckbox;
@property(nonatomic,strong) NSButton *createdWindowCheckbox;
@property(nonatomic,strong) FSFlippedView *documentView;
@property(nonatomic,strong) NSView *advancedView;
@property(nonatomic) BOOL moreExpanded;
@property(nonatomic) BOOL lastTrusted;
@property(nonatomic) BOOL permissionPromptShown;
@property(nonatomic) NSTimeInterval lastWindowRefresh;
@property(nonatomic) BOOL choosingWindow;
@property(nonatomic) NSInteger pickingSlot;
@property(nonatomic) NSUInteger pickingGeneration;
@property(nonatomic) NSTimeInterval pickingDeadline;
@property(nonatomic,strong) id pickMonitor;
- (void)handleHotKey:(UInt32)identifier;
- (BOOL)matchesPreset:(NSDictionary *)preset;
- (void)activatePreset:(NSInteger)index;
- (void)syncDragGuard:(BOOL)retry;
- (void)refreshDragTargets;
- (BOOL)requirePermission;
- (NSInteger)boundCount;
- (void)resolveBindings:(BOOL)force available:(NSArray<FSWindow *> *)available;
- (void)resolveBindings:(BOOL)force;
- (void)finishPicking;
- (void)fixLayout:(id)sender;
- (void)unlockLayout:(id)sender;
- (void)scheduleAutomaticPlacement;
- (void)captureActiveWindow;
- (void)activateCurrentLayout:(BOOL)seedEmpty;
- (void)finishActivation:(uint64_t)token attempt:(NSInteger)attempt;
- (void)foregroundLayout:(uint64_t)token;
- (void)seedEmptySlots;
- (void)cancelActivation;
- (void)rememberAssignment:(FSWindow *)window slot:(NSInteger)slot;
- (void)storeWindow:(FSWindow *)window slot:(NSInteger)slot;
- (void)storeWindow:(FSWindow *)window slot:(NSInteger)slot manual:(BOOL)manual;
- (void)beginWindowDrag:(NSEvent *)event;
- (void)updateDragOverlay:(NSEvent *)event;
- (void)finishWindowDrag:(NSEvent *)event;
- (void)commitWindowDrag:(NSArray<FSDragSnapshot *> *)snapshots at:(CGPoint)point
               startedAt:(CGPoint)startPoint profile:(NSString *)profileID;
- (void)clearWindowDrag;
- (void)completePendingDrop:(uint64_t)token;
- (void)noteCreatedWindow:(id)element pid:(pid_t)pid;
- (NSInteger)createdWindowActiveSlot:(FSWindow *)window;
- (BOOL)slotPinned:(NSInteger)slot;
- (void)togglePin:(NSButton *)sender;
- (void)pinFocusedSlot:(NSMenuItem *)sender;
- (void)unpinFromMenu:(NSMenuItem *)sender;
- (void)showTranslocatedWarning;
@end

static OSStatus hotKeyCallback(EventHandlerCallRef next, EventRef event, void *context) {
    EventHotKeyID identifier;
    OSStatus err=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(identifier),NULL,&identifier);
    if(err!=noErr || identifier.signature!='FSpl')return eventNotHandledErr;
    [(__bridge FSApp *)context handleHotKey:identifier.id]; return noErr;
}

@implementation FSApp

- (BOOL)locked {return _placement.enabled;}
- (void)setLocked:(BOOL)enabled {
    if(_placement.enabled!=enabled)FSPlacementSetEnabled(&_placement,enabled);
}

- (NSMutableDictionary *)newProfile:(NSString *)name {
    NSString *display=NSScreen.screens.count?FSDisplayID(NSScreen.mainScreen?:NSScreen.screens.firstObject):@"";
    return [@{@"id":NSUUID.UUID.UUIDString,@"name":name,@"display":display,@"layout":@0,
              @"ratio":@.5,@"gap":@8,@"preventDrag":@NO,@"newWindowInActiveSlot":@YES,
              @"bindings":[NSMutableArray arrayWithObjects:@{},@{},@{},@{},nil],
              @"pins":[NSMutableArray arrayWithObjects:@{},@{},@{},@{},nil]} mutableCopy];
}
- (NSMutableDictionary *)profile {
    for(NSMutableDictionary *p in self.config[@"profiles"])if([p[@"id"] isEqual:self.config[@"active"]])return p;
    return [self.config[@"profiles"] firstObject];
}
- (int)zoneCount {
    FSRect z[4]; return FSBuildZones([self.profile[@"layout"] intValue],(FSRect){0,0,1000,700},.5,8,z);
}
- (void)loadConfig {
    NSURL *directory=[[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"定屏" isDirectory:YES];
    self.configURL=[directory URLByAppendingPathComponent:@"layouts.json"];
    NSData *data=[NSData dataWithContentsOfURL:self.configURL];
    id loaded=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;
    BOOL valid=[loaded isKindOfClass:NSDictionary.class] &&
               ([loaded[@"version"] isEqual:@1] || [loaded[@"version"] isEqual:@2] || [loaded[@"version"] isEqual:@3]) &&
               [loaded[@"profiles"] isKindOfClass:NSArray.class] && [loaded[@"profiles"] count]>0;
    NSMutableArray *profiles=[NSMutableArray new];
    if(valid) for(id candidate in loaded[@"profiles"]) {
        if(![candidate isKindOfClass:NSDictionary.class] || ![candidate[@"id"] isKindOfClass:NSString.class] ||
           ![candidate[@"name"] isKindOfClass:NSString.class] || ![candidate[@"display"] isKindOfClass:NSString.class] ||
           ![candidate[@"layout"] isKindOfClass:NSNumber.class] || ![candidate[@"ratio"] isKindOfClass:NSNumber.class] ||
           ![candidate[@"gap"] isKindOfClass:NSNumber.class] || ![candidate[@"bindings"] isKindOfClass:NSArray.class] ||
           ([loaded[@"version"] isEqual:@3] && (![candidate[@"pins"] isKindOfClass:NSArray.class] ||
              [candidate[@"pins"] count]!=4))) {valid=NO;break;}
        int layout=[candidate[@"layout"] intValue];
        if(layout<0 || layout>=FSLayoutCount) {valid=NO;break;}
        NSMutableDictionary *p=[candidate mutableCopy];
        p[@"preventDrag"]=@([p[@"preventDrag"] isEqual:@YES]);
        p[@"newWindowInActiveSlot"]=[candidate[@"newWindowInActiveSlot"] isKindOfClass:NSNumber.class]?
            @([candidate[@"newWindowInActiveSlot"] boolValue]):@YES;
        p[@"ratio"]=@(fmin(.8,fmax(.2,[p[@"ratio"] doubleValue])));
        p[@"gap"]=@(fmin(40,fmax(0,[p[@"gap"] doubleValue])));
        FSProfileNormalize(p,![loaded[@"version"] isEqual:@3]);[profiles addObject:p];
    }
    if(valid) {
        NSString *active=[loaded[@"active"] isKindOfClass:NSString.class]?loaded[@"active"]:profiles.firstObject[@"id"];
        BOOL automatic=[loaded[@"version"] isEqual:@1]?[loaded[@"locked"] isEqual:@YES]:[loaded[@"mode"] isEqual:@"auto"];
        self.config=[@{@"version":@3,@"active":active,@"profiles":profiles,@"mode":automatic?@"auto":@"free"} mutableCopy];
        if([loaded[@"version"] isEqual:@1]) {
            NSURL *backup=[directory URLByAppendingPathComponent:@"layouts-before-0.4.0.json"];
            if(![[NSFileManager defaultManager] fileExistsAtPath:backup.path] && ![data writeToURL:backup atomically:YES]) {
                self.saveBlocked=YES;self.statusText=@"旧配置备份失败：本次修改暂不保存，原配置仍保留。";
            }
        }
        if(data && ![loaded[@"version"] isEqual:@3]) {
            NSURL *backup=[directory URLByAppendingPathComponent:@"layouts-before-0.7.0.json"];
            if(![[NSFileManager defaultManager] fileExistsAtPath:backup.path] && ![data writeToURL:backup atomically:YES]) {
                self.saveBlocked=YES;self.statusText=@"固定目标迁移备份失败：本次修改暂不保存，原配置仍保留。";
            }
        }
    } else {
        NSMutableDictionary *p=[self newProfile:@"默认方案"];
        self.config=[@{@"version":@3,@"active":p[@"id"],@"profiles":[NSMutableArray arrayWithObject:p],@"mode":@"free"} mutableCopy];
        if(data) {
            self.saveBlocked=YES;
            self.statusText=@"配置文件格式异常：原文件已保留，本次修改暂不保存。请从菜单打开配置文件夹，移走 layouts.json 后重启。";
        }
    }
    self.config[@"active"]=self.profile[@"id"];
    self.locked=[self.config[@"mode"] isEqual:@"auto"];
}
- (void)saveConfig {
    if(self.saveBlocked)return;
    self.config[@"mode"]=self.locked?@"auto":@"free";
    NSError *error=nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:self.configURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
    NSData *data=error?nil:[NSJSONSerialization dataWithJSONObject:self.config options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
    BOOL ok=data && [data writeToURL:self.configURL options:NSDataWritingAtomic error:&error];
    if(!ok)[self setMessage:[NSString stringWithFormat:@"保存失败：%@。本次调整仍可使用。",error.localizedDescription?:@"无法写入配置"]];
}
- (void)setMessage:(NSString *)message {
    self.statusText=message; self.statusLabel.stringValue=message?:@"";
}
- (void)resetTracking:(BOOL)clearWindows {
    [self finishPicking];
    [self clearWindowDrag];
    [self.createdWindowMarkers removeAllObjects];
    self.epoch++; [self.failures removeAllObjects]; [self.targets removeAllObjects];
    [self.suspended removeAllIndexes]; [self.pending removeAllIndexes];
    if(clearWindows){[self.runtime removeAllObjects];[self.borrowedSlots removeAllIndexes];}
    self.lastResolve=0; self.lastUsable=nil;
    self.dragGuard.targets=@[];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.runtime=[NSMutableDictionary new];self.borrowedSlots=[NSMutableIndexSet new];
    self.failures=[NSMutableDictionary new];
    self.targets=[NSMutableDictionary new]; self.suspended=[NSMutableIndexSet new];
    self.pending=[NSMutableIndexSet new]; self.originals=[NSMutableArray new];
    self.histories=[NSMutableDictionary new];self.ownerCache=[NSMutableDictionary new];
    self.createdWindowMarkers=[NSMutableArray new];
    self.focusObserver=[FSFocusObserver new];
    self.dragGuard=[FSDragGuard new];
    __weak FSApp *weakSelf=self;
    self.dragGuard.mayIntercept=^BOOL{
        FSApp *app=weakSelf;
        return app && app.locked && !app->_placement.switching && [app.profile[@"preventDrag"] boolValue] &&
               !app.sleeping && !app.sessionInactive && !app.menuOpen && !app.choosingWindow && !NSApp.modalWindow &&
               NSDate.timeIntervalSinceReferenceDate>=app.quietUntil && AXIsProcessTrusted();
    };
    self.dragGuard.onFailure=^(NSString *message){[weakSelf setMessage:message];[weakSelf updateStatus];};
    self.focusObserver.onChange=^{[weakSelf scheduleAutomaticPlacement];};
    self.focusObserver.onCreated=^(id element,pid_t pid){[weakSelf noteCreatedWindow:element pid:pid];};
    self.inputMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp|NSEventMaskRightMouseDown|NSEventMaskKeyDown handler:^(NSEvent *event){
        FSApp *app=weakSelf;
        if(!app)return;
        if(event.type==NSEventTypeLeftMouseDragged) {
            if(app.dragSnapshots.count){app.dragMotionSeen=YES;[app updateDragOverlay:event];}
            return;
        }
        if(event.type==NSEventTypeLeftMouseUp) {[app finishWindowDrag:event];return;}
        /* Our own global shortcuts already cancel or replace the transaction. */
        if(event.type==NSEventTypeKeyDown && (event.modifierFlags & NSEventModifierFlagControl) &&
           (event.modifierFlags & NSEventModifierFlagOption)) {
            unsigned short code=event.keyCode;
            if(code==kVK_ANSI_0 || code==kVK_ANSI_1 || code==kVK_ANSI_2 || code==kVK_ANSI_3 ||
               code==kVK_ANSI_4 || code==kVK_ANSI_5 || code==kVK_ANSI_6 || code==kVK_ANSI_R ||
               code==kVK_ANSI_P || code==kVK_Tab || code==kVK_ANSI_L)return;
        }
        if(app && app->_placement.switching) {
            [app cancelActivation];app.quietUntil=NSDate.timeIntervalSinceReferenceDate+.3;
            [app setMessage:@"已停止窗口前置，继续你的操作；当前布局仍然生效。"];
        }
        if(event.type==NSEventTypeLeftMouseDown)[app beginWindowDrag:event];
    }];
    self.lastDragResult=self.inputMonitor?@"尚未尝试拖动":@"系统未提供全局鼠标事件监听";
    self.localInputMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown|NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event){
        FSApp *app=weakSelf;
        if(app && app->_placement.switching)[app cancelActivation];
        return event;
    }];
    self.statusText=@"点击布局立即自动分屏；点击「自由模式」恢复自由摆放。";
    [self loadConfig];
    self.statusItem=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image=[NSImage imageWithSystemSymbolName:@"rectangle.split.2x1" accessibilityDescription:@"定屏"];
    self.statusItem.button.image.template=YES;
    if(!self.statusItem.button.image)self.statusItem.button.title=@"定屏";
    NSMenu *menu=[NSMenu new];menu.delegate=self;self.statusItem.menu=menu;
    self.lastExternalPID=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSNotificationCenter *nc=NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self selector:@selector(appActivated:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [nc addObserver:self selector:@selector(spaceChanged:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [nc addObserver:self selector:@selector(sessionResigned:) name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(sessionBecameActive:) name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [self registerHotKeys];
    self.quietUntil=NSDate.timeIntervalSinceReferenceDate+2;
    self.timer=[NSTimer timerWithTimeInterval:.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    self.timer.tolerance=.08;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    self.lastTrusted=AXIsProcessTrusted();
    BOOL newVersion=![[NSUserDefaults.standardUserDefaults stringForKey:@"lastShownVersion"] isEqual:FSVersion];
    if(newVersion || (!self.lastTrusted && self.locked) || self.saveBlocked ||
       [NSUserDefaults.standardUserDefaults boolForKey:@"showSettingsOnLaunch"])[self showSettings:nil];
    [self syncDragGuard:YES];
    [self updateStatus];
    if([NSBundle.mainBundle.bundlePath containsString:@"/AppTranslocation/"])
        dispatch_async(dispatch_get_main_queue(),^{[self showTranslocatedWarning];});
}
- (void)showTranslocatedWarning {
    NSAlert *alert=[NSAlert new];
    alert.messageText=@"请先安装定屏，再从「应用程序」启动";
    alert.informativeText=@"当前打开的是 macOS 隔离的临时副本。请退出定屏，双击下载的 .pkg 安装包；若下载的是 DMG，先打开它，再双击里面的「双击安装定屏.pkg」。完成后从 /Applications/定屏.app 启动。";
    [alert addButtonWithTitle:@"退出并安装"];[alert addButtonWithTitle:@"暂时继续"];
    [NSApp activateIgnoringOtherApps:YES];
    if([alert runModal]==NSAlertFirstButtonReturn)[NSApp terminate:nil];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self showSettings:nil];return YES;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    FSPostDragCancel(&_postDrag);self.pendingDropSnapshots=nil;
    [self cancelActivation];[self.focusObserver stop];
    if(self.inputMonitor)[NSEvent removeMonitor:self.inputMonitor];
    if(self.localInputMonitor)[NSEvent removeMonitor:self.localInputMonitor];
    [self finishPicking];
    [self saveConfig]; [self.timer invalidate];
    [self.dragGuard stop];
    if(self.activity)[NSProcessInfo.processInfo endActivity:self.activity];
    for(int i=0;i<15;i++)if(_hotKeys[i])UnregisterEventHotKey(_hotKeys[i]);
    if(_hotHandler)RemoveEventHandler(_hotHandler);
}
- (void)appActivated:(NSNotification *)note {
    NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];
    if(app.processIdentifier!=getpid())self.lastExternalPID=app.processIdentifier;
    if(self.locked && app.processIdentifier!=getpid() && app.activationPolicy==NSApplicationActivationPolicyRegular)
        [self.focusObserver watchPID:app.processIdentifier];
    else [self.focusObserver stop];
    [self scheduleAutomaticPlacement];
}
- (void)spaceChanged:(NSNotification *)note { FSPostDragCancel(&_postDrag);self.pendingDropSnapshots=nil;[self cancelActivation];[self finishPicking];self.quietUntil=NSDate.timeIntervalSinceReferenceDate+1.8; }
- (void)willSleep:(NSNotification *)note { FSPostDragCancel(&_postDrag);self.pendingDropSnapshots=nil;[self cancelActivation];[self finishPicking];self.sleeping=YES; }
- (void)didWake:(NSNotification *)note { self.sleeping=NO;self.quietUntil=NSDate.timeIntervalSinceReferenceDate+3;[self resetTracking:NO]; }
- (void)sessionResigned:(NSNotification *)note {FSPostDragCancel(&_postDrag);self.pendingDropSnapshots=nil;[self cancelActivation];[self finishPicking];self.sessionInactive=YES;}
- (void)sessionBecameActive:(NSNotification *)note {self.sessionInactive=NO;self.quietUntil=NSDate.timeIntervalSinceReferenceDate+2;}
- (void)screensChanged:(NSNotification *)note {
    FSPostDragCancel(&_postDrag);self.pendingDropSnapshots=nil;
    [self cancelActivation];
    self.quietUntil=NSDate.timeIntervalSinceReferenceDate+2; [self resetTracking:NO];
    [self refreshControls];
}

- (void)cancelActivation {
    FSPlacementCancelSwitch(&_placement);
    self.focusGeneration++;self.observedWindow=nil;
    [self clearWindowDrag];
    self.dragGuard.targets=@[];
}
- (void)rememberAssignment:(FSWindow *)window slot:(NSInteger)slot {
    if(!window)return;
    NSString *identifier=self.profile[@"id"];
    NSMutableArray<FSAssignment *> *history=self.histories[identifier];
    if(!history){history=[NSMutableArray new];self.histories[identifier]=history;}
    for(FSAssignment *entry in [history copy]) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:entry.window.pid];
        if(!app || app.terminated || [entry.window sameWindow:window])[history removeObject:entry];
    }
    FSAssignment *entry=[FSAssignment new];entry.window=window;entry.slot=slot;[history addObject:entry];
    if(history.count>96)[history removeObjectAtIndex:0];
}
- (BOOL)slotPinned:(NSInteger)slot {
    return [FSProfilePin(self.profile,slot)[@"bundle"] length]>0;
}
- (void)storeWindow:(FSWindow *)window slot:(NSInteger)slot {
    [self storeWindow:window slot:slot manual:NO];
}
- (void)storeWindow:(FSWindow *)window slot:(NSInteger)slot manual:(BOOL)manual {
    if(slot<0 || slot>=4)return;
    FSWindow *previous=self.runtime[@(slot)];
    if(previous)[self rememberAssignment:previous slot:slot];
    if(window) {
        for(int i=0;i<4;i++)if(i!=slot && [window sameWindow:self.runtime[@(i)]]) {
            FSProfileSetOccupant(self.profile,i,@{});
            [self.runtime removeObjectForKey:@(i)];[self.borrowedSlots removeIndex:i];
        }
        BOOL owned=[self slotPinned:slot] && previous && [window sameWindow:previous] &&
                   ![self.borrowedSlots containsIndex:slot];
        FSProfileSetOccupant(self.profile,slot,FSWindowBinding(window));
        if(![self slotPinned:slot] || manual || owned)
            [self.borrowedSlots removeIndex:slot];
        else [self.borrowedSlots addIndex:slot];
        self.runtime[@(slot)]=window;[self rememberAssignment:window slot:slot];
    } else {FSProfileSetOccupant(self.profile,slot,@{});[self.runtime removeObjectForKey:@(slot)];
            [self.borrowedSlots removeIndex:slot];}
}
- (void)noteCreatedWindow:(id)element pid:(pid_t)pid {
    if(!self.locked || _placement.switching || ![self.profile[@"newWindowInActiveSlot"] boolValue] ||
       self.sleeping || self.sessionInactive || !element || !self.observedWindow ||
       self.observedWindow.pid!=pid)return;
    NSInteger active=-1;
    for(int i=0;i<self.zoneCount;i++)if([self.observedWindow sameWindow:self.runtime[@(i)]]){active=i;break;}
    if(active<0)return;
    FSNewWindow *created=[FSNewWindow new];created.element=element;created.pid=pid;
    created.activeSlot=active;created.parent=self.observedWindow;
    created.createdAt=NSDate.timeIntervalSinceReferenceDate;created.profileID=self.profile[@"id"];
    [self.createdWindowMarkers addObject:created];
    if(self.createdWindowMarkers.count>24)[self.createdWindowMarkers removeObjectAtIndex:0];
}
- (NSInteger)createdWindowActiveSlot:(FSWindow *)window {
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    NSInteger slot=-1;
    for(FSNewWindow *entry in [self.createdWindowMarkers copy]) {
        if(now-entry.createdAt>8 || ![entry.profileID isEqual:self.profile[@"id"]]) {
            [self.createdWindowMarkers removeObject:entry];continue;
        }
        if(window.pid!=entry.pid || !CFEqual((__bridge CFTypeRef)window.element,(__bridge CFTypeRef)entry.element))continue;
        if(entry.activeSlot<self.zoneCount && [entry.parent sameWindow:self.runtime[@(entry.activeSlot)]])slot=entry.activeSlot;
        [self.createdWindowMarkers removeObject:entry];break;
    }
    return slot;
}
- (void)clearWindowDrag {
    [self.dragOverlay orderOut:nil];
    self.dragSnapshots=nil;self.dragProfileID=nil;self.dragMotionSeen=NO;
    self.dragStartPoint=CGPointZero;
    self.lastDragOverlayUpdate=0;
    self.dragGeneration++;
}
- (void)beginWindowDrag:(NSEvent *)event {
    [self clearWindowDrag];
    self.lastMouseDown=NSDate.timeIntervalSinceReferenceDate;
    if(!self.locked || [self.profile[@"preventDrag"] boolValue])return;
    if(_placement.switching || self.choosingWindow || self.menuOpen || self.sleeping ||
       self.sessionInactive || NSApp.modalWindow || !FSScreenWithID(self.profile[@"display"])) {
        self.lastDragResult=@"当前正在切换布局、打开菜单或目标屏幕不可用，未开始拖动识别";
        return;
    }
    if(!AXIsProcessTrusted()){self.lastDragResult=@"辅助功能未授权";return;}
    CGPoint point=mouseAXPoint(event);
    self.dragStartPoint=point;
    BOOL plainChrome=NO;FSRect visibleFrame={0},frame={0};NSString *reason=nil;
    FSWindow *hit=FSWindowAtPointWithChrome(point,&visibleFrame,&plainChrome,&reason);
    if(!hit){self.lastDragResult=reason;return;}
    if(!FSPassiveDragCandidate(visibleFrame,point.x,point.y)) {
        self.lastDragResult=@"已识别窗口；起点位于内容区或边框，请抓住顶部空白处";
        return;
    }
    if(![hit readFrame:&frame]) {
        self.lastDragResult=@"已匹配窗口，但无法读取辅助功能坐标";
        return;
    }
    FSDragSnapshot *snapshot=[FSDragSnapshot new];snapshot.window=hit;snapshot.frame=frame;
    snapshot.visibleFrame=visibleFrame;
    snapshot.pointerEligible=FSVisibleFrameMatch(frame,visibleFrame);
    snapshot.plainChrome=plainChrome;
    self.dragSnapshots=@[snapshot];self.dragProfileID=self.profile[@"id"];
    self.lastDragResult=@"已识别鼠标下的窗口，等待拖动";
}
- (void)updateDragOverlay:(NSEvent *)event {
    if(!self.locked || [self.profile[@"preventDrag"] boolValue] || !self.dragSnapshots.count ||
       ![self.dragProfileID isEqual:self.profile[@"id"]] || self.menuOpen || self.sleeping || self.sessionInactive)return;
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    if(now-self.lastDragOverlayUpdate<.08)return;
    self.lastDragOverlayUpdate=now;
    FSWindow *moving=nil;FSRect actual={0};
    for(FSDragSnapshot *snapshot in self.dragSnapshots) {
        FSRect frame;
        if([snapshot.window readFrame:&frame] &&
           (FSWindowWasDragged(snapshot.frame,frame) ||
            FSWindowTitleMovedFromVisible(snapshot.frame,frame,snapshot.visibleFrame,
                                          self.dragStartPoint.x,self.dragStartPoint.y))) {
            snapshot.movedDuringDrag=YES;snapshot.movedFrame=frame;
            moving=snapshot.window;actual=frame;break;
        }
    }
    if(!moving)for(FSDragSnapshot *snapshot in self.dragSnapshots)if(snapshot.movedDuringDrag) {
        moving=snapshot.window;actual=snapshot.movedFrame;break;
    }
    CGPoint point=mouseAXPoint(event);
    /* The AX frame can lag a real title-bar gesture. A managed source can
       still show the destination once the pointer has travelled far enough. */
    if(!moving)for(FSDragSnapshot *snapshot in self.dragSnapshots) {
        BOOL managed=NO;
        for(int i=0;i<self.zoneCount;i++)if([snapshot.window sameWindow:self.runtime[@(i)]]){managed=YES;break;}
        if(managed && snapshot.pointerEligible &&
           FSPointerDragIntent(snapshot.visibleFrame,0,snapshot.plainChrome,
                                          self.dragStartPoint.x,self.dragStartPoint.y,
                                          point.x,point.y)) {
            moving=snapshot.window;actual=snapshot.frame;
            actual.x+=point.x-self.dragStartPoint.x;
            actual.y+=point.y-self.dragStartPoint.y;
            break;
        }
    }
    if(!moving){[self.dragOverlay orderOut:nil];return;}
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);if(!screen)return;
    FSRect usable=FSUsableFrame(screen),zones[4];
    int count=FSBuildZones([self.profile[@"layout"] intValue],usable,
                           [self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones);
    int source=-1;unsigned pinned=0;BOOL sourcePinned=NO;
    for(int i=0;i<count;i++) {
        if([self slotPinned:i] && ![self.borrowedSlots containsIndex:i] && self.runtime[@(i)])pinned|=1u<<i;
        if([moving sameWindow:self.runtime[@(i)]])source=i;
    }
    if(source>=0)sourcePinned=(pinned & (1u<<source))!=0;
    for(int i=count;i<4 && !sourcePinned;i++)if([self slotPinned:i]) {
        FSWindow *hidden=self.runtime[@(i)];NSDictionary *binding=FSProfilePin(self.profile,i);
        sourcePinned=(hidden && [moving sameWindow:hidden]) ||
            (!hidden && [moving.bundleID isEqual:binding[@"bundle"]] && [moving.title isEqual:binding[@"title"]]);
    }
    int target=FSDropDestination(zones,count,source,point.x,point.y,actual);
    NSRect frame=screen.visibleFrame;
    if(!self.dragOverlay) {
        self.dragOverlay=[[NSPanel alloc] initWithContentRect:frame
            styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        self.dragOverlay.opaque=NO;self.dragOverlay.backgroundColor=NSColor.clearColor;
        self.dragOverlay.hasShadow=NO;self.dragOverlay.ignoresMouseEvents=YES;
        self.dragOverlay.hidesOnDeactivate=NO;self.dragOverlay.level=NSFloatingWindowLevel;
        self.dragOverlay.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorTransient;
        self.dragOverlayView=[[FSDragOverlayView alloc] initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];
        self.dragOverlay.contentView=self.dragOverlayView;
    }
    [self.dragOverlay setFrame:frame display:NO];
    self.dragOverlayView.frame=NSMakeRect(0,0,frame.size.width,frame.size.height);
    NSMutableArray<NSValue *> *rects=[NSMutableArray new];
    for(int i=0;i<count;i++) {
        FSRect zone=zones[i];
        [rects addObject:[NSValue valueWithRect:NSMakeRect(zone.x-usable.x,zone.y-usable.y,zone.width,zone.height)]];
    }
    self.dragOverlayView.zoneRects=rects;
    self.dragOverlayView.pinnedMask=pinned;self.dragOverlayView.sourceSlot=source;
    self.dragOverlayView.sourcePinned=sourcePinned;self.dragOverlayView.targetSlot=target==source?-1:target;
    self.dragOverlayView.needsDisplay=YES;
    if(!self.dragOverlay.visible)[self.dragOverlay orderFrontRegardless];
}
- (void)finishWindowDrag:(NSEvent *)event {
    NSArray<FSDragSnapshot *> *snapshots=self.dragSnapshots;
    BOOL moved=self.dragMotionSeen;
    NSString *profileID=self.dragProfileID;
    CGPoint startPoint=self.dragStartPoint;
    [self clearWindowDrag];
    if(!snapshots.count || !moved || !self.locked || _placement.switching ||
       [self.profile[@"preventDrag"] boolValue] || ![profileID isEqual:self.profile[@"id"]] ||
       self.choosingWindow || self.menuOpen || self.sleeping || self.sessionInactive ||
       NSApp.modalWindow || !AXIsProcessTrusted())return;
    CGPoint point=mouseAXPoint(event);
    self.lastMouseDown=NSDate.timeIntervalSinceReferenceDate;
    self.quietUntil=self.lastMouseDown+.8;
    if(_postDrag.pending)[self completePendingDrop:_postDrag.token];
    self.pendingDropSnapshots=snapshots;self.pendingDropProfileID=profileID;
    self.pendingDropStart=startPoint;self.pendingDropPoint=point;
    self.pendingDropEpoch=self.epoch;
    self.pendingDropReadyAt=NSDate.timeIntervalSinceReferenceDate+.12;
    self.lastDragResult=@"已收到拖动，等待目标窗口完成移动";
    uint64_t token=FSPostDragArm(&_postDrag);
    __weak FSApp *weakSelf=self;
    /* A global event monitor runs asynchronously. Let the target app complete
       the move before reading its accessibility frame and reassigning zones. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.12*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        FSApp *app=weakSelf;
        [weakSelf completePendingDrop:token];
    });
}
- (void)completePendingDrop:(uint64_t)token {
    if(!FSPostDragTake(&_postDrag,token))return;
    NSArray *snapshots=self.pendingDropSnapshots;
    NSString *profileID=self.pendingDropProfileID;
    CGPoint point=self.pendingDropPoint,start=self.pendingDropStart;
    NSUInteger epoch=self.pendingDropEpoch;
    self.pendingDropSnapshots=nil;self.pendingDropProfileID=nil;
    if(epoch!=self.epoch) {
        self.lastDragResult=@"布局在松手后已改变，本次拖放未换位";
        return;
    }
    [self commitWindowDrag:snapshots at:point startedAt:start profile:profileID];
}
- (void)commitWindowDrag:(NSArray<FSDragSnapshot *> *)snapshots at:(CGPoint)point
               startedAt:(CGPoint)startPoint profile:(NSString *)profileID {
    if(!self.locked || _placement.switching || [self.profile[@"preventDrag"] boolValue] ||
       ![profileID isEqual:self.profile[@"id"]] || self.choosingWindow ||
       self.sleeping || self.sessionInactive || !AXIsProcessTrusted()) {
        self.lastDragResult=@"松手后模式、布局或桌面改变，本次未换位";
        return;
    }
    FSWindow *window=nil;FSRect start={0},actual={0};BOOL pointerOnly=NO;
    for(FSDragSnapshot *snapshot in snapshots) {
        FSRect movedFrame;
        if([snapshot.window isUsable] && [snapshot.window readFrame:&movedFrame] &&
           (FSWindowWasDragged(snapshot.frame,movedFrame) ||
            FSWindowTitleMovedFromVisible(snapshot.frame,movedFrame,snapshot.visibleFrame,
                                          startPoint.x,startPoint.y))) {
            window=snapshot.window;start=snapshot.frame;actual=movedFrame;break;
        }
    }
    if(!window)for(FSDragSnapshot *snapshot in snapshots)if(snapshot.movedDuringDrag &&
       [snapshot.window isUsable]) {
        FSRect current;
        if([snapshot.window readFrame:&current]) {
            window=snapshot.window;start=snapshot.frame;actual=snapshot.movedFrame;break;
        }
    }
    if(!window)for(FSDragSnapshot *snapshot in snapshots) {
        NSInteger source=-1;
        for(int i=0;i<self.zoneCount;i++)if([snapshot.window sameWindow:self.runtime[@(i)]]){source=i;break;}
        if(!snapshot.pointerEligible ||
           !FSPointerDragIntent(snapshot.visibleFrame,(int)source,snapshot.plainChrome,
                                startPoint.x,startPoint.y,point.x,point.y) ||
           ![snapshot.window isUsable])continue;
        FSRect current;if(![snapshot.window readFrame:&current])continue;
        window=snapshot.window;start=snapshot.frame;actual=snapshot.frame;
        actual.x+=point.x-startPoint.x;actual.y+=point.y-startPoint.y;
        pointerOnly=YES;break;
    }
    if(!window){self.lastDragResult=@"未确认标题栏拖放：窗口未移动，或起点不在标题栏";return;}
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);if(!screen)return;
    FSRect zones[4];int count=FSBuildZones([self.profile[@"layout"] intValue],FSUsableFrame(screen),
                                          [self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones);
    int source=-1;unsigned pinned=0;
    for(int i=0;i<count;i++) {
        if([self slotPinned:i] && ![self.borrowedSlots containsIndex:i] && self.runtime[@(i)])pinned|=1u<<i;
        if([window sameWindow:self.runtime[@(i)]])source=i;
    }
    int destination=FSDropDestination(zones,count,source,point.x,point.y,actual);
    if(destination<0){self.lastDragResult=@"松手位置在分区外，原分区保持不变";return;}
    /* A pin in a temporarily hidden zone still owns its exact window. */
    for(int i=count;i<4;i++)if([self slotPinned:i]) {
        FSWindow *hidden=self.runtime[@(i)];NSDictionary *binding=FSProfilePin(self.profile,i);
        if((hidden && [window sameWindow:hidden]) ||
           (!hidden && [window.bundleID isEqual:binding[@"bundle"]] && [window.title isEqual:binding[@"title"]])) {
            self.lastDragResult=@"窗口固定在当前布局未显示的分区，未换位";
            [window moveTo:start error:nil];
            [self setMessage:@"这个窗口固定在当前布局暂未显示的分区；先取消固定再拖动换位。"];
            return;
        }
    }
    FSWindow *occupant=self.runtime[@(destination)];
    FSDropAction action=FSDropChooseAction(count,source,destination,pinned,occupant!=nil);
    if(action==FSDropIgnore){self.lastDragResult=@"窗口仍在原分区；把窗口拖到目标分区再松手";return;}
    if(action==FSDropBlocked) {
        self.lastDragResult=@"目标分区或来源窗口已固定，未换位";
        [window moveTo:start error:nil];
        [self setMessage:@"固定的窗口或分区不能拖动换位；请先取消「固定此窗口」。"];
        return;
    }
    if(action==FSDropSwap && (![occupant isUsable] || ![occupant isOnScreen:FSOnScreenRows()])) {
        self.lastDragResult=@"目标分区窗口暂不可见，未交换";
        [window moveTo:start error:nil];
        [self setMessage:@"目标分区窗口暂不可见，未交换；请先显示该窗口。"];
        return;
    }
    [self rememberOriginal:window frame:start];
    if(action==FSDropSwap) {
        FSRect previous;if([occupant readFrame:&previous])[self rememberOriginal:occupant frame:previous];
    }
    [self storeWindow:window slot:destination];
    if(action==FSDropSwap)[self storeWindow:occupant slot:source];
    self.focusGeneration++;self.observedWindow=window;_placement.lastSlot=destination;
    self.epoch++;[self.pending removeAllIndexes];
    [self.suspended removeIndex:destination];[self.failures removeObjectForKey:@(destination)];
    [self.targets removeObjectForKey:@(destination)];
    if(source>=0){[self.suspended removeIndex:source];[self.failures removeObjectForKey:@(source)];[self.targets removeObjectForKey:@(source)];}
    [self saveConfig];
    [self arrangeSlot:destination manual:YES];
    if(action==FSDropSwap)[self arrangeSlot:source manual:YES];
    [self refreshDragTargets];
    if(self.settingsWindow.visible){self.windowChoices=FSAvailableWindows();[self refreshControls];}
    if([self.suspended containsIndex:destination] || (source>=0 && [self.suspended containsIndex:source])) {
        self.lastDragResult=@"分区已更新，但窗口拒绝目标尺寸；请增大分区或减少间距";
        return;
    }
    NSString *detail=action==FSDropSwap?@"已与原窗口交换":action==FSDropReplace?@"原窗口仍保持打开":@"已移动";
    self.lastDragResult=[NSString stringWithFormat:@"已换到区域 %d（%@）",destination+1,
                         pointerOnly?@"标题栏落点":@"窗口位移"];
    [self setMessage:[NSString stringWithFormat:@"%@ → 区域 %d · %@。",window.appName,destination+1,detail]];
}
- (void)scheduleAutomaticPlacement {
    if(!self.locked || _placement.switching)return;
    NSUInteger generation=++self.focusGeneration;
    __weak FSApp *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.10*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        FSApp *app=weakSelf;
        if(app && app.focusGeneration==generation)[app captureActiveWindow];
    });
}
- (void)captureActiveWindow {
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    if(!self.locked || _placement.switching || self.sleeping || self.sessionInactive || self.menuOpen ||
       self.choosingWindow || NSApp.modalWindow || now<self.quietUntil ||
       self.dragSnapshots.count || NSEvent.pressedMouseButtons!=0 || now-self.lastMouseDown<.25 || !AXIsProcessTrusted())return;
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);if(!screen)return;
    NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
    if(!front || front.processIdentifier==getpid() || front.activationPolicy!=NSApplicationActivationPolicyRegular)return;
    [self.focusObserver watchPID:front.processIdentifier];
    FSWindow *window=FSFocusedWindow(front.processIdentifier);FSRect frame;
    if(!window){self.observedWindow=nil;return;}
    /* Automatic capture never pulls a window off a different physical display. */
    if(![window readFrame:&frame] || FSScreenForFrame(frame)!=screen)return;
    /* Resolve the saved group before allocating a new slot (especially on restart).
       A newly focused/restored window must not wait for the periodic resolver. */
    [self resolveBindings:![window sameWindow:self.observedWindow]];
    NSInteger known=-1;unsigned occupied=0,reserved=0;
    for(int i=0;i<self.zoneCount;i++)if([self slotPinned:i] && self.runtime[@(i)] &&
                                           ![self.borrowedSlots containsIndex:i])reserved|=1u<<i;
    /* A pin on a temporarily hidden slot stays attached to its window when
       changing from four zones to two. Explicit manual reassignment can move it. */
    for(int i=self.zoneCount;i<4;i++)if([self slotPinned:i]) {
        FSWindow *hidden=self.runtime[@(i)];
        NSDictionary *binding=FSProfilePin(self.profile,i);
        FSRect hiddenFrame;
        BOOL alive=hidden && [hidden readFrame:&hiddenFrame] &&
                   [NSRunningApplication runningApplicationWithProcessIdentifier:hidden.pid];
        if((alive && [window sameWindow:hidden]) ||
           (!alive && [window.bundleID isEqual:binding[@"bundle"]] && [window.title isEqual:binding[@"title"]]))
            return;
    }
    for(int i=0;i<self.zoneCount;i++) {
        FSWindow *other=self.runtime[@(i)];FSRect otherFrame;
        NSRunningApplication *owner=other?[NSRunningApplication runningApplicationWithProcessIdentifier:other.pid]:nil;
        if(other && owner && !owner.terminated && [other readFrame:&otherFrame]) {
            occupied|=1u<<i;if([window sameWindow:other])known=i;
        } else if(other)[self.runtime removeObjectForKey:@(i)];
    }
    NSInteger newlyCreatedSlot=[self createdWindowActiveSlot:window];
    if(known>=0 && [window sameWindow:self.observedWindow] &&
       [window.title isEqual:self.profile[@"bindings"][known][@"title"]]) {
        FSRect zones[4],actual;
        int count=FSBuildZones([self.profile[@"layout"] intValue],FSUsableFrame(screen),
            [self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones);
        if(known<count && [window readFrame:&actual] && FSRectNear(actual,zones[known],3))return;
    }
    if(known<0)for(FSAssignment *entry in [self.histories[self.profile[@"id"]] reverseObjectEnumerator])
        if([window sameWindow:entry.window]){known=entry.slot;break;}
    if(known>=0 && [self slotPinned:known] && ![self.borrowedSlots containsIndex:known] &&
       [window sameWindow:self.runtime[@(known)]])
        reserved&=~(1u<<known);
    int slot=known>=0?FSPlacementChooseAvailableSlot(&_placement,self.zoneCount,(int)known,occupied,reserved):
        FSPlacementChooseNewWindowSlot(&_placement,self.zoneCount,(int)newlyCreatedSlot,occupied,reserved,
                                       [self.profile[@"newWindowInActiveSlot"] boolValue]);
    if(slot<0) {
        [self setMessage:@"所有分区目前都有固定窗口；新窗口保持原位置。可取消一个「固定此窗口」后继续自动接纳。"];
        return;
    }
    BOOL changed=![window sameWindow:self.runtime[@(slot)]] || ![window.title isEqual:self.profile[@"bindings"][slot][@"title"]];
    [self storeWindow:window slot:slot];self.observedWindow=window;_placement.lastSlot=slot;
    /* Invalidate checks for displaced windows without retrying other suspended slots. */
    self.epoch++;[self.pending removeAllIndexes];[self.suspended removeIndex:slot];
    [self.failures removeObjectForKey:@(slot)];[self.targets removeObjectForKey:@(slot)];
    if(changed)[self saveConfig];
    [self arrangeSlot:slot manual:NO];
    [self refreshDragTargets];
    if(![self.suspended containsIndex:slot]) {
        FSRect actual={0},zones[4];NSScreen *targetScreen=FSScreenWithID(self.profile[@"display"]);
        int count=targetScreen?FSBuildZones([self.profile[@"layout"] intValue],FSUsableFrame(targetScreen),
            [self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones):0;
        BOOL arrived=slot<count && [window readFrame:&actual] && FSRectNear(actual,zones[slot],4);
        NSString *result=[self.pending containsIndex:slot]?@"正在确认位置":
            (arrived?@"已在目标位置":@"尚未到位，请查看权限诊断中的分区坐标");
        [self setMessage:[NSString stringWithFormat:@"%@ → 区域 %d · %@；原窗口仍保持打开。",window.appName,slot+1,result]];
    }
    if(self.settingsWindow.visible){self.windowChoices=FSAvailableWindows();[self refreshControls];}
}
- (void)seedEmptySlots {
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);if(!screen)return;
    NSArray<FSWindow *> *windows=FSAvailableWindows();
    pid_t pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    FSWindow *focused=FSFocusedWindow(pid==getpid()?self.lastExternalPID:pid);
    NSMutableArray<FSWindow *> *ordered=[NSMutableArray new];
    if(focused)[ordered addObject:focused];
    for(FSWindow *window in windows)if(![window sameWindow:focused])[ordered addObject:window];
    for(FSWindow *window in ordered) {
        FSRect frame;if(![window readFrame:&frame] || FSScreenForFrame(frame)!=screen)continue;
        BOOL hiddenPin=NO;
        for(int i=self.zoneCount;i<4;i++)if([self slotPinned:i]) {
            FSWindow *saved=self.runtime[@(i)];NSDictionary *b=FSProfilePin(self.profile,i);
            FSRect savedFrame;
            BOOL alive=saved && [saved readFrame:&savedFrame] &&
                       [NSRunningApplication runningApplicationWithProcessIdentifier:saved.pid];
            if((alive && [saved sameWindow:window]) ||
               (!alive && [b[@"bundle"] isEqual:window.bundleID] && [b[@"title"] isEqual:window.title])) {
                hiddenPin=YES;break;
            }
        }
        if(hiddenPin)continue;
        BOOL used=NO;for(FSWindow *other in self.runtime.allValues)if([window sameWindow:other]){used=YES;break;}
        if(used)continue;
        /* Saved labels do not reserve an unpinned slot after their window
           closes or changes title. Live resolved windows already occupy runtime. */
        for(int slot=0;slot<self.zoneCount;slot++)if(!self.runtime[@(slot)]) {
            [self storeWindow:window slot:slot];break;
        }
    }
    self.windowChoices=windows;
}
- (void)activateCurrentLayout:(BOOL)seedEmpty {
    if(![self requirePermission]){[self refreshControls];return;}
    if(!FSScreenWithID(self.profile[@"display"])) {
        if(NSScreen.screens.count==1) {
            self.profile[@"display"]=FSDisplayID(NSScreen.screens.firstObject);
            [self setMessage:@"检测到保存的显示器标识已变化，已自动使用当前唯一的显示器。"];
        } else {
            [self setMessage:@"请先选择已连接的显示器。当前模式和窗口位置未改变。"];
            [self showSettings:nil];return;
        }
    }
    [self cancelActivation];[self resetTracking:NO];
    uint64_t token=FSPlacementBeginSwitch(&_placement);
    NSMutableSet *bundles=[NSMutableSet new];
    for(int i=0;i<self.zoneCount;i++) {
        NSString *bundle=([self slotPinned:i]?FSProfilePin(self.profile,i):FSProfileOccupant(self.profile,i))[@"bundle"];
        if(bundle.length)[bundles addObject:bundle];
    }
    [self resolveBindings:YES available:FSRestorableWindows(bundles)];
    if(seedEmpty)[self seedEmptySlots];
    for(int i=0;i<self.zoneCount;i++) {
        FSWindow *window=self.runtime[@(i)];
        [self rememberAssignment:window slot:i];
        [window restoreForLayout];
    }
    [self saveConfig];[self refreshControls];
    [self setMessage:@"正在恢复并排列布局中的窗口…"];
    __weak FSApp *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.22*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [weakSelf finishActivation:token attempt:0];
    });
}
- (void)finishActivation:(uint64_t)token attempt:(NSInteger)attempt {
    if(!FSPlacementSwitchIsCurrent(&_placement,token))return;
    if(!AXIsProcessTrusted() || !FSScreenWithID(self.profile[@"display"]) || self.sleeping || self.sessionInactive) {
        [self cancelActivation];[self updateStatus];return;
    }
    NSArray *visible=FSOnScreenRows();BOOL waiting=NO;
    for(int i=0;i<self.zoneCount;i++) {
        FSWindow *window=self.runtime[@(i)];
        if(window && [window isRestorable] && (![window isUsable] || ![window isOnScreen:visible]))waiting=YES;
    }
    if(waiting && attempt<3) {
        __weak FSApp *weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.28*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            [weakSelf finishActivation:token attempt:attempt+1];
        });return;
    }
    [self applyLayout:YES];
    __weak FSApp *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.16*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [weakSelf foregroundLayout:token];
    });
}
- (void)foregroundLayout:(uint64_t)token {
    if(!FSPlacementSwitchIsCurrent(&_placement,token))return;
    if(!AXIsProcessTrusted() || self.sleeping || self.sessionInactive || !FSScreenWithID(self.profile[@"display"])) {
        [self cancelActivation];return;
    }
    NSMutableArray<FSWindow *> *ready=[NSMutableArray new];int firstSlot=0;
    for(int i=0;i<self.zoneCount;i++) {
        FSWindow *window=self.runtime[@(i)];
        FSRect frame;
        if(window && [window isUsable] && [window readFrame:&frame] &&
           FSScreenForFrame(frame)==FSScreenWithID(self.profile[@"display"])) {
            if(!ready.count)firstSlot=i;[ready addObject:window];
        }
    }
    FSWindow *first=ready.firstObject;
    for(FSWindow *window in ready.reverseObjectEnumerator)[window raiseWindow];
    BOOL requested=[first focusWindow];
    __weak FSApp *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.16*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        FSApp *app=weakSelf;if(!app || !FSPlacementSwitchIsCurrent(&app->_placement,token))return;
        NSArray *rows=FSOnScreenRows();NSUInteger raised=0;
        /* A final bounded pass keeps an app's other windows from covering the group.
           This path is explicit-only: timers and focus capture never raise windows. */
        for(FSWindow *window in ready.reverseObjectEnumerator)
            if([window isOnScreen:rows] && [window raiseWindow])raised++;
        BOOL focused=first && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==first.pid &&
                     [first sameWindow:FSFocusedWindow(first.pid)];
        FSPlacementFinishSwitch(&app->_placement,token);
        app->_placement.lastSlot=firstSlot;app.observedWindow=focused?first:nil;
        app.quietUntil=NSDate.timeIntervalSinceReferenceDate+.55;
        if(focused)[app.settingsWindow orderOut:nil];
        app.windowChoices=FSAvailableWindows();
        if(!app.suspended.count) {
            if(!ready.count)[app setMessage:app.windowChoices.count?
                @"布局已开启，但这组窗口暂不可用。点击目标窗口使它处于前台，或在分区里重新选择窗口。":
                @"布局已开启，但当前没有识别到可调整窗口。请点「权限诊断」查看窗口识别数量和目标显示器。"];
            else [app setMessage:[NSString stringWithFormat:@"布局已启用 · 存档 %ld、找到 %lu 个窗口，%lu 个已前置。位置仍需核对；可在「权限诊断」查看各格。%@",
                (long)app.boundCount,(unsigned long)ready.count,(unsigned long)raised,
                focused?@"可直接操作第一格的可用窗口。":(requested?@"系统尚未交出焦点，可直接点目标窗口。":@"不可用窗口已跳过；不会自动启动应用。")]];
        }
        [app syncDragGuard:YES];[app refreshControls];
    });
}

- (void)registerHotKeys {
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    OSStatus handler=InstallEventHandler(GetApplicationEventTarget(),hotKeyCallback,1,&type,(__bridge void *)self,&_hotHandler);
    if(handler!=noErr){self.hotkeyWarning=@"快捷键注册失败，仍可使用菜单操作。";return;}
    UInt32 codes[]={kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4,kVK_ANSI_R,kVK_ANSI_P,
                    kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4,kVK_ANSI_5,kVK_ANSI_6,kVK_Tab,kVK_ANSI_L,kVK_ANSI_0};
    NSArray *names=@[@"⌃⌥1",@"⌃⌥2",@"⌃⌥3",@"⌃⌥4",@"⌃⌥R",@"⌃⌥P",
                     @"⌃⌥⌘1",@"⌃⌥⌘2",@"⌃⌥⌘3",@"⌃⌥⌘4",@"⌃⌥⌘5",@"⌃⌥⌘6",@"⌃⌥Tab",@"⌃⌥L",@"⌃⌥⌘0"];
    NSMutableArray *failed=[NSMutableArray new];
    for(int i=0;i<15;i++) {
        EventHotKeyID key={'FSpl',(UInt32)i+1};
        UInt32 modifiers=controlKey|optionKey;
        if((i>=6 && i<=11) || i==14)modifiers|=cmdKey;
        if(RegisterEventHotKey(codes[i],modifiers,key,GetApplicationEventTarget(),0,&_hotKeys[i])!=noErr)
            [failed addObject:names[i]];
    }
    self.hotkeyWarning=failed.count?[@"快捷键被占用：" stringByAppendingString:[failed componentsJoinedByString:@"、"]]:@"";
}
- (void)handleHotKey:(UInt32)identifier {
    if(identifier>=1 && identifier<=4)[self bindFocusedSlot:(NSInteger)identifier-1];
    else if(identifier==5)[self applyNow:nil];
    else if(identifier==6)[self toggleLock:nil];
    else if(identifier>=7 && identifier<=12)[self activatePreset:(NSInteger)identifier-7];
    else if(identifier==13)[self nextProfile:nil];
    else if(identifier==14)[self toggleDragMode:nil];
    else if(identifier==15)[self unlockLayout:nil];
}
- (NSMenuItem *)item:(NSString *)title action:(SEL)action value:(id)value {
    NSMenuItem *i=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    i.target=self;i.representedObject=value;return i;
}
- (void)menuWillOpen:(NSMenu *)menu {if(_placement.switching)[self cancelActivation];self.menuOpen=YES;}
- (void)menuDidClose:(NSMenu *)menu {self.menuOpen=NO;}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if(menu!=self.statusItem.menu)return;
    menu.autoenablesItems=NO;[menu removeAllItems];
    NSString *state=!self.locked?@"自由模式":(!AXIsProcessTrusted()?@"等待授权":(!FSScreenWithID(self.profile[@"display"])?@"等待显示器":@"自动分屏中"));
    NSMenuItem *heading=[self item:[NSString stringWithFormat:@"定屏 · %@ · %@",state,self.profile[@"name"]] action:NULL value:nil];
    heading.enabled=NO;[menu addItem:heading];
    [menu addItem:[self item:@"打开布局设置…" action:@selector(showSettings:) value:nil]];
    [menu addItem:[self item:self.locked?@"重新显示这组窗口   ⌃⌥R":@"启用上次布局   ⌃⌥R" action:@selector(applyNow:) value:nil]];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quickHeading=[self item:@"选择模式（点击立即生效）" action:NULL value:nil];
    quickHeading.enabled=NO;[menu addItem:quickHeading];
    NSMenuItem *free=[self item:@"自由模式 · 不分屏   ⌃⌥⌘0" action:@selector(unlockLayout:) value:nil];
    free.state=self.locked?NSControlStateValueOff:NSControlStateValueOn;[menu addItem:free];
    NSInteger presetIndex=0;
    for(NSDictionary *preset in quickPresets()) {
        NSInteger index=presetIndex++;
        NSString *shortcut=index<6?[NSString stringWithFormat:@"   ⌃⌥⌘%ld",(long)index+1]:@"";
        NSMenuItem *i=[self item:[preset[@"name"] stringByAppendingString:shortcut]
                         action:@selector(presetFromMenu:) value:@(index)];
        i.state=self.locked && [self matchesPreset:preset]?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:i];
    }
    NSMenuItem *profiles=[self item:@"切换保存的方案" action:NULL value:nil];NSMenu *sub=[NSMenu new];
    for(NSDictionary *p in self.config[@"profiles"]) {
        NSMenuItem *i=[self item:p[@"name"] action:@selector(profileFromMenu:) value:p[@"id"]];
        i.state=self.locked && [p[@"id"] isEqual:self.profile[@"id"]]?NSControlStateValueOn:NSControlStateValueOff;[sub addItem:i];
    }
    [sub addItem:NSMenuItem.separatorItem];[sub addItem:[self item:@"下一个方案   ⌃⌥Tab" action:@selector(nextProfile:) value:nil]];
    profiles.submenu=sub;[menu addItem:profiles];
    NSMenuItem *bind=[self item:@"将当前窗口放到…" action:NULL value:nil];NSMenu *bindMenu=[NSMenu new];
    NSArray *positions=positionNames([self.profile[@"layout"] intValue]);
    for(int i=0;i<self.zoneCount;i++)
        [bindMenu addItem:[self item:[NSString stringWithFormat:@"%d · %@   ⌃⌥%d",i+1,positions[i],i+1] action:@selector(bindFromMenu:) value:@(i)]];
    bind.submenu=bindMenu;[menu addItem:bind];
    NSMenuItem *pin=[self item:@"将当前窗口固定到…" action:NULL value:nil];NSMenu *pinMenu=[NSMenu new];
    for(int i=0;i<self.zoneCount;i++)
        [pinMenu addItem:[self item:[NSString stringWithFormat:@"%d · %@",i+1,positions[i]]
                               action:@selector(pinFocusedSlot:) value:@(i)]];
    pin.submenu=pinMenu;[menu addItem:pin];
    NSMenuItem *unpin=[self item:@"取消分区固定" action:NULL value:nil];NSMenu *unpinMenu=[NSMenu new];
    for(int i=0;i<self.zoneCount;i++)if([self slotPinned:i])
        [unpinMenu addItem:[self item:[NSString stringWithFormat:@"%d · %@ · %@",i+1,positions[i],
                           FSProfilePin(self.profile,i)[@"app"]] action:@selector(unpinFromMenu:) value:@(i)]];
    if(unpinMenu.numberOfItems==0)[unpinMenu addItem:[self item:@"当前没有固定的窗口" action:NULL value:nil]];
    unpin.submenu=unpinMenu;[menu addItem:unpin];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *more=[self item:@"更多操作" action:NULL value:nil];NSMenu *extra=[NSMenu new];
    [extra addItem:[self item:@"用当前屏幕的窗口填满空格" action:@selector(autoFill:) value:nil]];
    [extra addItem:[self item:@"交换 / 轮换分区窗口" action:@selector(rotateWindows:) value:nil]];
    [extra addItem:[self item:@"仅整理一次，然后进入自由模式" action:@selector(arrangeOnce:) value:nil]];
    NSMenuItem *drag=[self item:@"阻止标题栏拖动（关闭可拖动换位）   ⌃⌥L" action:@selector(toggleDragMode:) value:nil];
    drag.state=[self.profile[@"preventDrag"] boolValue]?NSControlStateValueOn:NSControlStateValueOff;[extra addItem:drag];
    [extra addItem:[self item:@"恢复分屏前的位置（本次运行）" action:@selector(restoreOriginals:) value:nil]];
    [extra addItem:NSMenuItem.separatorItem];
    [extra addItem:[self item:@"打开权限设置…" action:@selector(openPermission:) value:nil]];
    if(!AXIsProcessTrusted())
        [extra addItem:[self item:@"修复旧版授权…" action:@selector(repairOldPermission:) value:nil]];
    [extra addItem:[self item:@"权限诊断…" action:@selector(showPermissionDiagnostics:) value:nil]];
    [extra addItem:[self item:@"在 Finder 中显示当前应用" action:@selector(revealCurrentApp:) value:nil]];
    [extra addItem:[self item:@"打开配置文件夹" action:@selector(openConfigFolder:) value:nil]];
    [extra addItem:[self item:@"设置开机启动…" action:@selector(openLoginSettings:) value:nil]];
    [extra addItem:[self item:@"使用说明" action:@selector(showHelp:) value:nil]];
    more.submenu=extra;[menu addItem:more];
    [menu addItem:[self item:@"退出定屏" action:@selector(quit:) value:nil]];
}

- (void)createSettingsWindow {
    NSRect screen=(NSScreen.mainScreen?:NSScreen.screens.firstObject).visibleFrame;
    CGFloat scale=fmin(1.0,fmin((screen.size.width-32)/980.0,(screen.size.height-32)/690.0));
    if(scale<=0)scale=1;
    self.settingsWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,980*scale,690*scale)
                  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title=@"定屏 — 自动分屏";self.settingsWindow.releasedWhenClosed=NO;
    self.settingsWindow.delegate=self;[self.settingsWindow center];
    FSFlippedView *root=[[FSFlippedView alloc] initWithFrame:NSMakeRect(0,0,980*scale,690*scale)];
    self.settingsWindow.contentView=root;

    self.moreExpanded=[NSUserDefaults.standardUserDefaults boolForKey:@"showAdvanced"];
    FSFlippedView *v=[[FSFlippedView alloc] initWithFrame:NSMakeRect(0,0,980,610)];
    self.documentView=v;v.hidden=self.moreExpanded;[root addSubview:v];
    FSFlippedView *advanced=[[FSFlippedView alloc] initWithFrame:NSMakeRect(0,0,980,610)];
    self.advancedView=advanced;advanced.hidden=!self.moreExpanded;[root addSubview:advanced];

    [v addSubview:label(@"定屏",NSMakeRect(24,12,130,32),26,YES)];
    [v addSubview:label(@"选布局即生效 · 激活窗口自动归位 · 可为重要窗口保留位置",NSMakeRect(26,47,720,20),12,NO)];
    self.stateLabel=label(@"",NSMakeRect(680,20,272,24),13,YES);
    self.stateLabel.alignment=NSTextAlignmentRight;[v addSubview:self.stateLabel];
    NSTextField *version=label([@"v" stringByAppendingString:FSVersion],NSMakeRect(855,48,100,18),11,NO);
    version.alignment=NSTextAlignmentRight;version.textColor=NSColor.secondaryLabelColor;[v addSubview:version];

    FSCard *guide=[[FSCard alloc] initWithFrame:NSMakeRect(24,76,932,62)];[v addSubview:guide];
    self.guideTitle=label(@"",NSMakeRect(14,7,736,20),14,YES);[guide addSubview:self.guideTitle];
    self.guideDetail=label(@"",NSMakeRect(14,30,570,26),11,NO);
    self.guideDetail.maximumNumberOfLines=2;self.guideDetail.lineBreakMode=NSLineBreakByWordWrapping;
    [self.guideDetail.cell setUsesSingleLineMode:NO];[guide addSubview:self.guideDetail];
    self.repairButton=button(@"修复旧版授权",NSMakeRect(594,14,164,32),self,@selector(repairOldPermission:));
    self.repairButton.toolTip=@"退出定屏后，引导你移除旧记录并重新授权当前安装路径。";
    [guide addSubview:self.repairButton];
    self.guideButton=button(@"",NSMakeRect(762,14,158,32),self,NULL);[guide addSubview:self.guideButton];

    [v addSubview:label(@"选择布局",NSMakeRect(26,144,155,20),14,YES)];
    NSTextField *quickHint=label(@"点一次立即排列；固定的窗口不会被新窗口替换",NSMakeRect(465,146,489,18),11,NO);
    quickHint.alignment=NSTextAlignmentRight;quickHint.textColor=NSColor.secondaryLabelColor;[v addSubview:quickHint];
    self.freeButton=button(@"自由模式",NSMakeRect(24,166,128,52),self,@selector(unlockLayout:));
    [self.freeButton setButtonType:NSButtonTypePushOnPushOff];self.freeButton.bezelStyle=NSBezelStyleRegularSquare;
    self.freeButton.image=[NSImage imageWithSystemSymbolName:@"macwindow" accessibilityDescription:@"不分屏"];
    self.freeButton.imagePosition=NSImageAbove;self.freeButton.font=[NSFont systemFontOfSize:12];
    self.freeButton.toolTip=@"不分屏、不自动归位；已保存的固定选择会保留。⌃⌥⌘0";[v addSubview:self.freeButton];
    self.presetButtons=[NSMutableArray new];
    NSInteger index=0;
    for(NSDictionary *preset in quickPresets()) {
        NSInteger tile=index+1,row=tile/7,column=tile%7;
        NSButton *b=button(preset[@"name"],NSMakeRect(24+134*column,166+58*row,128,52),self,@selector(presetFromButton:));
        b.tag=index++;[b setButtonType:NSButtonTypePushOnPushOff];b.bezelStyle=NSBezelStyleRegularSquare;
        b.image=layoutIcon(preset);b.image.size=NSMakeSize(44,29);
        b.imagePosition=NSImageAbove;b.font=[NSFont systemFontOfSize:11];
        b.toolTip=[NSString stringWithFormat:@"%@：立即排列，之后激活的窗口自动归位。",
                   preset[@"detail"]?:preset[@"name"]];
        [v addSubview:b];[self.presetButtons addObject:b];
    }

    self.preview=[[FSPreview alloc] initWithFrame:NSMakeRect(24,286,322,100)];
    self.preview.toolTip=@"黑框是最近使用的分区；固定窗口出现时会收回自己的分区，空缺时允许临时补位。";
    __weak FSApp *weakSelf=self;
    self.preview.onSelectSlot=^(NSInteger slot){
        FSApp *app=weakSelf;
        if(app && app.locked && !app.choosingWindow && slot>=0 && slot<app.zoneCount) {
            if([app slotPinned:slot] && ![app.borrowedSlots containsIndex:slot] && app.runtime[@(slot)]) {
                [app setMessage:@"此区域已固定给指定窗口。要让新窗口使用它，请先取消固定。"];return;
            }
            app->_placement.lastSlot=(int)slot;[app refreshControls];
            app.observedWindow=FSFocusedWindow(app.lastExternalPID);
            [app setMessage:[NSString stringWithFormat:@"已选区域 %ld；固定分区不会被替换。",(long)slot+1]];
        }
    };
    [v addSubview:self.preview];
    [v addSubview:label(@"目标屏幕",NSMakeRect(365,287,140,18),11,YES)];
    self.screenPopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(365,309,590,28) pullsDown:NO];
    self.screenPopup.target=self;self.screenPopup.action=@selector(screenChanged:);self.screenPopup.menu.delegate=self;
    [v addSubview:self.screenPopup];
    [v addSubview:label(@"保存的方案",NSMakeRect(365,343,142,18),11,YES)];
    self.profilePopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(365,363,432,28) pullsDown:NO];
    self.profilePopup.target=self;self.profilePopup.action=@selector(profileChanged:);self.profilePopup.menu.delegate=self;
    [v addSubview:self.profilePopup];
    NSPopUpButton *manage=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(812,363,144,28) pullsDown:YES];
    [manage addItemWithTitle:@"管理方案"];manage.menu.delegate=self;
    [manage.menu addItem:[self item:@"另存为新方案…" action:@selector(duplicateProfile:) value:nil]];
    [manage.menu addItem:[self item:@"重命名…" action:@selector(renameProfile:) value:nil]];
    [manage.menu addItem:[self item:@"删除此方案…" action:@selector(deleteProfile:) value:nil]];
    [v addSubview:manage];

    [v addSubview:label(@"分区中的窗口",NSMakeRect(26,399,180,21),14,YES)];
    self.fillButton=button(@"填入空位",NSMakeRect(650,395,146,28),self,@selector(autoFill:));
    self.fillButton.toolTip=@"为没有窗口的分区找可用窗口；固定目标暂时不在时，可以临时补位。";[v addSubview:self.fillButton];
    NSButton *refresh=button(@"更新窗口列表",NSMakeRect(807,395,149,28),self,@selector(refreshWindowList:));
    [v addSubview:refresh];
    self.bindingLabels=[NSMutableArray new];self.bindingPopups=[NSMutableArray new];
    self.pickButtons=[NSMutableArray new];self.pinButtons=[NSMutableArray new];
    for(int i=0;i<4;i++) {
        CGFloat y=426+34*i;
        NSTextField *l=label(@"",NSMakeRect(26,y+4,98,22),11,YES);[v addSubview:l];[self.bindingLabels addObject:l];
        NSPopUpButton *popup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(123,y,552,28) pullsDown:NO];
        popup.tag=i;popup.target=self;popup.action=@selector(bindingChanged:);popup.menu.delegate=self;
        [v addSubview:popup];[self.bindingPopups addObject:popup];
        NSButton *pick=button(@"鼠标选窗口",NSMakeRect(685,y,122,28),self,@selector(beginPicking:));
        pick.tag=i;pick.toolTip=@"12 秒内点击目标窗口标题栏空白处。";[v addSubview:pick];[self.pickButtons addObject:pick];
        NSButton *pin=[NSButton checkboxWithTitle:@"固定此窗口" target:self action:@selector(togglePin:)];
        pin.frame=NSMakeRect(813,y+2,143,25);pin.tag=i;
        pin.toolTip=@"保存固定目标；目标暂时不在时允许临时补位，回来后自动收回。";
        [v addSubview:pin];[self.pinButtons addObject:pin];
    }
    [v addSubview:label(@"拖动规则",NSMakeRect(26,568,114,22),11,YES)];
    self.lockModePopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(139,565,284,29) pullsDown:NO];
    [self.lockModePopup addItemsWithTitles:@[@"拖到分区换位",@"阻止标题栏拖动"]];
    self.lockModePopup.target=self;self.lockModePopup.action=@selector(lockModeChanged:);[v addSubview:self.lockModePopup];
    self.guardStatusLabel=label(@"",NSMakeRect(434,570,254,19),11,NO);[v addSubview:self.guardStatusLabel];
    self.moreButton=button(@"更多设置 →",NSMakeRect(755,562,201,33),self,@selector(toggleMore:));
    [v addSubview:self.moreButton];

    [advanced addSubview:label(@"更多设置",NSMakeRect(25,24,200,30),24,YES)];
    [advanced addSubview:button(@"← 返回布局",NSMakeRect(790,22,166,34),self,@selector(toggleMore:))];
    [advanced addSubview:label(@"布局形状",NSMakeRect(27,83,160,22),13,YES)];
    self.layoutPopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(160,79,460,30) pullsDown:NO];
    [self.layoutPopup addItemsWithTitles:layoutNames()];self.layoutPopup.target=self;self.layoutPopup.action=@selector(layoutChanged:);
    [advanced addSubview:self.layoutPopup];
    [advanced addSubview:button(@"使用当前屏幕",NSMakeRect(720,79,236,30),self,@selector(useCurrentScreen:))];
    self.ratioLabel=label(@"",NSMakeRect(27,144,440,22),12,YES);[advanced addSubview:self.ratioLabel];
    self.ratioSlider=[NSSlider sliderWithValue:50 minValue:20 maxValue:80 target:self action:@selector(ratioChanged:)];
    self.ratioSlider.frame=NSMakeRect(27,173,440,26);self.ratioSlider.continuous=YES;[advanced addSubview:self.ratioSlider];
    self.gapLabel=label(@"",NSMakeRect(510,144,440,22),12,YES);[advanced addSubview:self.gapLabel];
    self.gapSlider=[NSSlider sliderWithValue:8 minValue:0 maxValue:40 target:self action:@selector(gapChanged:)];
    self.gapSlider.frame=NSMakeRect(510,173,440,26);self.gapSlider.continuous=YES;[advanced addSubview:self.gapSlider];
    self.permissionLabel=label(@"",NSMakeRect(27,250,580,26),13,YES);[advanced addSubview:self.permissionLabel];
    self.permissionButton=button(@"打开权限设置",NSMakeRect(720,245,236,34),self,@selector(openPermission:));
    [advanced addSubview:self.permissionButton];
    [advanced addSubview:button(@"权限诊断",NSMakeRect(720,292,236,32),self,@selector(showPermissionDiagnostics:))];
    [advanced addSubview:label(@"固定窗口的位置只在自动分屏时维持；自由模式保留选择，允许自由摆放。",NSMakeRect(27,324,660,22),12,NO)];
    self.createdWindowCheckbox=[NSButton checkboxWithTitle:@"新建窗口优先放入当前活动分区" target:self action:@selector(newWindowPreferenceChanged:)];
    self.createdWindowCheckbox.frame=NSMakeRect(27,355,495,26);
    self.createdWindowCheckbox.toolTip=@"新建的普通窗口会替换当前未固定分区的窗口；已有窗口仍回原位或先填空格。";
    [advanced addSubview:self.createdWindowCheckbox];
    [advanced addSubview:label(@"已固定的分区始终保留；关闭此项后，新窗口优先填空格。",NSMakeRect(510,357,448,22),11,NO)];
    self.launchCheckbox=[NSButton checkboxWithTitle:@"启动时打开设置窗口" target:self action:@selector(launchPreferenceChanged:)];
    self.launchCheckbox.frame=NSMakeRect(27,401,350,26);
    self.launchCheckbox.state=[NSUserDefaults.standardUserDefaults boolForKey:@"showSettingsOnLaunch"]?NSControlStateValueOn:NSControlStateValueOff;
    [advanced addSubview:self.launchCheckbox];
    [advanced addSubview:button(@"设置开机启动…",NSMakeRect(720,398,236,32),self,@selector(openLoginSettings:))];
    [advanced addSubview:label(@"窗口位置达不到指定大小时，可降低比例、减少间距或切换分区数。",NSMakeRect(27,475,920,22),12,NO)];

    FSFlippedView *footer=[[FSFlippedView alloc] initWithFrame:NSMakeRect(0,610,980,80)];[root addSubview:footer];
    NSBox *line=[[NSBox alloc] initWithFrame:NSMakeRect(0,0,980,1)];line.boxType=NSBoxSeparator;[footer addSubview:line];
    self.lockButton=button(@"显示这组窗口",NSMakeRect(24,8,222,34),self,@selector(applyNow:));
    [footer addSubview:self.lockButton];
    self.rotateButton=button(@"交换窗口位置",NSMakeRect(258,8,204,34),self,@selector(rotateWindows:));[footer addSubview:self.rotateButton];
    self.restoreButton=button(@"恢复原来的位置",NSMakeRect(474,8,202,34),self,@selector(restoreOriginals:));[footer addSubview:self.restoreButton];
    [footer addSubview:button(@"使用说明",NSMakeRect(830,8,126,34),self,@selector(showHelp:))];
    self.statusLabel=label(@"",NSMakeRect(25,48,931,27),11,NO);
    self.statusLabel.maximumNumberOfLines=2;self.statusLabel.lineBreakMode=NSLineBreakByWordWrapping;
    [self.statusLabel.cell setUsesSingleLineMode:NO];self.statusLabel.textColor=NSColor.secondaryLabelColor;[footer addSubview:self.statusLabel];
    root.bounds=NSMakeRect(0,0,980,690);
}

- (void)showSettings:(id)sender {
    [self cancelActivation];
    if(!self.settingsWindow)[self createSettingsWindow];
    [self refreshWindowList:nil];
    [NSApp activateIgnoringOtherApps:YES];[self.settingsWindow makeKeyAndOrderFront:nil];
    [NSUserDefaults.standardUserDefaults setObject:FSVersion forKey:@"lastShownVersion"];
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    if(!self.choosingWindow && NSDate.timeIntervalSinceReferenceDate-self.lastWindowRefresh>1)[self refreshWindowList:nil];
}
- (void)windowWillClose:(NSNotification *)notification {[self finishPicking];}
- (void)refreshWindowList:(id)sender {
    if(sender)[self cancelActivation];
    self.windowChoices=FSAvailableWindows();self.lastWindowRefresh=NSDate.timeIntervalSinceReferenceDate;
    if(AXIsProcessTrusted())[self resolveBindings:YES available:self.windowChoices];
    [self refreshControls];
    if(sender) {
        if(![self requirePermission])return;
        [self resetTracking:NO];
        [self setMessage:self.windowChoices.count?@"窗口列表已刷新。只列出当前桌面中可调整的普通窗口。":@"未找到可调整窗口：请退出目标窗口的全屏或最小化状态。"];
        [self syncDragGuard:YES];
    }
}
- (NSInteger)boundCount {
    NSInteger n=0;for(int i=0;i<self.zoneCount;i++)if([self.profile[@"bindings"][i][@"bundle"] length])n++;
    return n;
}
- (void)updateStatus {
    BOOL trusted=AXIsProcessTrusted(),connected=FSScreenWithID(self.profile[@"display"])!=nil;
    BOOL active=self.locked && trusted && connected && !self.choosingWindow && !self.sleeping && !self.sessionInactive;
    if(active && !self.activity)
        self.activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"保持用户启用的自动分屏"];
    else if(!active && self.activity) {
        [NSProcessInfo.processInfo endActivity:self.activity];self.activity=nil;
    }
    NSString *state=!self.locked?@"自由模式":(!trusted?@"等待授权":(!connected?@"等待显示器":(_placement.switching?@"正在切换":@"自动分屏中")));
    self.stateLabel.stringValue=state;
    self.stateLabel.textColor=active?NSColor.systemGreenColor:NSColor.secondaryLabelColor;
    self.permissionLabel.stringValue=trusted?@"● 已获辅助功能授权":@"● 尚未授权；自由模式可正常使用";
    self.permissionLabel.textColor=trusted?NSColor.systemGreenColor:NSColor.systemOrangeColor;
    self.lockButton.enabled=trusted && connected && !self.choosingWindow;
    self.lockButton.title=self.locked?@"显示这组窗口":@"启用当前布局";
    self.freeButton.state=self.locked?NSControlStateValueOff:NSControlStateValueOn;
    for(NSButton *b in self.presetButtons)b.state=self.locked && [self matchesPreset:quickPresets()[b.tag]]?NSControlStateValueOn:NSControlStateValueOff;
    self.restoreButton.enabled=trusted && self.originals.count>0 && !self.choosingWindow;
    NSInteger freeBound=0,freeCount=0;
    for(int i=0;i<self.zoneCount;i++)if(![self slotPinned:i]) {
        freeCount++;if([self.profile[@"bindings"][i][@"bundle"] length])freeBound++;
    }
    self.rotateButton.enabled=trusted && connected && freeCount>=2 && freeBound>=2 && !self.choosingWindow;
    self.rotateButton.title=freeCount==2?@"交换未固定窗口":@"未固定窗口轮换";
    BOOL vacant=NO;for(int i=0;i<self.zoneCount;i++)if(!self.runtime[@(i)])vacant=YES;
    self.fillButton.enabled=trusted && connected && vacant && !self.choosingWindow;
    for(NSButton *b in self.pickButtons)b.enabled=trusted && connected && b.tag<self.zoneCount && !self.choosingWindow;
    for(NSButton *b in self.pinButtons)b.enabled=b.tag<self.zoneCount &&
        ([FSProfileOccupant(self.profile,b.tag)[@"bundle"] length]>0 || [self slotPinned:b.tag]) &&
        !self.choosingWindow;
    self.lockModePopup.enabled=!self.choosingWindow;
    self.preview.freeMode=!self.locked;self.preview.activeSlot=_placement.lastSlot;self.preview.needsDisplay=YES;
    if(!self.locked)self.guardStatusLabel.stringValue=@"自由模式 · 不固定窗口";
    else if(!trusted || !connected)self.guardStatusLabel.stringValue=@"条件未就绪 · 暂停调整";
    else if(self.choosingWindow || _placement.switching)self.guardStatusLabel.stringValue=@"操作期间暂不拦截拖动";
    else if(![self.profile[@"preventDrag"] boolValue])self.guardStatusLabel.stringValue=@"拖动标题栏到其他分区可换位";
    else self.guardStatusLabel.stringValue=self.dragGuard.running?@"自动分屏 · 阻止标题栏拖动":@"标题栏拦截不可用 · 松手回位";
    self.guardStatusLabel.textColor=NSColor.secondaryLabelColor;
    self.statusItem.button.title=self.statusItem.button.image?(self.locked?(!trusted || !connected?@" !":@" 自动"):@""):@"定屏";
    self.statusItem.button.toolTip=[NSString stringWithFormat:@"定屏 · %@ · %@",state,self.profile[@"name"]];
    self.statusLabel.stringValue=self.statusText?:@"点击布局立即生效。";
    self.guideButton.enabled=YES;
    self.repairButton.hidden=trusted || self.choosingWindow;
    self.repairButton.enabled=!self.choosingWindow;
    if(self.choosingWindow) {
        NSInteger seconds=MAX(0,(NSInteger)ceil(self.pickingDeadline-NSDate.timeIntervalSinceReferenceDate));
        self.guideTitle.stringValue=[NSString stringWithFormat:@"点击区域 %ld 要使用的窗口（%ld 秒）",(long)self.pickingSlot+1,(long)seconds];
        self.guideDetail.stringValue=@"请点目标窗口标题栏空白处；超时会取消。选择期间暂停自动归位。";
        self.guideButton.title=@"取消选择";self.guideButton.action=@selector(cancelPicking:);
    } else if(!trusted) {
        self.guideTitle.stringValue=self.locked?@"自动分屏需要辅助功能权限":@"当前为自由模式 · 分屏前需授权";
        self.guideDetail.stringValue=@"系统开关已开仍无效时，点「修复旧版授权」移除旧条目，再添加当前 App。";
        self.guideButton.title=@"打开权限设置";self.guideButton.action=@selector(openPermission:);
    } else if(!self.locked) {
        self.guideTitle.stringValue=@"自由模式 · 窗口由你自己摆放";
        self.guideDetail.stringValue=@"点击下方任一布局立即开始自动分屏。设置和窗口组合仍保留，切回时可继续使用。";
        self.guideButton.title=@"启用当前布局";self.guideButton.action=@selector(fixLayout:);
    } else if(!connected) {
        self.guideTitle.stringValue=@"目标显示器未连接 · 自动分屏暂停";
        self.guideDetail.stringValue=@"连接原显示器，或选择现在使用的屏幕。也可随时切回自由模式。";
        self.guideButton.title=@"使用当前屏幕";self.guideButton.action=@selector(useCurrentScreen:);
    } else if(_placement.switching) {
        self.guideTitle.stringValue=@"正在恢复并显示布局中的窗口";
        self.guideDetail.stringValue=@"点击其他布局以最后一次为准；点击自由模式会立即停止后续调整。";
        self.guideButton.title=@"自由模式";self.guideButton.action=@selector(unlockLayout:);
    } else if(self.suspended.count) {
        self.guideTitle.stringValue=@"部分窗口受尺寸限制";
        self.guideDetail.stringValue=@"这些窗口已暂停固定。可增大分区、换成两栏，或点「显示这组窗口」重试。";
        self.guideButton.title=@"显示这组窗口";self.guideButton.action=@selector(applyNow:);
    } else {
        self.guideTitle.stringValue=[NSString stringWithFormat:@"自动分屏中 · %@ · %d 个分区",layoutNames()[[self.profile[@"layout"] integerValue]],self.zoneCount];
        self.guideDetail.stringValue=@"打开或切换窗口自动归位。固定窗口出现时优先占用指定分区；暂时关闭时，其他窗口可以临时补位。";
        self.guideButton.title=@"自由模式";self.guideButton.action=@selector(unlockLayout:);
    }
}
- (void)refreshControls {
    if(!self.settingsWindow)return;
    self.refreshing=YES;
    NSMutableDictionary *p=self.profile;
    [self.profilePopup removeAllItems];
    for(NSDictionary *candidate in self.config[@"profiles"]) {
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:candidate[@"name"] action:nil keyEquivalent:@""];
        [self.profilePopup.menu addItem:item];self.profilePopup.lastItem.representedObject=candidate[@"id"];
        if([candidate[@"id"] isEqual:p[@"id"]])[self.profilePopup selectItem:self.profilePopup.lastItem];
    }
    [self.screenPopup removeAllItems];
    BOOL found=NO;
    NSUInteger screenIndex=0;
    for(NSScreen *s in NSScreen.screens) {
        NSString *sid=FSDisplayID(s);
        [self.screenPopup addItemWithTitle:[NSString stringWithFormat:@"%lu · %@ · %.0f × %.0f",(unsigned long)++screenIndex,s.localizedName,s.frame.size.width,s.frame.size.height]];
        self.screenPopup.lastItem.representedObject=sid;
        if([sid isEqual:p[@"display"]]){found=YES;[self.screenPopup selectItem:self.screenPopup.lastItem];}
    }
    if(!found) {
        [self.screenPopup addItemWithTitle:@"保存的显示器未连接（暂停调整）"];
        self.screenPopup.lastItem.representedObject=p[@"display"];[self.screenPopup selectItem:self.screenPopup.lastItem];
    }
    int kind=[p[@"layout"] intValue];
    [self.lockModePopup selectItemAtIndex:[p[@"preventDrag"] boolValue]?1:0];
    self.createdWindowCheckbox.state=[p[@"newWindowInActiveSlot"] boolValue]?NSControlStateValueOn:NSControlStateValueOff;
    for(NSButton *b in self.presetButtons)b.state=self.locked && [self matchesPreset:quickPresets()[b.tag]]?NSControlStateValueOn:NSControlStateValueOff;
    [self.layoutPopup selectItemAtIndex:kind];
    self.ratioSlider.doubleValue=[p[@"ratio"] doubleValue]*100;
    self.gapSlider.doubleValue=[p[@"gap"] doubleValue];
    BOOL ratioUseful=(kind!=FSLayoutColumns3 && kind!=FSLayoutRows3 && kind!=FSLayoutFill);
    self.ratioSlider.enabled=ratioUseful;
    int r=(int)round(self.ratioSlider.doubleValue);
    BOOL vertical=kind==FSLayoutRows2 || kind==FSLayoutMainTopAndColumns;
    self.ratioLabel.stringValue=ratioUseful?[NSString stringWithFormat:@"%@ %d%%  /  %@ %d%%",vertical?@"上方":@"左侧",r,vertical?@"下方":@"右侧",100-r]:@"此布局使用固定比例";
    self.gapLabel.stringValue=[NSString stringWithFormat:@"窗口间距与外边距：%d 点",(int)round(self.gapSlider.doubleValue)];
    NSMutableArray *names=[NSMutableArray new];
    NSArray *positions=positionNames(kind);
    for(int i=0;i<4;i++) {
        NSPopUpButton *popup=self.bindingPopups[i];NSDictionary *binding=FSProfileOccupant(p,i);
        NSDictionary *pin=FSProfilePin(p,i);
        BOOL enabled=i<self.zoneCount;
        popup.enabled=enabled;self.bindingLabels[i].textColor=enabled?NSColor.labelColor:NSColor.tertiaryLabelColor;
        self.bindingLabels[i].stringValue=enabled?[NSString stringWithFormat:@"%d · %@",i+1,positions[i]]:[NSString stringWithFormat:@"%d · 未使用",i+1];
        self.pinButtons[i].state=[self slotPinned:i]?NSControlStateValueOn:NSControlStateValueOff;
        self.pinButtons[i].title=[self slotPinned:i]?@"已固定 · 可取消":@"固定此窗口";
        [popup removeAllItems];[popup addItemWithTitle:enabled?
            ([self slotPinned:i]?@"固定中 · 先取消固定才能清空":@"空闲分区 / 清空此区域"):
            @"此布局未使用该区域"];
        if(pin[@"bundle"]) {
            [popup addItemWithTitle:[NSString stringWithFormat:@"固定目标 · %@ — %@",pin[@"app"],pin[@"title"]]];
            popup.lastItem.representedObject=@"saved";[popup selectItem:popup.lastItem];
        } else if(binding[@"bundle"]) {
            [popup addItemWithTitle:[NSString stringWithFormat:@"上次占位 · %@ — %@",binding[@"app"],binding[@"title"]]];
            popup.lastItem.representedObject=@"saved";[popup selectItem:popup.lastItem];
        }
        for(FSWindow *w in self.windowChoices) {
            NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:w.label action:nil keyEquivalent:@""];
            NSImage *icon=[[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid].icon copy];
            icon.size=NSMakeSize(16,16);item.image=icon;
            [popup.menu addItem:item];popup.lastItem.representedObject=w;
            if([w sameWindow:self.runtime[@(i)]]) {
                if([self.suspended containsIndex:i])item.title=[@"尺寸受限 · " stringByAppendingString:item.title];
                [popup selectItem:popup.lastItem];
            }
        }
        FSWindow *occupant=self.runtime[@(i)];
        NSString *name=enabled?(occupant.appName?:pin[@"app"]?:binding[@"app"]?:@""):@"";
        if(enabled && [self.borrowedSlots containsIndex:i])
            name=[NSString stringWithFormat:@"🔒 %@ 暂缺 · %@ 代用",pin[@"app"],occupant.appName];
        else if([self slotPinned:i] && enabled)name=[@"🔒 " stringByAppendingString:name];
        [names addObject:name];
    }
    NSScreen *screen=FSScreenWithID(p[@"display"]);
    FSRect usable=screen?FSUsableFrame(screen):(FSRect){0,0,16,9};
    self.preview.layout=kind;self.preview.ratio=[p[@"ratio"] doubleValue];self.preview.gap=[p[@"gap"] doubleValue];
    self.preview.aspect=usable.width/usable.height;self.preview.names=names;self.preview.needsDisplay=YES;
    self.statusLabel.stringValue=self.statusText?:@"";
    self.refreshing=NO;[self updateStatus];
}

- (void)toggleMore:(id)sender {
    self.moreExpanded=!self.moreExpanded;
    [NSUserDefaults.standardUserDefaults setBool:self.moreExpanded forKey:@"showAdvanced"];
    self.advancedView.hidden=!self.moreExpanded;
    self.documentView.hidden=self.moreExpanded;
}
- (void)launchPreferenceChanged:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state==NSControlStateValueOn forKey:@"showSettingsOnLaunch"];
    [self setMessage:sender.state==NSControlStateValueOn?@"下次启动时会显示设置窗口。":@"配置完成后，下次启动将常驻菜单栏。首次升级和需要授权时仍会显示引导。"];
}
- (void)newWindowPreferenceChanged:(NSButton *)sender {
    if(self.refreshing)return;
    self.profile[@"newWindowInActiveSlot"]=@(sender.state==NSControlStateValueOn);
    [self saveConfig];
    [self setMessage:sender.state==NSControlStateValueOn?
        @"新建窗口将优先进入当前活动分区；固定位置不受影响。":
        @"新建窗口会先填未固定空格，空格用完后进入最近使用的分区。"];
}
- (void)useCurrentScreen:(id)sender {
    NSScreen *screen=self.settingsWindow.screen?:NSScreen.mainScreen;
    if(!screen)return;
    self.profile[@"display"]=FSDisplayID(screen);[self changedGeometry];
}
- (void)autoFill:(id)sender {
    if(![self requirePermission])return;
    if(!FSScreenWithID(self.profile[@"display"])){[self setMessage:@"请先选择已连接的目标显示器。"];return;}
    [self cancelActivation];[self finishPicking];[self resolveBindings:YES];
    NSUInteger before=self.runtime.count;[self seedEmptySlots];
    [self resetTracking:NO];[self saveConfig];
    if(self.locked)[self applyLayout:YES];
    [self refreshControls];[self syncDragGuard:YES];
    [self setMessage:[NSString stringWithFormat:@"已填入 %ld 个空闲分区。%@",(long)(self.runtime.count-before),self.locked?@"自动分屏继续生效。":@"当前为自由模式，点击布局后开始分屏。"]];
}
- (void)rotateWindows:(id)sender {
    if(![self requirePermission])return;
    if(!FSScreenWithID(self.profile[@"display"])){[self setMessage:@"目标显示器未连接，暂不交换位置。"];return;}
    NSMutableArray<NSNumber *> *freeSlots=[NSMutableArray new];
    NSInteger freeBound=0;
    for(int i=0;i<self.zoneCount;i++)if(![self slotPinned:i]) {
        [freeSlots addObject:@(i)];
        if([self.profile[@"bindings"][i][@"bundle"] length])freeBound++;
    }
    if(freeSlots.count<2 || freeBound<2) {
        [self setMessage:@"至少需要两个未固定的分区窗口才能交换；已固定的窗口留在原位。"];return;
    }
    [self cancelActivation];[self finishPicking];[self resolveBindings:YES];
    NSArray *old=[self.profile[@"bindings"] copy];NSDictionary *previous=[self.runtime copy];
    for(NSUInteger index=0;index<freeSlots.count;index++) {
        NSInteger slot=freeSlots[index].integerValue;
        NSInteger source=freeSlots[(index+freeSlots.count-1)%freeSlots.count].integerValue;
        FSProfileSetOccupant(self.profile,slot,old[source]);
        if(previous[@(source)])self.runtime[@(slot)]=previous[@(source)];
        else [self.runtime removeObjectForKey:@(slot)];
        [self rememberAssignment:self.runtime[@(slot)] slot:slot];
    }
    [self resetTracking:NO];[self saveConfig];[self applyLayout:YES];[self syncDragGuard:YES];[self refreshControls];
}
- (void)arrangeOnce:(id)sender {
    if(![self requirePermission])return;
    [self unlockLayout:nil];
    [self resolveBindings:YES];[self seedEmptySlots];[self saveConfig];
    [self applyLayout:YES];[self refreshControls];
    if(!self.suspended.count)[self setMessage:@"已整理一次，当前为自由模式。窗口可自由移动，新窗口不会自动归位。"];
}
- (void)finishPicking {
    if(!self.choosingWindow && !self.pickMonitor)return;
    self.choosingWindow=NO;self.pickingGeneration++;
    if(self.pickMonitor){[NSEvent removeMonitor:self.pickMonitor];self.pickMonitor=nil;}
    self.quietUntil=NSDate.timeIntervalSinceReferenceDate+.4;
}
- (void)cancelPicking:(id)sender {
    [self finishPicking];[self updateStatus];
    [self setMessage:@"已取消点选，原来的窗口选择未变。"];
}
- (void)beginPicking:(NSButton *)sender {
    if(![self requirePermission] || sender.tag<0 || sender.tag>=self.zoneCount)return;
    [self cancelActivation];
    [self finishPicking];self.choosingWindow=YES;self.pickingSlot=sender.tag;
    self.pickingDeadline=NSDate.timeIntervalSinceReferenceDate+12;self.pickingGeneration++;
    NSUInteger generation=self.pickingGeneration;
    self.dragGuard.targets=@[];
    __weak FSApp *weakSelf=self;
    self.pickMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp handler:^(NSEvent *event) {
        FSApp *app=weakSelf;if(!app || !app.choosingWindow || generation!=app.pickingGeneration)return;
        CGEventRef cg=event.CGEvent;
        NSPoint mouse=NSEvent.mouseLocation;
        CGPoint point=cg?CGEventGetLocation(cg):CGPointMake(mouse.x,NSMaxY(NSScreen.screens.firstObject.frame)-mouse.y);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.05*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            FSApp *current=weakSelf;
            if(!current || !current.choosingWindow || generation!=current.pickingGeneration)return;
            if(NSDate.timeIntervalSinceReferenceDate>=current.pickingDeadline || !AXIsProcessTrusted()) {
                [current cancelPicking:nil];return;
            }
            FSWindow *window=FSWindowAtPoint(point);
            if(!window){[current setMessage:@"这里不是可调整的普通窗口。请点击目标窗口标题栏空白处，或回到定屏取消。"];return;}
            NSInteger slot=current.pickingSlot;[current finishPicking];
            [current bindWindow:window slot:slot];
            [current showSettings:nil];
        });
    }];
    if(!self.pickMonitor) {
        [self finishPicking];[self setMessage:@"系统未允许点选，请用下拉列表或 ⌃⌥1–4 选择窗口。"];
    } else [self setMessage:@"请在 12 秒内点击目标窗口的标题栏空白处。选择期间暂不自动调整窗口。"];
    [self updateStatus];
}

- (BOOL)matchesPreset:(NSDictionary *)preset {
    int kind=[self.profile[@"layout"] intValue];
    return kind==[preset[@"layout"] intValue] &&
           (kind==FSLayoutColumns3 || kind==FSLayoutRows3 ||
            fabs([self.profile[@"ratio"] doubleValue]-[preset[@"ratio"] doubleValue])<.01);
}
- (void)activatePreset:(NSInteger)index {
    if(index<0 || (NSUInteger)index>=quickPresets().count)return;
    if(![self requirePermission]){[self refreshControls];return;}
    NSDictionary *preset=quickPresets()[index];
    self.profile[@"layout"]=preset[@"layout"];self.profile[@"ratio"]=preset[@"ratio"];
    [self activateCurrentLayout:YES];
}
- (void)presetFromButton:(NSButton *)sender {[self activatePreset:sender.tag];}
- (void)presetFromMenu:(NSMenuItem *)sender {[self activatePreset:[sender.representedObject integerValue]];}
- (void)nextProfile:(id)sender {
    if(![self requirePermission])return;
    NSArray *profiles=self.config[@"profiles"];
    NSUInteger index=[profiles indexOfObjectIdenticalTo:self.profile];
    NSUInteger next=index==NSNotFound?0:(index+1)%profiles.count;
    self.locked=YES;[self switchProfile:profiles[next][@"id"]];
}
- (void)lockModeChanged:(NSPopUpButton *)sender {
    if(self.refreshing)return;
    self.profile[@"preventDrag"]=@(sender.indexOfSelectedItem==1);
    [self saveConfig];[self syncDragGuard:YES];[self refreshControls];
    if(![self requirePermission])return;
    if(!self.locked)[self setMessage:@"拖动规则已保存。点击任一分屏布局即可生效。"];
    else if([self.profile[@"preventDrag"] boolValue] && self.dragGuard.running)
        [self setMessage:@"已阻止分区窗口的标题栏拖动，内容区仍可拖拽；选「自由模式」可自由移动。"];
    else if(![self.profile[@"preventDrag"] boolValue])[self setMessage:@"可拖动窗口标题栏到其他分区：空格迁移，有窗口则交换；固定格不能被替换。"];
}
- (void)toggleDragMode:(id)sender {
    self.profile[@"preventDrag"]=@(![self.profile[@"preventDrag"] boolValue]);
    [self saveConfig];[self syncDragGuard:YES];[self refreshControls];
    if(!AXIsProcessTrusted())[self requirePermission];
}
- (void)refreshDragTargets {
    if(!self.dragGuard.running || !self.locked || _placement.switching || ![self.profile[@"preventDrag"] boolValue] ||
       !FSScreenWithID(self.profile[@"display"]) || !AXIsProcessTrusted()) {self.dragGuard.targets=@[];return;}
    NSArray *visible=FSOnScreenRows();NSMutableArray *targets=[NSMutableArray new];
    for(int i=0;i<self.zoneCount;i++) {
        FSWindow *window=self.runtime[@(i)];FSRect frame;
        if(!window || [self.suspended containsIndex:i] || ![window isUsable] ||
           ![window readFrame:&frame] || ![window isOnScreen:visible])continue;
        FSDragTarget *target=[FSDragTarget new];target.window=window;target.frame=frame;[targets addObject:target];
    }
    self.dragGuard.targets=targets;
}
- (void)syncDragGuard:(BOOL)retry {
    if(!self.locked || _placement.switching || ![self.profile[@"preventDrag"] boolValue] || !AXIsProcessTrusted() ||
       !FSScreenWithID(self.profile[@"display"])) {
        self.dragGuard.targets=@[];
        /* Finish a swallowed mouse sequence before removing the event tap. */
        if(!CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft))[self.dragGuard stop];
    } else if(!self.dragGuard.running && (retry || !self.dragGuard.faulted)) {
        NSString *error=nil;
        if(![self.dragGuard start:&error])[self setMessage:[NSString stringWithFormat:@"禁止拖动未生效：%@。当前使用松手回位。",error]];
    }
    [self refreshDragTargets];[self updateStatus];
}

- (void)changedGeometry {
    [self cancelActivation];
    [self resetTracking:NO];[self saveConfig];[self refreshControls];
    self.quietUntil=NSDate.timeIntervalSinceReferenceDate+.65;
    [self setMessage:self.locked?@"布局已保存，松开鼠标后应用新尺寸。":@"布局已保存。当前为自由模式，点「启用当前布局」开始分屏。"];
}
- (void)layoutChanged:(NSPopUpButton *)sender {
    if(self.refreshing)return;
    if(![self requirePermission]){[self refreshControls];return;}
    self.profile[@"layout"]=@(sender.indexOfSelectedItem);[self activateCurrentLayout:YES];
}
- (void)screenChanged:(NSPopUpButton *)sender {if(self.refreshing)return;self.profile[@"display"]=sender.selectedItem.representedObject;[self changedGeometry];}
- (void)ratioChanged:(NSSlider *)sender {if(self.refreshing)return;self.profile[@"ratio"]=@(round(sender.doubleValue)/100.0);[self changedGeometry];}
- (void)gapChanged:(NSSlider *)sender {if(self.refreshing)return;self.profile[@"gap"]=@(round(sender.doubleValue));[self changedGeometry];}
- (void)switchProfile:(NSString *)identifier {
    if(![self requirePermission]){[self refreshControls];return;}
    BOOL found=NO;for(NSDictionary *p in self.config[@"profiles"])if([p[@"id"] isEqual:identifier]){found=YES;break;}
    if(!found)return;
    NSMutableDictionary *owners=[NSMutableDictionary new];
    for(int i=0;i<4;i++)if([self slotPinned:i] && ![self.borrowedSlots containsIndex:i] && self.runtime[@(i)])
        owners[@(i)]=self.runtime[@(i)];
    self.ownerCache[self.profile[@"id"]]=owners;
    [self cancelActivation];[self resetTracking:YES];
    self.config[@"active"]=identifier;
    /* Only owner identity is cached. Borrowed occupants must be reallocated. */
    self.runtime=[self.ownerCache[identifier] mutableCopy]?:[NSMutableDictionary new];
    _placement.lastSlot=0;self.locked=YES;
    [self saveConfig];
    if(!FSScreenWithID(self.profile[@"display"])) {
        [self setMessage:@"方案已选择，目标显示器未连接。请连接显示器或选择当前屏幕。"];
        [self syncDragGuard:NO];[self refreshControls];return;
    }
    [self activateCurrentLayout:YES];
}
- (void)profileChanged:(NSPopUpButton *)sender {if(!self.refreshing)[self switchProfile:sender.selectedItem.representedObject];}
- (void)profileFromMenu:(NSMenuItem *)sender {
    if(![self requirePermission])return;
    self.locked=YES;[self switchProfile:sender.representedObject];
}
- (NSString *)askName:(NSString *)title initial:(NSString *)initial {
    [self cancelActivation];[self finishPicking];
    NSAlert *alert=[NSAlert new];alert.messageText=title;alert.informativeText=@"例如：剪辑、写作、浏览器＋文件夹。";
    NSTextField *input=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,280,26)];input.stringValue=initial;
    alert.accessoryView=input;[alert addButtonWithTitle:@"保存"];[alert addButtonWithTitle:@"取消"];
    [NSApp activateIgnoringOtherApps:YES];[alert.window setInitialFirstResponder:input];
    if([alert runModal]!=NSAlertFirstButtonReturn)return nil;
    NSString *name=[input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length?[name substringToIndex:MIN((NSUInteger)48,name.length)]:nil;
}
- (void)duplicateProfile:(id)sender {
    NSString *name=[self askName:@"另存为新的布局方案" initial:[self.profile[@"name"] stringByAppendingString:@" 副本"]];if(!name)return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:self.profile options:0 error:nil];
    NSMutableDictionary *p=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    p[@"id"]=NSUUID.UUID.UUIDString;p[@"name"]=name;[self.config[@"profiles"] addObject:p];
    self.config[@"active"]=p[@"id"];
    for(int slot=0;slot<4;slot++)[self rememberAssignment:self.runtime[@(slot)] slot:slot];
    [self saveConfig];[self refreshControls];[self setMessage:@"已另存为新方案，当前窗口位置和模式保持不变。"];
}
- (void)renameProfile:(id)sender {NSString *name=[self askName:@"重命名方案" initial:self.profile[@"name"]];if(name){self.profile[@"name"]=name;[self saveConfig];[self refreshControls];}}
- (void)deleteProfile:(id)sender {
    [self cancelActivation];[self finishPicking];
    NSMutableArray *profiles=self.config[@"profiles"];
    if(profiles.count<=1){[self setMessage:@"至少保留一个布局方案。可以直接修改当前方案。"];return;}
    NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:@"删除方案「%@」？",self.profile[@"name"]];
    alert.informativeText=@"仅删除这个布局方案，应用窗口不会关闭。";[alert addButtonWithTitle:@"删除"];[alert addButtonWithTitle:@"取消"];
    if([alert runModal]!=NSAlertFirstButtonReturn)return;
    NSString *removed=self.profile[@"id"];
    [profiles removeObject:self.profile];[self.histories removeObjectForKey:removed];
    [self.ownerCache removeObjectForKey:removed];
    self.config[@"active"]=profiles.firstObject[@"id"];
    [self resetTracking:YES];self.runtime=[NSMutableDictionary new];
    [self unlockLayout:nil];[self refreshWindowList:nil];
    [self setMessage:@"方案已删除，已回到自由模式。选择布局即可重新开始。"];
}

- (BOOL)bindWindow:(FSWindow *)window slot:(NSInteger)slot {
    if(slot<0 || slot>=self.zoneCount)return NO;
    if(!window && [self slotPinned:slot]) {
        [self setMessage:[NSString stringWithFormat:@"区域 %ld 仍固定给 %@。要清空此固定目标，请先点「已固定 · 可取消」。",
            (long)slot+1,FSProfilePin(self.profile,slot)[@"app"]]];
        [self refreshControls];return NO;
    }
    NSDictionary *pin=FSProfilePin(self.profile,slot);
    BOOL sameOwner=window && [window.bundleID isEqual:pin[@"bundle"]] &&
        ((window.document.length && [window.document isEqual:pin[@"document"]]) ||
         [window.title isEqual:pin[@"title"]] ||
         (![self.borrowedSlots containsIndex:slot] && [window sameWindow:self.runtime[@(slot)]]));
    if(window && [self slotPinned:slot] && !sameOwner) {
        NSAlert *alert=[NSAlert new];
        alert.messageText=[NSString stringWithFormat:@"替换区域 %ld 的固定窗口？",(long)slot+1];
        alert.informativeText=[NSString stringWithFormat:@"当前固定给 %@。确认后才会改为 %@。",pin[@"app"],window.appName];
        [alert addButtonWithTitle:@"替换固定目标"];
        [alert addButtonWithTitle:@"取消"];
        if([alert runModal]!=NSAlertFirstButtonReturn){[self refreshControls];return NO;}
    }
    NSInteger previousOwner=-1;
    if(window)for(int i=0;i<4;i++)if(i!=slot && [self slotPinned:i] &&
        ![self.borrowedSlots containsIndex:i] && [window sameWindow:self.runtime[@(i)]]) {
        previousOwner=i;break;
    }
    BOOL destinationPinned=[self slotPinned:slot];
    [self cancelActivation];[self storeWindow:window slot:slot manual:YES];_placement.lastSlot=(int)slot;
    if(previousOwner>=0)FSProfileSetPin(self.profile,previousOwner,@{});
    if(window && (destinationPinned || previousOwner>=0))
        FSProfileSetPin(self.profile,slot,FSWindowBinding(window));
    [self resetTracking:NO];[self saveConfig];
    if(self.locked && window)[self arrangeSlot:slot manual:YES];
    [self refreshControls];[self syncDragGuard:YES];
    if(![self.suspended containsIndex:slot])[self setMessage:window?[NSString stringWithFormat:@"%@ 已放入区域 %ld。%@",window.appName,(long)slot+1,self.locked?@"":@"自由模式中只保存选择，尚未移动。"]:@"分区已清空，原窗口仍然打开。"];
    return YES;
}
- (void)togglePin:(NSButton *)sender {
    if(self.refreshing || sender.tag<0 || sender.tag>=self.zoneCount)return;
    BOOL pinned=sender.state==NSControlStateValueOn;
    NSDictionary *candidate=self.runtime[@(sender.tag)]?FSWindowBinding(self.runtime[@(sender.tag)]):
                            FSProfileOccupant(self.profile,sender.tag);
    if(pinned && ![candidate[@"bundle"] length]) {
        [self setMessage:@"请先在该分区选择一个窗口，再点「固定此窗口」。"];
        [self refreshControls];return;
    }
    NSString *name=pinned?candidate[@"app"]:FSProfilePin(self.profile,sender.tag)[@"app"];
    FSProfileSetPin(self.profile,sender.tag,pinned?candidate:@{});
    [self.borrowedSlots removeIndex:sender.tag];
    [self resetTracking:NO];[self saveConfig];[self refreshControls];
    [self setMessage:pinned?
      [NSString stringWithFormat:@"%@ 固定在区域 %ld；它暂时不在时，其他窗口可临时补位。",name,(long)sender.tag+1]:
      [NSString stringWithFormat:@"区域 %ld 的 %@ 已取消固定；新窗口可以自动进入。",(long)sender.tag+1,name]];
}
- (void)bindingChanged:(NSPopUpButton *)sender {
    if(self.refreshing)return;
    id value=sender.selectedItem.representedObject;
    if([value isKindOfClass:FSWindow.class])[self bindWindow:value slot:sender.tag];
    else if(!value)[self bindWindow:nil slot:sender.tag];
}
- (void)bindFromMenu:(NSMenuItem *)sender {[self bindFocusedSlot:[sender.representedObject integerValue]];}
- (void)pinFocusedSlot:(NSMenuItem *)sender {
    NSInteger slot=[sender.representedObject integerValue];
    if(slot<0 || slot>=self.zoneCount || ![self requirePermission])return;
    pid_t pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    FSWindow *window=FSFocusedWindow(pid==getpid()?self.lastExternalPID:pid);
    if(!window){[self setMessage:@"先点击要固定的普通窗口，再打开菜单选择固定位置。"];NSBeep();return;}
    if(![self bindWindow:window slot:slot])return;
    FSProfileSetPin(self.profile,slot,FSWindowBinding(window));[self saveConfig];[self refreshControls];
    [self setMessage:[NSString stringWithFormat:@"已将 %@ 固定在区域 %ld；暂时关闭时允许其他窗口临时补位。",window.appName,(long)slot+1]];
}
- (void)unpinFromMenu:(NSMenuItem *)sender {
    NSInteger slot=[sender.representedObject integerValue];
    if(slot<0 || slot>=self.zoneCount)return;
    FSProfileSetPin(self.profile,slot,@{});
    [self.borrowedSlots removeIndex:slot];
    [self saveConfig];[self refreshControls];
    [self setMessage:[NSString stringWithFormat:@"区域 %ld 已取消固定。",(long)slot+1]];
}
- (void)bindFocusedSlot:(NSInteger)slot {
    if(slot>=self.zoneCount){[self setMessage:@"当前布局没有这个区域，请先在设置中切换布局。"];NSBeep();return;}
    if(![self requirePermission])return;
    pid_t pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    FSWindow *window=FSFocusedWindow(pid==getpid()?self.lastExternalPID:pid);
    if(!window){[self setMessage:@"未找到可调整的当前窗口。请先点击一个普通窗口，再按 ⌃⌥1–4 选择它。"];NSBeep();return;}
    [self bindWindow:window slot:slot];
}

- (void)resolveBindings:(BOOL)force {[self resolveBindings:force available:nil];}
- (void)resolveBindings:(BOOL)force available:(NSArray<FSWindow *> *)available {
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    BOOL missing=NO;
    for(int i=0;i<self.zoneCount;i++) {
        FSWindow *w=self.runtime[@(i)];FSRect r;
        if(w && (![w readFrame:&r] || ![NSRunningApplication runningApplicationWithProcessIdentifier:w.pid])) {
            [self.runtime removeObjectForKey:@(i)];[self.borrowedSlots removeIndex:i];
        }
        if(!self.runtime[@(i)] || ([self slotPinned:i] && [self.borrowedSlots containsIndex:i]))missing=YES;
    }
    if(!force && (!missing || now-self.lastResolve<4))return;
    self.lastResolve=now;
    NSArray<FSWindow *> *visible=FSAvailableWindows();
    NSMutableSet<NSString *> *bundles=[NSMutableSet new];
    for(int i=0;i<4;i++) {
        NSString *saved=FSProfileOccupant(self.profile,i)[@"bundle"];
        NSString *fixed=FSProfilePin(self.profile,i)[@"bundle"];
        if(saved.length)[bundles addObject:saved];
        if(fixed.length)[bundles addObject:fixed];
    }
    NSMutableArray<FSWindow *> *windows=[visible mutableCopy];
    for(FSWindow *w in (available?:FSRestorableWindows(bundles))) {
        BOOL seen=NO;for(FSWindow *other in windows)if([w sameWindow:other]){seen=YES;break;}
        if(!seen)[windows addObject:w];
    }
    NSDictionary<NSNumber *,FSWindow *> *previous=[self.runtime copy];
    for(FSWindow *w in previous.allValues)if([w isRestorable]) {
        BOOL seen=NO;for(FSWindow *other in windows)if([w sameWindow:other]){seen=YES;break;}
        if(!seen)[windows addObject:w];
    }
    FSBindingCandidate *candidates=calloc(MAX((NSUInteger)1,windows.count),sizeof(*candidates));
    if(!candidates)return;
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);
    for(NSUInteger index=0;index<windows.count;index++) {
        FSWindow *w=windows[index];FSRect frame;
        BOOL onTarget=index<visible.count && screen && [w isUsable] &&
                      [w readFrame:&frame] && FSScreenForFrame(frame)==screen;
        candidates[index]=(FSBindingCandidate){.bundle=w.bundleID.UTF8String,.title=w.title.UTF8String,
            .document=w.document.UTF8String,.restorable=[w isRestorable],.visibleOnTarget=onTarget};
        for(int hidden=self.zoneCount;hidden<4;hidden++)if([self slotPinned:hidden] &&
            [w sameWindow:previous[@(hidden)]])candidates[index].used=true;
    }
    FSBindingSlot slots[4]={0};
    for(int i=0;i<self.zoneCount;i++) {
        NSDictionary *b=[self slotPinned:i]?FSProfilePin(self.profile,i):FSProfileOccupant(self.profile,i);
        int previousIndex=-1;
        for(NSUInteger index=0;index<windows.count;index++)if([previous[@(i)] sameWindow:windows[index]]) {
            previousIndex=(int)index;break;
        }
        slots[i]=(FSBindingSlot){.bundle=[b[@"bundle"] UTF8String],.title=[b[@"title"] UTF8String],
            .document=[b[@"document"] UTF8String],.previous=previousIndex,
            .pinned=[self slotPinned:i],.borrowed=[self.borrowedSlots containsIndex:i]};
    }
    int indices[4];unsigned owners=FSBindingPlan(slots,self.zoneCount,candidates,windows.count,indices);
    free(candidates);
    NSMutableDictionary<NSNumber *,FSWindow *> *next=[NSMutableDictionary new];
    for(int i=0;i<self.zoneCount;i++)if(indices[i]>=0) {
        FSWindow *chosen=windows[indices[i]];next[@(i)]=chosen;[self rememberAssignment:chosen slot:i];
    }
    BOOL assignmentsChanged=NO;
    for(int i=0;i<self.zoneCount;i++)if(![previous[@(i)] sameWindow:next[@(i)]] &&
                                         (previous[@(i)] || next[@(i)]))assignmentsChanged=YES;
    if(assignmentsChanged) {
        /* A previous occupant's delayed move verification must not suspend
           the new owner of this slot. */
        self.epoch++;[self.pending removeAllIndexes];[self.suspended removeAllIndexes];
        [self.failures removeAllObjects];[self.targets removeAllObjects];
    }
    self.runtime=next;[self.borrowedSlots removeAllIndexes];
    BOOL changed=NO;
    for(int i=0;i<self.zoneCount;i++) {
        FSWindow *w=next[@(i)];if(!w)continue;
        if([self slotPinned:i] && !(owners & (1u<<i)))[self.borrowedSlots addIndex:i];
        NSMutableDictionary *replacement=FSWindowBinding(w);
        if(![replacement isEqual:FSProfileOccupant(self.profile,i)]) {
            FSProfileSetOccupant(self.profile,i,replacement);changed=YES;
        }
    }
    if(changed)[self saveConfig];
}
- (void)rememberOriginal:(FSWindow *)window frame:(FSRect)frame {
    for(FSRestore *r in self.originals)if([r.window sameWindow:window])return;
    FSRestore *r=[FSRestore new];r.window=window;r.frame=frame;[self.originals addObject:r];
}
- (void)arrangeSlot:(NSInteger)slot manual:(BOOL)manual {
    if(!AXIsProcessTrusted())return;
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);if(!screen)return;
    FSRect zones[4];int count=FSBuildZones([self.profile[@"layout"] intValue],FSUsableFrame(screen),[self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones);
    if(slot<0 || slot>=count)return;
    [self resolveBindings:manual];
    [self moveSlot:slot to:zones[slot] visible:FSOnScreenRows() manual:manual];
}
- (BOOL)moveSlot:(NSInteger)slot to:(FSRect)target visible:(NSArray *)visible manual:(BOOL)manual {
    if([self.pending containsIndex:slot] || (!manual && [self.suspended containsIndex:slot]))return NO;
    FSWindow *window=self.runtime[@(slot)];FSRect current;
    if(!window || ![window isUsable] || ![window readFrame:&current])return NO;
    /* Explicit layout activation can restore a saved window even when the
       WindowServer snapshot has stale bounds. In background maintenance,
       accept the focused window as proof of presence on the current desktop. */
    if(!manual && ![window isOnScreen:visible] && ![window isFocusedInFrontmostApp])return NO;
    if(FSRectNear(current,target,3))return YES;
    if(self.targets[@(slot)] && !FSRectNear(fsrect(self.targets[@(slot)].rectValue),target,1))self.failures[@(slot)]=@0;
    self.targets[@(slot)]=[NSValue valueWithRect:nsrect(target)];
    [self rememberOriginal:window frame:current];
    NSString *error=nil;
    if(![window moveTo:target error:&error]) {
        [self.suspended addIndex:slot];[self setMessage:[NSString stringWithFormat:@"区域 %ld：%@；已暂停此窗口的自动调整。",(long)slot+1,error]];return NO;
    }
    [self.pending addIndex:slot];
    NSUInteger epoch=self.epoch;
    __weak FSApp *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.55*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        FSApp *app=weakSelf;if(!app || app.epoch!=epoch)return;
        [app.pending removeIndex:slot];FSRect actual;
        if(CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft) ||
           NSEvent.pressedMouseButtons!=0)return; /* Let the next maintenance pass retry after dragging. */
        if(![window readFrame:&actual]) {
            [app.suspended addIndex:slot];
            [app setMessage:[NSString stringWithFormat:@"区域 %ld：%@ 的位置暂时无法读取；点击布局重试。",(long)slot+1,window.appName]];
            return;
        }
        if(FSRectNear(actual,target,4)) {
            app.failures[@(slot)]=@0;
            if([app.observedWindow sameWindow:window] && [app.statusText containsString:@"正在确认位置"])
                [app setMessage:[NSString stringWithFormat:@"%@ → 区域 %ld · 已确认到位。",window.appName,(long)slot+1]];
            return;
        }
        int attempts=[app.failures[@(slot)] intValue]+1;app.failures[@(slot)]=@(attempts);
        if(attempts>=2 || !app.locked) {
            [app.suspended addIndex:slot];
            [app refreshDragTargets];
            [app setMessage:[NSString stringWithFormat:@"区域 %ld：%@ 未达到目标位置/尺寸（目标 %.0f,%.0f %.0f×%.0f；实际 %.0f,%.0f %.0f×%.0f）。已暂停自动调整；请检查窗口限制，或点击布局重试。",
                (long)slot+1,window.appName,target.x,target.y,target.width,target.height,
                actual.x,actual.y,actual.width,actual.height]];
        }
    });
    return YES;
}
- (void)applyLayout:(BOOL)manual {
    if(!manual && !self.locked)return;
    if(!AXIsProcessTrusted()){if(manual)[self requirePermission];return;}
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);
    if(!screen){self.dragGuard.targets=@[];[self setMessage:@"目标显示器未连接：已暂停该方案的窗口调整。连接显示器或重新选择目标显示器后继续。"];return;}
    FSRect usable=FSUsableFrame(screen),zones[4];
    if(self.lastUsable && !FSRectNear(fsrect(self.lastUsable.rectValue),usable,1))[self resetTracking:NO];
    self.lastUsable=[NSValue valueWithRect:nsrect(usable)];
    int count=FSBuildZones([self.profile[@"layout"] intValue],usable,[self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones);
    [self resolveBindings:manual];NSArray *visible=FSOnScreenRows();
    int bound=0,processed=0;
    for(int i=0;i<count;i++) {
        if(self.profile[@"bindings"][i][@"bundle"])bound++;
        if([self moveSlot:i to:zones[i] visible:visible manual:manual])processed++;
    }
    if(manual && self.suspended.count==0) {
        if(!bound)[self setMessage:self.locked?@"自动分屏已开启，打开或切换目标屏幕上的窗口即可归位。":@"当前为自由模式。点击布局开始分屏。"]; 
        else [self setMessage:[NSString stringWithFormat:@"已向 %d / %d 个存档窗口发送调整或确认请求；正在核对实际位置。%@",processed,bound,self.locked?@"自动归位和固定已开启；选「自由模式」可停止。":@"自由模式中可随意拖动。"]];
    }
    [self refreshDragTargets];
}
- (void)applyNow:(id)sender {[self activateCurrentLayout:YES];}
- (void)fixLayout:(id)sender {[self activateCurrentLayout:YES];}
- (void)unlockLayout:(id)sender {
    /* Always available, even with no permission or an unplugged display. */
    [self cancelActivation];self.locked=NO;[self.focusObserver stop];
    [self resetTracking:NO];[self saveConfig];
    [self setMessage:@"自由模式：已停止自动归位和固定，窗口保留当前位置。点击任一布局可重新开始。"];
    [self syncDragGuard:NO];[self refreshControls];[self updateStatus];
}
- (void)toggleLock:(id)sender {
    if(self.locked)[self unlockLayout:sender];
    else [self fixLayout:sender];
}
- (void)tick:(NSTimer *)timer {
    [self updateStatus];
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    if(self.choosingWindow) {
        if(now>=self.pickingDeadline || !AXIsProcessTrusted()) {
            [self finishPicking];[self updateStatus];[self setMessage:@"点选已结束，原选择未变。"];
        }
        return;
    }
    BOOL trusted=AXIsProcessTrusted();
    if(trusted!=self.lastTrusted && !self.menuOpen && !NSApp.modalWindow) {
        self.lastTrusted=trusted;
        if(!trusted){[self cancelActivation];[self.focusObserver stop];}
        if(self.settingsWindow.visible)[self refreshWindowList:nil];
    }
    if(!self.locked || ![self.profile[@"preventDrag"] boolValue] || !trusted)[self syncDragGuard:NO];
    if(CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft) || NSEvent.pressedMouseButtons!=0){self.lastMouseDown=now;return;}
    if(!self.locked || _placement.switching || self.sleeping || self.sessionInactive || self.menuOpen ||
       NSApp.modalWindow || now<self.quietUntil || now-self.lastMouseDown<.3 || !trusted)return;
    [self captureActiveWindow];
    if(now-self.lastMaintenance>=.85) {
        self.lastMaintenance=now;[self applyLayout:NO];
        if([self.profile[@"preventDrag"] boolValue] && !self.dragGuard.running && !self.dragGuard.faulted)[self syncDragGuard:NO];
    }
}
- (void)restoreOriginals:(id)sender {
    [self unlockLayout:nil];
    if(![self requirePermission])return;
    NSArray *visible=FSOnScreenRows();NSMutableArray *remaining=[NSMutableArray new];int restored=0;
    for(FSRestore *entry in self.originals) {
        FSRect f;if(![entry.window readFrame:&f])continue;
        if(![entry.window isUsable] || ![entry.window isOnScreen:visible]){[remaining addObject:entry];continue;}
        NSString *error=nil;
        if([entry.window moveTo:entry.frame error:&error])restored++;
        else [remaining addObject:entry];
    }
    self.originals=remaining;
    [self setMessage:[NSString stringWithFormat:@"已进入自由模式，已向 %d 个窗口发送恢复请求。%lu 个暂不可用的窗口可稍后再恢复。",restored,(unsigned long)remaining.count]];
    [self updateStatus];
}
- (BOOL)requirePermission {
    if(AXIsProcessTrusted())return YES;
    /* Called only by an explicit user command. A new install path has a new
       authorization decision; surface that decision instead of silently
       leaving the old layout active. */
    if(!self.permissionPromptShown) {
        self.permissionPromptShown=YES;
        NSDictionary *options=@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
    [self setMessage:[NSString stringWithFormat:@"当前这份定屏未获辅助功能授权：%@。请在系统设置中添加此路径并开启开关。",NSBundle.mainBundle.bundlePath]];
    [self updateStatus];
    [self showSettings:nil];
    return NO;
}
- (void)openPermission:(id)sender {
    [self cancelActivation];
    [self finishPicking];
    /* Only an explicit menu/button action reaches this method. Open one surface. */
    BOOL opened=[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    [self setMessage:opened?@"请为当前这份定屏开启辅助功能。列表中没有时，用 + 添加「权限诊断」显示的应用路径；完成后返回并点击「更新窗口列表」。":@"未能打开设置。请手动前往「系统设置 → 隐私与安全性 → 辅助功能」。"];
}
- (void)repairOldPermission:(id)sender {
    if(AXIsProcessTrusted()) {
        [self setMessage:@"当前进程已经获得辅助功能授权，无需移除现有授权。"];
        return;
    }
    [self cancelActivation];[self finishPicking];
    NSURL *tool=[NSBundle.mainBundle URLForResource:@"修复定屏授权" withExtension:@"command"];
    if(!tool) {
        [self setMessage:@"应用中缺少授权修复工具。请使用最新 DMG「高级安装」内的授权修复工具。"];
        return;
    }
    if([NSWorkspace.sharedWorkspace openURL:tool]) {
        [NSApp terminate:nil];
    } else {
        [self setMessage:@"未能打开授权修复工具。请使用 DMG「高级安装」内的授权修复工具。"];
    }
}
- (void)revealCurrentApp:(id)sender {
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[NSBundle.mainBundle.bundleURL]];
}
- (void)showPermissionDiagnostics:(id)sender {
    /* Opening a status menu is a read-only action. Give the target app its
       normal mouse-up frame update before reporting this drag's result. */
    if(_postDrag.pending && NSDate.timeIntervalSinceReferenceDate<self.pendingDropReadyAt) {
        NSTimeInterval delay=self.pendingDropReadyAt-NSDate.timeIntervalSinceReferenceDate+.02;
        __weak FSApp *weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            [weakSelf showPermissionDiagnostics:nil];
        });
        return;
    }
    if(_postDrag.pending)[self completePendingDrop:_postDrag.token];
    [self cancelActivation];
    [self finishPicking];
    BOOL trusted=AXIsProcessTrusted();
    if(trusted && self.locked)[self resolveBindings:YES];
    NSBundle *bundle=NSBundle.mainBundle;
    NSArray *rows=FSOnScreenRows();NSUInteger ordinaryRows=0;
    for(NSDictionary *row in rows)if([row[(__bridge NSString *)kCGWindowLayer] intValue]==0 &&
        [row[(__bridge NSString *)kCGWindowOwnerPID] intValue]!=getpid())ordinaryRows++;
    NSArray<FSWindow *> *available=trusted?FSAvailableWindows():@[];
    pid_t lastPID=self.lastExternalPID;
    FSWindow *focused=trusted?FSFocusedWindow(lastPID):nil;
    NSString *focusDetail=trusted?FSFocusedWindowDiagnostic(lastPID):@"需要辅助功能授权";
    NSScreen *screen=FSScreenWithID(self.profile[@"display"]);
    NSString *screenState=screen?@"已连接":@"保存的显示器未找到";
    NSUInteger availableOnTarget=0;
    for(FSWindow *candidate in available) {
        FSRect frame;
        if(screen && [candidate readFrame:&frame] && FSScreenForFrame(frame)==screen)availableOnTarget++;
    }
    FSRect zones[4]={0};
    int zoneCount=screen?FSBuildZones([self.profile[@"layout"] intValue],FSUsableFrame(screen),
        [self.profile[@"ratio"] doubleValue],[self.profile[@"gap"] doubleValue],zones):0;
    NSMutableSet *pinBundles=[NSMutableSet new];NSUInteger fixedCount=0;
    for(int i=0;i<self.zoneCount;i++)if([self slotPinned:i])
        {[pinBundles addObject:FSProfilePin(self.profile,i)[@"bundle"]];fixedCount++;}
    NSArray<FSWindow *> *pinCandidates=trusted?FSRestorableWindows(pinBundles):@[];
    NSMutableArray<NSString *> *zoneLines=[NSMutableArray new];NSUInteger resolved=0;
    for(int i=0;i<self.zoneCount;i++) {
        NSDictionary *binding=FSProfileOccupant(self.profile,i);
        NSDictionary *fixed=FSProfilePin(self.profile,i);
        FSWindow *window=self.runtime[@(i)];
        NSString *saved=[fixed[@"app"] length]?fixed[@"app"]:([binding[@"app"] length]?binding[@"app"]:@"空");
        BOOL borrowed=[self.borrowedSlots containsIndex:i];
        NSString *pin=[self slotPinned:i]?(borrowed?@"固定目标缺席 · 临时补位":@"固定"):@"可补位";
        if(!window || ![window isRestorable]) {
            NSUInteger candidates=0;
            for(FSWindow *candidate in pinCandidates)if([candidate.bundleID isEqual:fixed[@"bundle"]])candidates++;
            NSString *detail=[self slotPinned:i]?(candidates>1?
                [NSString stringWithFormat:@"该应用有 %lu 个普通窗口，标题或文档均无法唯一识别；请重新选择要固定的窗口",(unsigned long)candidates]:
                (candidates==0?@"该应用当前没有可恢复的普通窗口":@"候选窗口正在恢复，请再点一次布局")):
                @"当前没有匹配的窗口";
            [zoneLines addObject:[NSString stringWithFormat:@"%d %@（%@）：%@",i+1,saved,pin,detail]];
            continue;
        }
        resolved++;
        FSRect actual={0};BOOL readable=[window readFrame:&actual];
        NSString *state=[self.suspended containsIndex:i]?@"已暂停":
            ([self.pending containsIndex:i]?@"等待确认":
             (readable && i<zoneCount && FSRectNear(actual,zones[i],4)?@"已到位":
              ([window isOnScreen:rows] || [window isFocusedInFrontmostApp]?@"未到位":@"当前桌面不可见")));
        NSString *coordinates=readable && i<zoneCount?
            [NSString stringWithFormat:@"目标 %.0f,%.0f %.0f×%.0f；实际 %.0f,%.0f %.0f×%.0f",
                zones[i].x,zones[i].y,zones[i].width,zones[i].height,
                actual.x,actual.y,actual.width,actual.height]:@"坐标不可读";
        NSString *occupant=borrowed?[NSString stringWithFormat:@"当前 %@；固定目标 %@",window.appName,saved]:window.appName;
        [zoneLines addObject:[NSString stringWithFormat:@"%d %@（%@）：%@；%@",i+1,occupant,pin,state,coordinates]];
    }
    NSString *dragStatus=!self.locked?@"自由模式下不换位":
        ([self.profile[@"preventDrag"] boolValue]?@"当前选择阻止标题栏拖动；改为「拖到分区换位」后再试":
         (self.lastDragResult?:@"尚无记录"));
    NSString *diagnostic=[NSString stringWithFormat:
        @"版本：%@（构建 %@）\n当前进程：%d\n辅助功能检测：%@\n当前模式：%@；目标显示器：%@\n窗口识别：屏幕普通窗口 %lu；可调整窗口 %lu；目标屏可用 %lu；最近活动窗口 %@\n最近窗口检查：%@\n当前布局：存档 %ld；固定目标 %lu；临时补位 %lu；找到 %lu；等待确认 %lu；已暂停 %lu；鼠标监听 %@\n分区实际位置：\n%@\n拖动规则：%@；拦截器 %@\n最近状态：%@\n拖动诊断：%@\n应用标识：%@\n正在运行的应用：\n%@\n\n%@",
        FSVersion,[bundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"未知",getpid(),
        trusted?@"已授权":@"未授权",self.locked?@"自动分屏":@"自由模式",screenState,
        (unsigned long)ordinaryRows,(unsigned long)available.count,(unsigned long)availableOnTarget,
        focused?[focused label]:@"未识别",focusDetail,
        (long)self.boundCount,(unsigned long)fixedCount,(unsigned long)self.borrowedSlots.count,
        (unsigned long)resolved,(unsigned long)self.pending.count,
        (unsigned long)self.suspended.count,self.inputMonitor?@"正常":@"不可用",
        [zoneLines componentsJoinedByString:@"\n"],
        [self.profile[@"preventDrag"] boolValue]?@"阻止拖动":@"拖放换位",
        ![self.profile[@"preventDrag"] boolValue]?@"不适用":
            (self.dragGuard.running?@"运行中":(self.dragGuard.faulted?@"已暂停":@"未启用")),
        self.statusText?:@"无",dragStatus,bundle.bundleIdentifier?:@"未知",bundle.bundlePath,
        trusted?@"当前进程已获得授权。如果窗口仍无法调整，请刷新窗口，并检查目标窗口是否全屏、最小化或受最小尺寸限制。":
        @"若系统开关已经开启，可能对应旧版本或其他副本。请点「修复旧版授权」：工具会退出定屏，核对当前 App，帮助你仅移除旧定屏条目，然后从上方显示的准确路径重新添加并开启。"];
    if([bundle.bundlePath containsString:@"/AppTranslocation/"])
        diagnostic=[diagnostic stringByAppendingString:@"\n\n当前正在运行 DMG 隔离的临时副本。请退出，运行下载的 .pkg，或双击 DMG 内的「双击安装定屏.pkg」，再从 /Applications/定屏.app 启动。"];
    NSAlert *alert=[NSAlert new];alert.messageText=@"定屏 · 权限诊断";alert.informativeText=diagnostic;
    [alert addButtonWithTitle:@"关闭"];[alert addButtonWithTitle:@"在 Finder 中显示"];[alert addButtonWithTitle:@"复制诊断"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse result=[alert runModal];
    if(result==NSAlertSecondButtonReturn)[self revealCurrentApp:nil];
    else if(result==NSAlertThirdButtonReturn) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:diagnostic forType:NSPasteboardTypeString];
        [self setMessage:@"权限诊断已复制，可粘贴反馈。"];
    }
}
- (void)openConfigFolder:(id)sender {
    [[NSFileManager defaultManager] createDirectoryAtURL:self.configURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:self.configURL.URLByDeletingLastPathComponent];
}
- (void)openLoginSettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]];
    [self setMessage:@"在「通用 → 登录项与扩展」的「登录时打开」中添加「定屏」。"];
}
- (void)showHelp:(id)sender {
    [self cancelActivation];[self finishPicking];
    NSAlert *alert=[NSAlert new];alert.messageText=@"选择模式，窗口自动归位";
    alert.informativeText=[NSString stringWithFormat:@"自由模式\n停止自动归位和位置约束，窗口保留当前位置。⌃⌥⌘0 随时切回。\n\n点击布局图标\n立即启用并排列窗口。空分区从目标屏幕已有窗口中补充；不会自动启动已关闭的应用。\n\n拖动换位\n在自动分屏时，拖动普通窗口的标题栏并把鼠标松在目标分区：窗口开始移动后会显示目标分区边框，当前落点高亮，固定分区标为不可替换。空格迁移，有窗口就交换；选择「阻止标题栏拖动」可关闭换位。\n\n固定指定窗口\n在分区一行选好窗口，勾选「固定此窗口」，或从菜单「将当前窗口固定到…」一步完成。固定分区不会被其他新窗口占用；临时关闭仍保留位置。取消勾选后恢复自动分配。\n\n以后激活窗口\n固定窗口始终回自己的分区。更多设置默认开启「新建窗口优先放入当前活动分区」；关闭后新建窗口先填未固定空位。已有窗口优先回原位；固定分区不会被替换。\n\n更多设置\n可调布局比例、间距、目标显示器及新建窗口去向；拖动规则可在主界面选择。自由模式停止位置约束和标题栏拦截。\n\n恢复分屏前的位置\n进入自由模式并恢复本次启动内记录的位置，不关闭窗口。\n\n只自动接纳目标屏幕、当前桌面的普通可调整窗口；全屏、弹窗、菜单不参与。\n%@",self.hotkeyWarning?:@""];
    [alert addButtonWithTitle:@"知道了"];[alert addButtonWithTitle:@"完整说明"];
    [NSApp activateIgnoringOtherApps:YES];
    if([alert runModal]==NSAlertSecondButtonReturn) {
        NSURL *url=[NSBundle.mainBundle URLForResource:@"使用说明" withExtension:@"md"];
        if(url)[NSWorkspace.sharedWorkspace openURL:url];
    }
}
- (void)quit:(id)sender {[NSApp terminate:nil];}
@end

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        NSApplication *application=NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        static FSApp *delegate;
        delegate=[FSApp new];application.delegate=delegate;
        [application run];
    }
    return 0;
}
