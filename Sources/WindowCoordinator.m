#import "WindowCoordinator.h"
#include <unistd.h>

static NSDictionary *windowDescriptor(FSWindow *w) {
    NSMutableDictionary *d=[@{@"bundle":w.bundleID?:@"",@"app":w.appName?:@"",@"title":w.title?:@""} mutableCopy];
    if(w.document.length)d[@"document"]=w.document;return d;
}
@implementation FSWindowEnvironment
- (NSArray<FSWindow *> *)availableWindows {return FSAvailableWindows();}
- (NSArray *)visibleRows {return FSOnScreenRows();}
- (BOOL)trusted {return AXIsProcessTrusted();}
- (int)zonesForProfile:(NSDictionary *)profile into:(FSRect *)zones {
    NSScreen *screen=FSScreenWithID(profile[@"display"]);
    return screen?FSBuildZones([profile[@"layout"] intValue],FSUsableFrame(screen),
                              [profile[@"ratio"] doubleValue],[profile[@"gap"] doubleValue],zones):0;
}
- (BOOL)window:(FSWindow *)w onTargetOfProfile:(NSDictionary *)profile rows:(NSArray *)rows {
    NSScreen *screen=FSScreenWithID(profile[@"display"]);FSRect frame;
    return screen && [w isUsable] && [w readFrame:&frame] && FSScreenForFrame(frame)==screen &&
           ([w isOnScreen:rows] || [w isFocusedInFrontmostApp]);
}
@end
@interface FSWindowCoordinator () {
    FSWorkspaceGate _gate;
}
@property(nonatomic,strong,readwrite) FSWorkspaceStore *store;
@property(nonatomic,strong) NSMutableDictionary<NSString *,FSWindow *> *live;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary<NSString *,NSString *> *> *memberships;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *missing;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *failures;
@property(nonatomic,strong) NSMutableSet<NSString *> *pendingMoves;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSValue *> *originals;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSString *> *tops;
@property(nonatomic,strong) NSMutableArray<NSString *> *trace;
@property(nonatomic,strong) NSArray *rows;
@property(nonatomic) BOOL seeded;
@property(nonatomic) NSTimeInterval nextMaintenance;
@end
@implementation FSWindowCoordinator
- (instancetype)initWithStore:(FSWorkspaceStore *)store {
    self=[super init];if(!self)return nil;self.store=store;self.environment=[FSWindowEnvironment new];
    self.live=[NSMutableDictionary new];self.memberships=[NSMutableDictionary new];self.missing=[NSMutableDictionary new];
    self.failures=[NSMutableDictionary new];self.pendingMoves=[NSMutableSet new];self.originals=[NSMutableDictionary new];
    self.tops=[NSMutableDictionary new];self.trace=[NSMutableArray new];self.activeSlot=0;
    FSWorkspaceEnable(&_gate,[store.config[@"mode"] isEqual:@"auto"]);return self;
}
- (BOOL)enabled {return _gate.enabled;}
- (BOOL)busy {return _gate.switching || _gate.dragging || _gate.dropPending;}
- (BOOL)dragging {return _gate.dragging || _gate.dropPending;}
- (NSUInteger)generation {return _gate.generation;}
- (NSMutableDictionary *)profile {return self.store.activeProfile;}
- (NSScreen *)screen {return FSScreenWithID(self.profile[@"display"]);}
- (int)zones:(FSRect *)zones {
    return [self.environment zonesForProfile:self.profile into:zones];
}
- (NSMutableDictionary *)map {
    NSString *identifier=self.profile[@"id"];
    if(!self.memberships[identifier])self.memberships[identifier]=[NSMutableDictionary new];return self.memberships[identifier];
}
- (void)note:(NSString *)message {
    [self.trace addObject:message];if(self.trace.count>24)[self.trace removeObjectAtIndex:0];
    if(self.onMessage)self.onMessage(message);
}
- (void)save {
    NSError *error=nil;
    if(![self.store save:&error] && error)[self note:[@"保存方案失败：" stringByAppendingString:error.localizedDescription]];
    if(self.onChange)self.onChange();
}
- (NSString *)keyForWindow:(FSWindow *)window register:(BOOL)create {
    if(!window)return nil;
    for(NSString *key in self.live)if([window sameWindow:self.live[key]]) {self.live[key]=window;return key;}
    if(!create)return nil;NSString *key=NSUUID.UUID.UUIDString;self.live[key]=window;return key;
}
- (NSMutableDictionary *)recordForKey:(NSString *)key {
    return key?[self.store record:self.map[key] inProfile:self.profile]:nil;
}
- (BOOL)eligible:(FSWindow *)window {
    return window && [self.environment window:window onTargetOfProfile:self.profile rows:self.rows];
}
- (void)pause {
    BOOL enabled=_gate.enabled;FSWorkspaceEnable(&_gate,enabled);
    [self.pendingMoves removeAllObjects];[self.failures removeAllObjects];[self.tops removeAllObjects];
    self.seeded=NO;self.nextMaintenance=NSDate.timeIntervalSinceReferenceDate+1;
}
- (void)setFreeMode {
    FSWorkspaceEnable(&_gate,NO);self.store.config[@"mode"]=@"free";
    [self.pendingMoves removeAllObjects];[self.failures removeAllObjects];[self.tops removeAllObjects];
    [self save];[self note:@"自由模式：窗口保留当前位置；布局和方案记忆保留。"];
    if(self.onIdle)self.onIdle();
}
- (void)scanInitial:(BOOL)initial {
    self.rows=[self.environment visibleRows];NSArray *available=[self.environment availableWindows];
    NSMutableArray<NSString *> *keys=[NSMutableArray new];
    for(FSWindow *w in available)if([self eligible:w]) {
        NSString *key=[self keyForWindow:w register:YES];[keys addObject:key];[self.missing removeObjectForKey:key];
    }
    for(NSString *key in [self.live.allKeys copy]) {
        FSWindow *w=self.live[key];
        if(![w isAlive]) {
            NSUInteger attempts=[self.missing[key] unsignedIntegerValue]+1;self.missing[key]=@(attempts);
            if(attempts>=3) {
                [self.live removeObjectForKey:key];[self.missing removeObjectForKey:key];
                for(NSMutableDictionary *map in self.memberships.allValues)[map removeObjectForKey:key];
                [self.pendingMoves removeObject:key];[self.failures removeObjectForKey:key];
            }
        } else if([self eligible:w] && ![keys containsObject:key])[keys addObject:key];
    }
    NSMutableArray *candidates=[NSMutableArray new];
    for(NSString *key in keys) {
        NSMutableDictionary *d=[windowDescriptor(self.live[key]) mutableCopy];d[@"key"]=key;d[@"bound"]=@(self.map[key]!=nil);
        [candidates addObject:d];
    }
    NSDictionary *matches=[self.store matchCandidates:candidates profile:self.profile
                                        usedRecordIDs:[NSSet setWithArray:self.map.allValues]];
    BOOL changed=NO;FSRect zones[4];int count=[self zones:zones];unsigned populations[4]={0};
    for(NSString *key in self.map) {
        NSDictionary *r=[self recordForKey:key];NSInteger slot=[r[@"slot"] integerValue];
        if(r && slot<count && [self eligible:self.live[key]])populations[slot]++;
    }
    /* Match all remembered windows first, before assigning the surplus. This
       makes a layout switch independent of accessibility enumeration order. */
    for(NSString *key in keys)if(!self.map[key] && matches[key]) {
        self.map[key]=matches[key];NSDictionary *r=[self recordForKey:key];NSInteger slot=[r[@"slot"] integerValue];
        if(slot<count)populations[slot]++;
    }
    for(NSString *key in keys) {
        FSWindow *w=self.live[key];NSMutableDictionary *r=[self recordForKey:key];
        if(!r || [r[@"slot"] integerValue]>=count) {
            /* A remembered slot outside a shape edited by the user is mapped
               to an existing zone once. It never floats between zones on focus. */
            NSInteger slot=FSWorkspaceChooseSlot(count,-1,(int)self.activeSlot,populations,
                                !initial && [self.profile[@"newWindowInActiveSlot"] boolValue]);
            if(slot<0)continue;
            if(r)[self.store moveRecord:r[@"id"] toSlot:slot profile:self.profile];
            else {r=[self.store addWindow:windowDescriptor(w) slot:slot profile:self.profile];self.map[key]=r[@"id"];}
            populations[slot]++;changed=YES;
            [self note:[NSString stringWithFormat:@"%@ → 分区 %ld · %@",w.appName,(long)slot+1,initial?@"首次分配":@"新窗口叠放"]];
        }
        NSDictionary *d=windowDescriptor(w);
        for(NSString *profileID in self.memberships) {
            NSMutableDictionary *p=[self.store profileWithID:profileID];
            NSMutableDictionary *remembered=[self.store record:self.memberships[profileID][key] inProfile:p];
            if(!remembered)continue;
            if(![remembered[@"title"] isEqual:d[@"title"]] || ![(remembered[@"document"]?:@"") isEqual:(d[@"document"]?:@"")]) {
                [self.store updateRecord:remembered descriptor:d];changed=YES;
            }
        }
    }
    if(changed)[self save];
}
- (NSArray<FSWindow *> *)windowsInSlot:(NSInteger)slot {
    NSMutableArray *result=[NSMutableArray new];NSDictionary *map=self.map;
    for(NSDictionary *r in self.profile[@"windows"])if([r[@"slot"] integerValue]==slot)
        for(NSString *key in map)if([map[key] isEqual:r[@"id"]] && self.live[key])[result addObject:self.live[key]];
    return result;
}
- (FSWindow *)topWindowInSlot:(NSInteger)slot {
    for(FSWindow *w in [self windowsInSlot:slot].reverseObjectEnumerator)if([self eligible:w])return w;return nil;
}
- (NSArray<FSWindow *> *)availableWindows {return [self.environment availableWindows];}
- (NSInteger)slotForWindow:(FSWindow *)window {
    NSDictionary *r=[self recordForKey:[self keyForWindow:window register:NO]];return r?[r[@"slot"] integerValue]:-1;
}
- (void)moveKey:(NSString *)key target:(FSRect)target token:(uint64_t)token {
    FSWindow *w=self.live[key];FSRect current;
    if(!FSWorkspaceCommandCurrent(&_gate,token) || [self.pendingMoves containsObject:key] ||
       [self.failures[key] integerValue]>=2 || ![self eligible:w] || ![w readFrame:&current] || FSRectNear(current,target,4))return;
    if(!self.originals[key])self.originals[key]=[NSValue valueWithRect:NSMakeRect(current.x,current.y,current.width,current.height)];
    NSString *error=nil;
    if(![w moveTo:target error:&error]) {self.failures[key]=@2;[self note:[NSString stringWithFormat:@"%@ 调整暂停：%@",w.appName,error]];return;}
    [self.pendingMoves addObject:key];__weak FSWindowCoordinator *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.4*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        FSWindowCoordinator *engine=weakSelf;
        if(!engine || !FSWorkspaceCommandCurrent(&engine->_gate,token))return;
        [engine.pendingMoves removeObject:key];FSRect actual;
        if(![w isUsable] || NSEvent.pressedMouseButtons!=0)return;
        if([w readFrame:&actual] && FSRectNear(actual,target,4))engine.failures[key]=@0;
        else {
            NSInteger count=[engine.failures[key] integerValue]+1;engine.failures[key]=@(count);
            if(count>=2)[engine note:[NSString stringWithFormat:@"%@ 未达到目标尺寸，已暂停重复调整；点击当前方案重试。",w.appName]];
        }
        if(engine.onChange)engine.onChange();
    });
}
- (void)arrange:(uint64_t)token {
    FSRect zones[4];int count=[self zones:zones];
    for(NSString *key in self.map) {
        NSDictionary *r=[self recordForKey:key];NSInteger slot=[r[@"slot"] integerValue];
        if(r && slot>=0 && slot<count)[self moveKey:key target:zones[slot] token:token];
    }
}
- (void)updateTopsReveal:(BOOL)reveal {
    FSRect zones[4];int count=[self zones:zones];NSMutableDictionary *next=[NSMutableDictionary new];
    for(int slot=0;slot<count;slot++) {
        FSWindow *w=[self topWindowInSlot:slot];NSString *key=[self keyForWindow:w register:NO];if(key)next[@(slot)]=key;
        NSString *old=self.tops[@(slot)];
        NSDictionary *oldRecord=old?[self recordForKey:old]:nil;
        if(reveal && old && ![old isEqual:key] &&
           (![self eligible:self.live[old]] || !oldRecord || [oldRecord[@"slot"] integerValue]!=slot) && w) {
            [w raiseWindow];[self note:[NSString stringWithFormat:@"分区 %d 显示下一窗口：%@",slot+1,w.appName]];
        }
    }
    self.tops=next;
}
- (void)tick {
    FSRect zones[4];
    if(!FSWorkspaceIdle(&_gate) || ![self.environment trusted] || ![self zones:zones] || NSEvent.pressedMouseButtons!=0)return;
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    if(now<self.nextMaintenance)return;self.nextMaintenance=now+.7;
    [self scanInitial:!self.seeded];self.seeded=YES;
    [self arrange:_gate.generation];[self updateTopsReveal:YES];
    if(self.onChange)self.onChange();
}
- (void)observeFocusedWindow:(FSWindow *)window {
    if(!FSWorkspaceIdle(&_gate) || !window || ![self eligible:window])return;
    NSString *key=[self keyForWindow:window register:NO];NSMutableDictionary *r=[self recordForKey:key];
    if(!r) {
        [self scanInitial:!self.seeded];self.seeded=YES;
        key=[self keyForWindow:window register:NO];r=[self recordForKey:key];
    }
    if(!r)return;self.activeSlot=[r[@"slot"] integerValue];
    /* Focus changes only stack order. This method cannot change r.slot,
       evict another record, run a binding resolver or move another window. */
    if([self.store promoteRecord:r[@"id"] profile:self.profile])[self save];
    [self updateTopsReveal:NO];
}
- (BOOL)activateProfile:(NSString *)identifier preferredWindow:(FSWindow *)preferred foreground:(BOOL)foreground {
    NSMutableDictionary *p=[self.store profileWithID:identifier];if(!p || self.dragging)return NO;
    uint64_t token=FSWorkspaceBeginSwitch(&_gate);if(!token)return NO;
    self.store.config[@"active"]=identifier;self.store.config[@"mode"]=@"auto";self.activeSlot=0;
    [self.pendingMoves removeAllObjects];[self.failures removeAllObjects];[self.tops removeAllObjects];
    [self scanInitial:YES];self.seeded=YES;
    if([p[@"restoreMinimized"] boolValue])for(NSString *key in self.map)[self.live[key] restoreForLayout];
    [self arrange:token];[self save];
    NSString *preferredKey=[self keyForWindow:preferred register:NO];
    if(self.map[preferredKey?:@""])[self.store promoteRecord:self.map[preferredKey] profile:p];
    __weak FSWindowCoordinator *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.18*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        FSWindowCoordinator *engine=weakSelf;
        if(!engine || !FSWorkspaceCommandCurrent(&engine->_gate,token))return;
        engine.rows=[engine.environment visibleRows];FSRect zones[4];int count=[engine zones:zones];
        FSWindow *focus=preferredKey?[engine.live objectForKey:preferredKey]:nil;
        if(![engine eligible:focus])focus=nil;
        for(int slot=0;slot<count;slot++) {
            for(FSWindow *w in [engine windowsInSlot:slot])if(foreground && [engine eligible:w])[w raiseWindow];
            if(!focus)focus=[engine topWindowInSlot:slot];
        }
        if(foreground && focus)[focus focusWindow];
        /* Application activation can raise its sibling windows. Restore each
           zone's top once, while the gate still suppresses self-made focus. */
        if(foreground)for(int slot=0;slot<count;slot++)[[engine topWindowInSlot:slot] raiseWindow];
        if(focus)engine.activeSlot=[engine slotForWindow:focus];
        [engine updateTopsReveal:NO];FSWorkspaceFinishSwitch(&engine->_gate,token);
        [engine save];[engine note:[NSString stringWithFormat:@"已启用「%@」：%lu 个窗口分别归位；点击只置前，拖动保存位置。",
                                   engine.profile[@"name"],(unsigned long)engine.map.count]];
        if(engine.onIdle)engine.onIdle();
    });return YES;
}
- (uint64_t)beginDrag {
    if(_gate.switching)[self pause]; /* Direct user input preempts a layout's delayed effects. */
    uint64_t token=FSWorkspaceBeginDrag(&_gate);
    if(token){[self.pendingMoves removeAllObjects];[self.failures removeAllObjects];}return token;
}
- (BOOL)releaseDrag:(uint64_t)token {return FSWorkspaceReleaseDrag(&_gate,token);}
- (void)finishDrag:(uint64_t)token window:(FSWindow *)window destination:(NSInteger)destination {
    /* Commit membership before releasing the gate. Delayed focus, maintenance
       and queued switches therefore observe the user's final assignment. */
    if(_gate.generation!=token || (!_gate.dragging && !_gate.dropPending))return;
    FSRect zones[4];int count=[self zones:zones];
    if(window && destination>=0 && destination<count) {
        NSString *key=[self keyForWindow:window register:YES];NSMutableDictionary *r=[self recordForKey:key];
        if(!r){r=[self.store addWindow:windowDescriptor(window) slot:destination profile:self.profile];self.map[key]=r[@"id"];}
        NSInteger source=[r[@"slot"] integerValue];
        [self.store updateRecord:r descriptor:windowDescriptor(window)];
        [self.store moveRecord:r[@"id"] toSlot:destination profile:self.profile];self.activeSlot=destination;
        [self save];[self note:[NSString stringWithFormat:@"%@：分区 %ld → %ld · 已保存，目标分区原窗口保留在下层。",
                                window.appName,(long)source+1,(long)destination+1]];
    }
    if(!FSWorkspaceFinishDrag(&_gate,token))return;
    self.rows=[self.environment visibleRows];[self arrange:token];[self updateTopsReveal:YES];
    if(window && destination>=0 && destination<count)[window raiseWindow];
    self.nextMaintenance=NSDate.timeIntervalSinceReferenceDate+.35;
    if(self.onIdle)self.onIdle();
}
- (void)assignWindow:(FSWindow *)window toSlot:(NSInteger)slot {
    uint64_t token=[self beginDrag];if(token)[self finishDrag:token window:window destination:slot];
}
- (void)focusSlot:(NSInteger)slot {
    if(!FSWorkspaceIdle(&_gate))return;FSWindow *w=[self topWindowInSlot:slot];self.activeSlot=slot;
    [w focusWindow];[self observeFocusedWindow:w];if(self.onChange)self.onChange();
}
- (BOOL)topWindowPinned:(NSInteger)slot {
    FSWindow *w=[self topWindowInSlot:slot];return [[self recordForKey:[self keyForWindow:w register:NO]][@"pinned"] boolValue];
}
- (void)togglePinInSlot:(NSInteger)slot {
    if(!FSWorkspaceIdle(&_gate))return;FSWindow *w=[self topWindowInSlot:slot];
    NSMutableDictionary *r=[self recordForKey:[self keyForWindow:w register:NO]];if(!r)return;
    r[@"pinned"]=@(![r[@"pinned"] boolValue]);[self save];
    [self note:@"所有窗口默认记住分区；固定标记随手动拖动更新，不代表永久置顶。"];
}
- (NSMutableDictionary *)saveFavorite:(NSString *)name {
    if(self.busy)return nil;NSString *old=self.profile[@"id"];NSDictionary *map=[self.map copy];
    NSMutableDictionary *p=[self.store saveFavorite:name];self.memberships[p[@"id"]]=[map mutableCopy];
    FSWorkspaceEnable(&_gate,self.enabled);[self.pendingMoves removeAllObjects];[self save];
    [self note:[NSString stringWithFormat:@"已保存常用方案「%@」；后续拖动自动更新这份方案，原布局「%@」独立保留。",name,[self.store profileWithID:old][@"name"]]];return p;
}
- (void)restoreOriginalPositions {
    [self setFreeMode];self.rows=FSOnScreenRows();NSUInteger restored=0;
    for(NSString *key in self.originals) {
        FSWindow *w=self.live[key];if(![w isUsable] || ![w isOnScreen:self.rows])continue;
        NSRect r=[self.originals[key] rectValue];NSString *error=nil;
        if([w moveTo:(FSRect){r.origin.x,r.origin.y,r.size.width,r.size.height} error:&error])restored++;
    }
    [self note:[NSString stringWithFormat:@"已进入自由模式，恢复 %lu 个窗口的原位置。",(unsigned long)restored]];
}
- (NSString *)diagnostic {
    FSRect zones[4];int count=[self zones:zones];NSMutableArray *lines=[NSMutableArray new];
    [lines addObject:[NSString stringWithFormat:@"方案：%@；记录 %lu；本次匹配 %lu；事件代次 %llu；拖动 %@；切换 %@",
                      self.profile[@"name"],(unsigned long)[self.profile[@"windows"] count],(unsigned long)self.map.count,
                      (unsigned long long)_gate.generation,self.dragging?@"进行中":@"空闲",_gate.switching?@"进行中":@"空闲"]];
    for(int slot=0;slot<count;slot++) {
        NSArray *stack=[self windowsInSlot:slot];NSUInteger index=0;
        for(FSWindow *w in stack.reverseObjectEnumerator) {
            FSRect actual={0};BOOL read=[w readFrame:&actual];
            NSString *state=[w isMinimized]?@"最小化保留":([w isHidden]?@"隐藏保留":
                ([self eligible:w]?(read && FSRectNear(actual,zones[slot],4)?@"已到位":@"未到位"):@"当前桌面/显示器未参与"));
            [lines addObject:[NSString stringWithFormat:@"%d.%lu %@：%@；目标 %.0f,%.0f %.0f×%.0f；实际 %.0f,%.0f %.0f×%.0f",
                slot+1,(unsigned long)++index,w.label,state,zones[slot].x,zones[slot].y,zones[slot].width,zones[slot].height,
                actual.x,actual.y,actual.width,actual.height]];
        }
        if(!stack.count)[lines addObject:[NSString stringWithFormat:@"%d 空分区",slot+1]];
    }
    [lines addObject:@"最近事件（点击不会修改分区）："];[lines addObjectsFromArray:self.trace];return [lines componentsJoinedByString:@"\n"];
}
@end
