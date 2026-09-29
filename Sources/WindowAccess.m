#import "WindowAccess.h"
#include <math.h>
#include <unistd.h>

static id readAX(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (result != kAXErrorSuccess) { if (value) CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

static BOOL readAXFrame(AXUIElementRef element, FSRect *frame) {
    id position=readAX(element,kAXPositionAttribute), size=readAX(element,kAXSizeAttribute);
    if (!position || !size ||
        CFGetTypeID((__bridge CFTypeRef)position)!=AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)size)!=AXValueGetTypeID()) return NO;
    CGPoint p; CGSize s;
    if (!AXValueGetValue((__bridge AXValueRef)position,kAXValueCGPointType,&p) ||
        !AXValueGetValue((__bridge AXValueRef)size,kAXValueCGSizeType,&s)) return NO;
    *frame=(FSRect){p.x,p.y,s.width,s.height};
    return isfinite(p.x)&&isfinite(p.y)&&isfinite(s.width)&&isfinite(s.height)&&s.width>0&&s.height>0;
}

@implementation FSWindow
- (AXUIElementRef)ax { return (__bridge AXUIElementRef)self.element; }
- (BOOL)readFrame:(FSRect *)frame { return readAXFrame(self.ax,frame); }
- (BOOL)isRestorable {
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:self.pid];
    if (!app || app.terminated || app.activationPolicy!=NSApplicationActivationPolicyRegular ||
        ![app.bundleIdentifier isEqual:self.bundleID]) return NO;
    if (![readAX(self.ax,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]) return NO;
    if (![readAX(self.ax,kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole]) return NO;
    if ([readAX(self.ax,CFSTR("AXFullScreen")) boolValue] || [readAX(self.ax,kAXModalAttribute) boolValue]) return NO;
    id sheets=readAX(self.ax,CFSTR("AXSheets"));
    if([sheets isKindOfClass:NSArray.class] && [sheets count])return NO;
    Boolean movable=false, resizable=false;
    AXUIElementIsAttributeSettable(self.ax,kAXPositionAttribute,&movable);
    AXUIElementIsAttributeSettable(self.ax,kAXSizeAttribute,&resizable);
    FSRect f;
    return movable && resizable && [self readFrame:&f];
}
- (BOOL)isUsable {
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:self.pid];
    return !app.hidden && ![readAX(self.ax,kAXMinimizedAttribute) boolValue] && [self isRestorable];
}
- (BOOL)restoreForLayout {
    if(![self isRestorable])return NO;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:self.pid];
    if(app.hidden && ![app unhide])return NO;
    if([readAX(self.ax,kAXMinimizedAttribute) boolValue])
        return AXUIElementSetAttributeValue(self.ax,kAXMinimizedAttribute,kCFBooleanFalse)==kAXErrorSuccess;
    return YES;
}
- (BOOL)raiseWindow {
    if(![self isUsable])return NO;
    return AXUIElementPerformAction(self.ax,kAXRaiseAction)==kAXErrorSuccess;
}
- (BOOL)focusWindow {
    if(![self isUsable] || ![self isOnScreen:FSOnScreenRows()])return NO;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:self.pid];
    BOOL activated=[app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    AXUIElementRef application=AXUIElementCreateApplication(self.pid);
    AXUIElementSetMessagingTimeout(application,.18);
    AXError front=AXUIElementSetAttributeValue(application,kAXFrontmostAttribute,kCFBooleanTrue);
    AXUIElementSetAttributeValue(self.ax,kAXMainAttribute,kCFBooleanTrue);
    AXUIElementSetAttributeValue(application,kAXFocusedWindowAttribute,self.ax);
    CFRelease(application);
    BOOL raised=[self raiseWindow];
    return raised && (activated || front==kAXErrorSuccess);
}
- (BOOL)isOnScreen:(NSArray<NSDictionary *> *)rows {
    FSRect f;
    if (![self readFrame:&f]) return NO;
    for (NSDictionary *row in rows) {
        if ([row[(__bridge NSString *)kCGWindowOwnerPID] intValue]!=self.pid ||
            [row[(__bridge NSString *)kCGWindowLayer] intValue]!=0) continue;
        CGRect b;
        NSDictionary *bounds=row[(__bridge NSString *)kCGWindowBounds];
        if (bounds && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds,&b) &&
            FSRectNear(f,(FSRect){b.origin.x,b.origin.y,b.size.width,b.size.height},3)) return YES;
    }
    return NO;
}
- (BOOL)moveTo:(FSRect)frame error:(NSString **)error {
    if (![self isUsable]) {
        if(error)*error=@"窗口已关闭、隐藏、最小化、全屏或不支持调整";
        return NO;
    }
    CGPoint p=CGPointMake(frame.x,frame.y);
    CGSize s=CGSizeMake(frame.width,frame.height);
    AXValueRef position=AXValueCreate(kAXValueCGPointType,&p), size=AXValueCreate(kAXValueCGSizeType,&s);
    if (!position || !size) {
        if(position)CFRelease(position); if(size)CFRelease(size);
        if(error)*error=@"无法创建窗口坐标"; return NO;
    }
    /* Resize before moving so a large window can cross to a smaller display.
       Retry size after moving because some apps constrain it to the old screen. */
    AXUIElementSetAttributeValue(self.ax,kAXSizeAttribute,size);
    AXError pe=AXUIElementSetAttributeValue(self.ax,kAXPositionAttribute,position);
    AXError se=AXUIElementSetAttributeValue(self.ax,kAXSizeAttribute,size);
    CFRelease(position); CFRelease(size);
    if(pe!=kAXErrorSuccess || se!=kAXErrorSuccess) {
        if(error)*error=[NSString stringWithFormat:@"应用拒绝调整（位置 %d，尺寸 %d）",pe,se];
        return NO;
    }
    return YES;
}
- (BOOL)sameWindow:(FSWindow *)other {
    return other && self.pid==other.pid && CFEqual((__bridge CFTypeRef)self.element,(__bridge CFTypeRef)other.element);
}
- (NSString *)label {
    NSString *title=self.title.length?self.title:@"无标题窗口";
    if(title.length>65) title=[[title substringToIndex:65] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"%@ — %@",self.appName,title];
}
@end

