#import "FocusObserver.h"

@interface FSFocusObserver () {
    AXObserverRef _observer;
    AXUIElementRef _application;
    pid_t _pid;
}
@end

static void focusChanged(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context) {
    FSFocusObserver *watcher=(__bridge FSFocusObserver *)context;
    if(watcher.onChange)watcher.onChange();
}

@implementation FSFocusObserver
- (void)watchPID:(pid_t)pid {
    if(pid==_pid && _observer)return;
    [self stop];
    if(pid<=0 || !AXIsProcessTrusted())return;
    if(AXObserverCreate(pid,focusChanged,&_observer)!=kAXErrorSuccess)return;
    _pid=pid;_application=AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(_application,.15);
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
    _pid=0;
}
- (void)dealloc {[self stop];}
@end
