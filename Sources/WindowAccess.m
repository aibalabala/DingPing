#import "WindowAccess.h"
#include "DragPolicy.h"
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
- (BOOL)isAlive {
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:self.pid];
    return app && !app.terminated && [app.bundleIdentifier isEqual:self.bundleID] &&
           [readAX(self.ax,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole];
}
- (BOOL)isDefinitelyClosed {
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:self.pid];
    if(!app || app.terminated || ![app.bundleIdentifier isEqual:self.bundleID])return YES;
    CFTypeRef role=NULL;AXError error=AXUIElementCopyAttributeValue(self.ax,kAXRoleAttribute,&role);
    if(role)CFRelease(role);
    /* A messaging timeout is not proof of closure and must not erase identity. */
    return error==kAXErrorInvalidUIElement;
}
- (BOOL)isMinimized {return [readAX(self.ax,kAXMinimizedAttribute) boolValue];}
- (BOOL)isHidden {return [NSRunningApplication runningApplicationWithProcessIdentifier:self.pid].hidden;}
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
    if(![self isUsable])return NO;
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
- (BOOL)isFocusedInFrontmostApp {
    if(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=self.pid)return NO;
    AXUIElementRef application=AXUIElementCreateApplication(self.pid);
    AXUIElementSetMessagingTimeout(application,.5);
    id focused=readAX(application,kAXFocusedWindowAttribute);
    CFRelease(application);
    return focused && CFGetTypeID((__bridge CFTypeRef)focused)==AXUIElementGetTypeID() &&
           CFEqual((__bridge CFTypeRef)focused,(__bridge CFTypeRef)self.element);
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
            FSVisibleFrameMatch(f,(FSRect){b.origin.x,b.origin.y,b.size.width,b.size.height})) return YES;
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
    id document=readAX(element,kAXDocumentAttribute);
    w.document=[document isKindOfClass:NSString.class]?document:@"";
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
    /* A focused ordinary window is a usable fallback if WindowServer bounds
       cannot be paired with its AX frame on this macOS release. */
    pid_t front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    FSWindow *focused=FSFocusedWindow(front);
    if(focused) {
        BOOL known=NO;
        for(FSWindow *window in result)if([window sameWindow:focused]){known=YES;break;}
        if(!known)[result insertObject:focused atIndex:0];
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
    AXUIElementSetMessagingTimeout(axApp,.5);
    id focused=readAX(axApp,kAXFocusedWindowAttribute);
    CFRelease(axApp);
    if(!focused || CFGetTypeID((__bridge CFTypeRef)focused)!=AXUIElementGetTypeID())return nil;
    AXUIElementRef element=(__bridge AXUIElementRef)focused;
    AXUIElementSetMessagingTimeout(element,.5);
    FSWindow *w=makeWindow(element,app);
    /* AX's focused window belongs to the active app's current UI. WindowServer
       geometry is only a hint here; rejecting this window also disables the
       automatic capture path when the two APIs report different bounds. */
    return w && [w isUsable]?w:nil;
}