static FSWindow *makeWindow(AXUIElementRef element, NSRunningApplication *app) {
    if(!app.bundleIdentifier.length) return nil;
    FSWindow *w=[FSWindow new];
    w.element=(__bridge id)element;
    w.pid=app.processIdentifier;
    w.bundleID=app.bundleIdentifier;
    w.appName=app.localizedName?:app.bundleIdentifier;
    id title=readAX(element,kAXTitleAttribute);
    w.title=[title isKindOfClass:NSString.class]?title:@"";
    return w;
}

NSArray<NSDictionary *> *FSOnScreenRows(void) {
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
    return rows?CFBridgingRelease(rows):@[];
}

NSArray<FSWindow *> *FSAvailableWindows(void) {
    if(!AXIsProcessTrusted())return @[];
    NSArray *rows=FSOnScreenRows();
    NSMutableSet *seen=[NSMutableSet new];
    NSMutableArray *result=[NSMutableArray new];
    for(NSDictionary *row in rows) {
        NSNumber *pid=row[(__bridge NSString *)kCGWindowOwnerPID];
        if(!pid || [seen containsObject:pid] || pid.intValue==getpid())continue;
        [seen addObject:pid];
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
        if(!app || app.activationPolicy!=NSApplicationActivationPolicyRegular || app.hidden)continue;
        AXUIElementRef axApp=AXUIElementCreateApplication(pid.intValue);
        AXUIElementSetMessagingTimeout(axApp,.18);
        id windows=readAX(axApp,kAXWindowsAttribute);
        if([windows isKindOfClass:NSArray.class]) for(id element in windows) {
            if(CFGetTypeID((__bridge CFTypeRef)element)!=AXUIElementGetTypeID())continue;
            AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)element,.18);
            FSWindow *w=makeWindow((__bridge AXUIElementRef)element,app);
            if(w && [w isUsable] && [w isOnScreen:rows]) [result addObject:w];
        }
        CFRelease(axApp);
    }
    return result;
}

