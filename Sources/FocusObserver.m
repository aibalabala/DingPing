#import "FocusObserver.h"

@interface FSFocusObserver () {
    AXObserverRef _observer;
    AXUIElementRef _application;
    pid_t _pid;
}
@property(nonatomic,strong) NSMutableArray *knownWindows;
- (void)noteWindow:(AXUIElementRef)element;
- (void)handleNotification:(CFStringRef)notification element:(AXUIElementRef)element;
@end

static void focusChanged(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context) {
    FSFocusObserver *watcher=(__bridge FSFocusObserver *)context;
    [watcher handleNotification:notification element:element];
}

@implementation FSFocusObserver
- (void)handleNotification:(CFStringRef)notification element:(AXUIElementRef)element {
    if(CFEqual(notification,kAXWindowCreatedNotification)) [self noteWindow:element];
    else if(CFEqual(notification,kAXFocusedWindowChangedNotification) && _application) {
        CFTypeRef focused=NULL;
        if(AXUIElementCopyAttributeValue(_application,kAXFocusedWindowAttribute,&focused)==kAXErrorSuccess && focused) {
            if(CFGetTypeID(focused)==AXUIElementGetTypeID())[self noteWindow:(AXUIElementRef)focused];
            CFRelease(focused);
        }
    }
    if(self.onChange)self.onChange();
}
- (void)noteWindow:(AXUIElementRef)element {
    if(!element || CFGetTypeID(element)!=AXUIElementGetTypeID())return;
    CFTypeRef role=NULL;
    BOOL ordinary=AXUIElementCopyAttributeValue(element,kAXRoleAttribute,&role)==kAXErrorSuccess &&
                  role && CFGetTypeID(role)==CFStringGetTypeID() && CFEqual(role,kAXWindowRole);
    if(role)CFRelease(role);
    if(!ordinary)return;
    for(id known in self.knownWindows)if(CFEqual((__bridge CFTypeRef)known,element))return;
    [self.knownWindows addObject:(__bridge id)element];
    if(self.onCreated)self.onCreated((__bridge id)element,_pid);
}
- (void)watchPID:(pid_t)pid {
    if(pid==_pid && _observer)return;
    [self stop];
    if(pid<=0 || !AXIsProcessTrusted())return;
    if(AXObserverCreate(pid,focusChanged,&_observer)!=kAXErrorSuccess)return;
    _pid=pid;_application=AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(_application,.15);
    self.knownWindows=[NSMutableArray new];
    CFTypeRef current=NULL;
    if(AXUIElementCopyAttributeValue(_application,kAXWindowsAttribute,&current)==kAXErrorSuccess && current) {
        if(CFGetTypeID(current)==CFArrayGetTypeID())for(id window in (__bridge NSArray *)current)
            if(CFGetTypeID((__bridge CFTypeRef)window)==AXUIElementGetTypeID())[self.knownWindows addObject:window];
        CFRelease(current);
    }
    AXObserverAddNotification(_observer,_application,kAXFocusedWindowChangedNotification,(__bridge void *)self);
    AXObserverAddNotification(_observer,_application,kAXWindowCreatedNotification,(__bridge void *)self);
    CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(_observer),kCFRunLoopCommonModes);
}
- (void)stop {
    if(_observer) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(_observer),kCFRunLoopCommonModes);
        CFRelease(_observer);_observer=NULL;
    }
    if(_application){CFRelease(_application);_application=NULL;}
    self.knownWindows=nil;
    _pid=0;
}
- (void)dealloc {[self stop];}
@end