NSString *FSFocusedWindowDiagnostic(pid_t pid) {
    if(pid<=0 || pid==getpid())return @"没有可检查的外部应用";
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(!app || app.terminated)return [NSString stringWithFormat:@"PID %d 已退出",pid];
    AXUIElementRef axApp=AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(axApp,.5);
    CFTypeRef value=NULL;
    AXError status=AXUIElementCopyAttributeValue(axApp,kAXFocusedWindowAttribute,&value);
    CFRelease(axApp);
    if(status!=kAXErrorSuccess || !value || CFGetTypeID(value)!=AXUIElementGetTypeID()) {
        if(value)CFRelease(value);
        return [NSString stringWithFormat:@"%@ (PID %d)：无法取得焦点窗口，AX 错误 %d",app.localizedName?:@"应用",pid,status];
    }
    AXUIElementRef element=(AXUIElementRef)value;
    AXUIElementSetMessagingTimeout(element,.5);
    FSWindow *window=makeWindow(element,app);
    id role=readAX(element,kAXRoleAttribute),subrole=readAX(element,kAXSubroleAttribute);
    Boolean position=false,size=false;
    AXError positionError=AXUIElementIsAttributeSettable(element,kAXPositionAttribute,&position);
    AXError sizeError=AXUIElementIsAttributeSettable(element,kAXSizeAttribute,&size);
    FSRect frame={0};BOOL hasFrame=[window readFrame:&frame];
    NSString *result=[NSString stringWithFormat:@"%@ (PID %d)：角色 %@ / %@；位置可写 %@ (%d)；尺寸可写 %@ (%d)；坐标 %@；最小化 %@；隐藏 %@",
        app.localizedName?:@"应用",pid,role?:@"无",subrole?:@"无",
        position?@"是":@"否",positionError,size?@"是":@"否",sizeError,
        hasFrame?[NSString stringWithFormat:@"%.0f,%.0f %.0f×%.0f",frame.x,frame.y,frame.width,frame.height]:@"不可读",
        [readAX(element,kAXMinimizedAttribute) boolValue]?@"是":@"否",app.hidden?@"是":@"否"];
    CFRelease(value);
    return result;
}

NSString *FSDisplayID(NSScreen *screen) {
    CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display);
    if(!uuid)return [NSString stringWithFormat:@"display-%u",display];
    NSString *identifier=CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault,uuid));
    CFRelease(uuid); return identifier;
}