NSArray<FSWindow *> *FSRestorableWindows(NSSet<NSString *> *bundleIDs) {
    if(!AXIsProcessTrusted() || !bundleIDs.count)return @[];
    NSMutableArray *result=[NSMutableArray new];
    for(NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if(app.processIdentifier==getpid() || app.activationPolicy!=NSApplicationActivationPolicyRegular ||
           !app.bundleIdentifier || ![bundleIDs containsObject:app.bundleIdentifier])continue;
        AXUIElementRef axApp=AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(axApp,.18);
        id windows=readAX(axApp,kAXWindowsAttribute);
        if([windows isKindOfClass:NSArray.class])for(id element in windows) {
            if(CFGetTypeID((__bridge CFTypeRef)element)!=AXUIElementGetTypeID())continue;
            AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)element,.18);
            FSWindow *window=makeWindow((__bridge AXUIElementRef)element,app);
            if(window && [window isRestorable])[result addObject:window];
        }
        CFRelease(axApp);
    }
    return result;
}

FSWindow *FSFocusedWindow(pid_t pid) {
    if(!AXIsProcessTrusted() || pid<=0 || pid==getpid())return nil;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(!app || app.terminated)return nil;
    AXUIElementRef axApp=AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(axApp,.18);
    id focused=readAX(axApp,kAXFocusedWindowAttribute);
    CFRelease(axApp);
    if(!focused || CFGetTypeID((__bridge CFTypeRef)focused)!=AXUIElementGetTypeID())return nil;
    AXUIElementRef element=(__bridge AXUIElementRef)focused;
    AXUIElementSetMessagingTimeout(element,.18);
    FSWindow *w=makeWindow(element,app);
    return w && [w isUsable] && [w isOnScreen:FSOnScreenRows()]?w:nil;
}

NSString *FSDisplayID(NSScreen *screen) {
    CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display);
    if(!uuid)return [NSString stringWithFormat:@"display-%u",display];
    NSString *identifier=CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault,uuid));
    CFRelease(uuid); return identifier;
}

FSWindow *FSWindowAtPoint(CGPoint point) {
    if(!AXIsProcessTrusted())return nil;
    AXUIElementRef system=AXUIElementCreateSystemWide(),hit=NULL;
    AXUIElementSetMessagingTimeout(system,.18);
    AXError result=AXUIElementCopyElementAtPosition(system,point.x,point.y,&hit);
    CFRelease(system);
    if(result!=kAXErrorSuccess || !hit){if(hit)CFRelease(hit);return nil;}
    AXUIElementSetMessagingTimeout(hit,.18);
    id element=[readAX(hit,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]?(__bridge id)hit:readAX(hit,kAXWindowAttribute);
    FSWindow *window=nil;
    if(element && CFGetTypeID((__bridge CFTypeRef)element)==AXUIElementGetTypeID()) {
        AXUIElementRef ax=(__bridge AXUIElementRef)element;
        AXUIElementSetMessagingTimeout(ax,.18);
        pid_t pid=0;
        if(AXUIElementGetPid(ax,&pid)==kAXErrorSuccess && pid>0 && pid!=getpid()) {
            NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            if(app.activationPolicy==NSApplicationActivationPolicyRegular)window=makeWindow(ax,app);
        }
    }
    CFRelease(hit);
    return window && [window isUsable] && [window isOnScreen:FSOnScreenRows()]?window:nil;
}

NSScreen *FSScreenForFrame(FSRect frame) {
    double top=NSMaxY(NSScreen.screens.firstObject.frame),bestArea=0;
    NSScreen *best=nil;
    for(NSScreen *screen in NSScreen.screens) {
        NSRect f=screen.frame;
        FSRect ax=FSCocoaToAX((FSRect){f.origin.x,f.origin.y,f.size.width,f.size.height},top);
        double area=FSIntersectionArea(frame,ax);
        if(area>bestArea){best=screen;bestArea=area;}
    }
    return best;
}

NSScreen *FSScreenWithID(NSString *identifier) {
    for(NSScreen *screen in NSScreen.screens)if([FSDisplayID(screen) isEqual:identifier])return screen;
    return nil;
}

FSRect FSUsableFrame(NSScreen *screen) {
    NSRect r=screen.visibleFrame;
    double top=NSMaxY(NSScreen.screens.firstObject.frame);
    return FSCocoaToAX((FSRect){r.origin.x,r.origin.y,r.size.width,r.size.height},top);
}
