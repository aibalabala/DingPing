#import "DragGuard.h"
#import "DragPolicy.h"

@implementation FSDragTarget @end

@interface FSDragGuard () {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
    AXUIElementRef _system;
    FSDragState _drag;
    BOOL _running;
    BOOL _faulted;
}
- (CGEventRef)filterType:(CGEventType)type event:(CGEventRef)event;
@end

static CGEventRef dragCallback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    @autoreleasepool {
        return [(__bridge FSDragGuard *)context filterType:type event:event];
    }
}

static id guardRead(AXUIElementRef element,CFStringRef attribute) {
    CFTypeRef value=NULL;
    AXError result=AXUIElementCopyAttributeValue(element,attribute,&value);
    if(result!=kAXErrorSuccess){if(value)CFRelease(value);return nil;}
    return CFBridgingRelease(value);
}

@implementation FSDragGuard
- (BOOL)running {return _running;}
- (BOOL)faulted {return _faulted;}
- (BOOL)start:(NSString **)error {
    if(_running)return YES;
    [self stop];_faulted=NO;
    if(!AXIsProcessTrusted()) {if(error)*error=@"请先开启辅助功能权限";_faulted=YES;return NO;}
    CGEventMask mask=CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventLeftMouseUp);
    _tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,mask,dragCallback,(__bridge void *)self);
    if(!_tap){if(error)*error=@"系统未允许鼠标拦截，请重新确认辅助功能权限后切换锁定模式重试";_faulted=YES;return NO;}
    _source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,_tap,0);
    if(!_source){[self stop];_faulted=YES;if(error)*error=@"无法创建鼠标拦截事件源";return NO;}
    _system=AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(_system,.015);
    CFRunLoopAddSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);
    CGEventTapEnable(_tap,true);_running=CGEventTapIsEnabled(_tap);
    if(!_running){[self stop];_faulted=YES;if(error)*error=@"鼠标拦截未生效";return NO;}
    return YES;
}
- (void)stop {
    _running=NO;
    FSFilterDrag(&_drag,FSDragReset,false,false);
    if(_tap){CGEventTapEnable(_tap,false);CFMachPortInvalidate(_tap);}
    if(_source){CFRunLoopRemoveSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);CFRelease(_source);_source=NULL;}
    if(_tap){CFRelease(_tap);_tap=NULL;}
    if(_system){CFRelease(_system);_system=NULL;}
    self.targets=@[];
}
- (void)dealloc {[self stop];}

- (BOOL)confirmedTitleAt:(CGPoint)point {
    /* The cached rectangle is just a cheap prefilter. Never suppress on geometry alone. */
    NSMutableArray<FSDragTarget *> *candidates=[NSMutableArray new];
    for(FSDragTarget *target in self.targets)if(FSTitleCandidate(target.frame,point.x,point.y))[candidates addObject:target];
    if(!candidates.count || !_system)return NO;
    CFAbsoluteTime started=CFAbsoluteTimeGetCurrent();
    AXUIElementRef hit=NULL;
    if(AXUIElementCopyElementAtPosition(_system,point.x,point.y,&hit)!=kAXErrorSuccess || !hit){if(hit)CFRelease(hit);return NO;}
    AXUIElementSetMessagingTimeout(hit,.015);
    BOOL confirmed=NO;
    for(FSDragTarget *target in candidates) {
        AXUIElementRef window=target.window.ax;
        AXUIElementSetMessagingTimeout(window,.015);
        FSRect live;
        BOOL inTitle=[target.window readFrame:&live] && FSTitleCandidate(live,point.x,point.y);
        if(inTitle) {
            id title=guardRead(window,kAXTitleUIElementAttribute);
            BOOL hasNativeTitle=title && CFGetTypeID((__bridge CFTypeRef)title)==AXUIElementGetTypeID();
            /* A bare AXWindow hit can also mean an inaccessible custom tab bar.
               Require an exposed native title element before accepting that case. */
            if(hasNativeTitle && (CFEqual(hit,window) || CFEqual(hit,(__bridge CFTypeRef)title)))confirmed=YES;
            /* Empty toolbar areas are allowed only if AX exposes the toolbar itself,
               never a child button, tab, search field, generic group, or web content. */
            if(!confirmed && [guardRead(hit,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXToolbarRole]) {
                id owner=guardRead(hit,kAXWindowAttribute);
                confirmed=owner && CFGetTypeID((__bridge CFTypeRef)owner)==AXUIElementGetTypeID() && CFEqual((__bridge CFTypeRef)owner,window);
            }
        }
        AXUIElementSetMessagingTimeout(window,.18);
        if(confirmed || CFAbsoluteTimeGetCurrent()-started>.07)break;
    }
    /* Restore ordinary AX timeouts, even if this hit aliases a managed window. */
    AXUIElementSetMessagingTimeout(hit,.18);CFRelease(hit);
    return confirmed && CFAbsoluteTimeGetCurrent()-started<.10;
}

- (CGEventRef)filterType:(CGEventType)type event:(CGEventRef)event {
    if(type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
        _running=NO;_faulted=YES;
        FSFilterDrag(&_drag,FSDragReset,false,false);
        /* Fail open and leave the ordinary restore mode running. No silent retry loop. */
        __weak FSDragGuard *weakSelf=self;
        dispatch_async(dispatch_get_main_queue(),^{
            FSDragGuard *guard=weakSelf;
            if(guard && !guard.running && guard.onFailure)guard.onFailure(@"系统暂停了拖动拦截，当前使用松手回位；可切换锁定模式重试");
        });
        return event;
    }
    if(!event)return event;
    BOOL enabled=_running && (!self.mayIntercept || self.mayIntercept());
    BOOL consumed=NO;
    if(type==kCGEventLeftMouseDown) {
        BOOL title=enabled && [self confirmedTitleAt:CGEventGetLocation(event)];
        consumed=FSFilterDrag(&_drag,FSDragDown,enabled,title);
    } else if(type==kCGEventLeftMouseDragged)consumed=FSFilterDrag(&_drag,FSDragMotion,enabled,false);
    else if(type==kCGEventLeftMouseUp)consumed=FSFilterDrag(&_drag,FSDragUp,enabled,false);
    return consumed?NULL:event;
}
@end