FSWindow *FSWindowAtPointWithChrome(CGPoint point, FSRect *visibleFrame,
                                    BOOL *plainChrome, NSString **reason) {
    if(plainChrome)*plainChrome=NO;
    if(visibleFrame)*visibleFrame=(FSRect){0};
    if(reason)*reason=@"辅助功能未授权";
    if(!AXIsProcessTrusted())return nil;
    /* The onscreen list is front to back. Bind the AX element to the actual
       layer-zero window below the pointer before accepting a drag source. */
    FSRect cgFrame={0};pid_t topPID=0;
    for(NSDictionary *row in FSOnScreenRows()) {
        if([row[(__bridge NSString *)kCGWindowLayer] intValue]!=0)continue;
        CGRect bounds;NSDictionary *value=row[(__bridge NSString *)kCGWindowBounds];
        if(!value || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)value,&bounds) ||
           !CGRectContainsPoint(bounds,point))continue;
        topPID=[row[(__bridge NSString *)kCGWindowOwnerPID] intValue];
        cgFrame=(FSRect){bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height};
        break;
    }
    if(!topPID){if(reason)*reason=@"鼠标下没有可见的普通窗口；请确认当前桌面和标题栏";return nil;}
    if(topPID==getpid()){if(reason)*reason=@"鼠标下是定屏的窗口；请拖动目标应用的标题栏";return nil;}
    if(visibleFrame)*visibleFrame=cgFrame;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:topPID];
    if(!app || app.activationPolicy!=NSApplicationActivationPolicyRegular || app.hidden) {
        if(reason)*reason=@"鼠标下的窗口不支持分屏";
        return nil;
    }
    AXUIElementRef system=AXUIElementCreateSystemWide(),hit=NULL;
    AXUIElementSetMessagingTimeout(system,.18);
    AXError result=AXUIElementCopyElementAtPosition(system,point.x,point.y,&hit);
    CFRelease(system);
    id role=nil;id hitWindow=nil;
    if(result==kAXErrorSuccess && hit) {
        AXUIElementSetMessagingTimeout(hit,.18);
        role=readAX(hit,kAXRoleAttribute);
        hitWindow=[role isEqual:(__bridge NSString *)kAXWindowRole]?(__bridge id)hit:readAX(hit,kAXWindowAttribute);
        if(!hitWindow)hitWindow=readAX(hit,kAXTopLevelUIElementAttribute);
    }
    /* A toolbar child may expose neither AXWindow nor a useful hit result.
       Enumerate just this frontmost PID, then choose the closest visible frame. */
    AXUIElementRef axApp=AXUIElementCreateApplication(topPID);
    AXUIElementSetMessagingTimeout(axApp,.18);
    id windows=readAX(axApp,kAXWindowsAttribute);
    CFRelease(axApp);
    FSWindow *best=nil;double bestScore=-1,secondScore=-1;
    NSMutableArray *candidates=[NSMutableArray new];
    if([windows isKindOfClass:NSArray.class])[candidates addObjectsFromArray:windows];
    if(hitWindow && CFGetTypeID((__bridge CFTypeRef)hitWindow)==AXUIElementGetTypeID()) {
        BOOL listed=NO;
        for(id candidate in candidates)if(CFGetTypeID((__bridge CFTypeRef)candidate)==AXUIElementGetTypeID() &&
            CFEqual((__bridge CFTypeRef)candidate,(__bridge CFTypeRef)hitWindow)){listed=YES;break;}
        if(!listed)[candidates addObject:hitWindow];
    }
    for(id element in candidates) {
        if(CFGetTypeID((__bridge CFTypeRef)element)!=AXUIElementGetTypeID())continue;
        AXUIElementRef ax=(__bridge AXUIElementRef)element;
        AXUIElementSetMessagingTimeout(ax,.18);
        pid_t pid=0;
        if(AXUIElementGetPid(ax,&pid)!=kAXErrorSuccess || pid!=topPID)continue;
        FSWindow *window=makeWindow(ax,app);FSRect frame;
        if(![window isUsable] || ![window readFrame:&frame])continue;
        BOOL direct=hitWindow && CFGetTypeID((__bridge CFTypeRef)hitWindow)==AXUIElementGetTypeID() &&
            CFEqual((__bridge CFTypeRef)hitWindow,(__bridge CFTypeRef)element);
        /* The WindowServer rectangle can differ from AX's frame, especially
           around toolbars. A system AX hit identifies the window directly;
           otherwise require a clear overlap with the front CG row of its PID. */
        double score=FSDragWindowMatchScore(frame,cgFrame,direct);
        if(score<0)continue;
        if(score>bestScore){secondScore=bestScore;best=window;bestScore=score;}
        else if(score>secondScore)secondScore=score;
    }
    if(bestScore<2 && secondScore>=0 && bestScore-secondScore<.15)best=nil;
    if(!best) {
        /* Focus is a fallback only when it corroborates the CG owner's PID
           and overlaps its visible frame. */
        FSWindow *focused=FSFocusedWindow(topPID);FSRect frame;
        double smaller=focused && [focused readFrame:&frame]?
            fmin(frame.width*frame.height,cgFrame.width*cgFrame.height):0;
        if(smaller>0 && FSIntersectionArea(frame,cgFrame)/smaller>=.25)best=focused;
    }
    BOOL matchedHit=hitWindow && CFGetTypeID((__bridge CFTypeRef)hitWindow)==AXUIElementGetTypeID() &&
        best && CFEqual((__bridge CFTypeRef)hitWindow,(__bridge CFTypeRef)best.element);
    if(hit)CFRelease(hit);
    if(!best) {
        if(reason)*reason=[NSString stringWithFormat:@"鼠标下窗口 PID %d；AX 命中%@；未找到该进程中可调整且边界重合的普通窗口",topPID,
            result==kAXErrorSuccess?@"成功": [NSString stringWithFormat:@"失败(%d)",result]];
        return nil;
    }
    FSRect axFrame;
    if(visibleFrame && [best readFrame:&axFrame] &&
       FSDragUseAXTitleFrame(axFrame,cgFrame,point.x,point.y)) *visibleFrame=axFrame;
    if(plainChrome && matchedHit)
        *plainChrome=[role isEqual:(__bridge NSString *)kAXWindowRole] ||
                     [role isEqual:(__bridge NSString *)kAXToolbarRole] ||
                     [role isEqual:(__bridge NSString *)kAXGroupRole] ||
                     [role isEqual:(__bridge NSString *)kAXStaticTextRole];
    if(reason)*reason=@"已识别鼠标下的窗口";
    return best;
}

FSWindow *FSWindowAtPoint(CGPoint point) {return FSWindowAtPointWithChrome(point,NULL,NULL,NULL);}

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
