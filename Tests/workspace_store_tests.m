#import <Foundation/Foundation.h>
#import "../Sources/WorkspaceStore.h"
#include <stdio.h>
static void check(BOOL value,NSString *message) {if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static NSDictionary *deep(id value) {return [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL] options:0 error:NULL];}
static NSDictionary *desc(NSString *bundle,NSString *title) {return @{@"bundle":bundle,@"app":bundle,@"title":title};}
int main(void) {@autoreleasepool {
    NSDictionary *chrome=desc(@"chrome",@"Codex"),*code=desc(@"code",@"project"),*terminal=desc(@"terminal",@"shell");
    NSDictionary *legacy=@{@"version":@3,@"active":@"old",@"mode":@"auto",@"profiles":@[
        @{@"id":@"old",@"name":@"工作",@"display":@"monitor",@"layout":@2,@"ratio":@.5,@"gap":@8,
          @"pins":@[chrome,code,@{},@{}],@"bindings":@[chrome,terminal,terminal,@{}]}]};
    FSWorkspaceStore *store=[[FSWorkspaceStore alloc] initWithConfig:legacy defaultDisplay:@"monitor"];
    check(!store.saveBlocked && [store.config[@"version"] isEqual:@4],@"schema 3 migrates");
    NSMutableDictionary *p=store.activeProfile;
    check([p[@"windows"] count]==4 && [p[@"favorite"] boolValue],@"both absent fixed owner and borrowed occupant survive");
    check([p[@"windows"][1][@"bundle"] isEqual:@"code"] && [p[@"windows"][1][@"pinned"] boolValue],@"Code's fixed record survives");
    check([legacy isEqual:deep(legacy)],@"migration does not mutate source");
    NSMutableDictionary *builtin=[store builtin:0 name:@"左右平分" display:@"monitor" layout:0 ratio:.5];
    check(builtin!=p && [builtin[@"windows"] count]==0,@"builtin has separate memory");
    check([store builtin:0 name:@"左右平分" display:@"monitor" layout:0 ratio:.5]==builtin,@"same builtin is reused");
    store.config[@"active"]=builtin[@"id"];
    NSMutableDictionary *a=[store addWindow:chrome slot:0 profile:builtin],*b=[store addWindow:desc(@"chrome",@"Docs") slot:1 profile:builtin];
    NSString *aid=a[@"id"],*bid=b[@"id"];
    for(int i=0;i<100;i++){[store promoteRecord:aid profile:builtin];[store promoteRecord:bid profile:builtin];}
    check([a[@"slot"] isEqual:@0] && [b[@"slot"] isEqual:@1],@"repeated focus never changes either zone");
    a[@"pinned"]=@YES;
    [store moveRecord:aid toSlot:1 profile:builtin];
    check([a[@"slot"] isEqual:@1] && [b[@"slot"] isEqual:@1] && [a[@"pinned"] boolValue],@"drag stacks rather than swapping, pin follows");
    check([builtin[@"windows"] count]==2 && [builtin[@"windows"] lastObject]==a,@"destination retains both windows and dragged window is top");
    NSMutableDictionary *favorite=[store saveFavorite:@"编程"];
    NSMutableDictionary *copyA=[store record:aid inProfile:favorite];
    [store moveRecord:aid toSlot:0 profile:favorite];
    check([copyA[@"slot"] isEqual:@0] && [a[@"slot"] isEqual:@1],@"saved plan has a deep independent memory");
    NSString *identifier=favorite[@"id"];favorite[@"name"]=@"开发";check([favorite[@"id"] isEqual:identifier],@"rename preserves identity");
    [store updateRecord:copyA descriptor:desc(@"chrome",@"new tab")];
    check([copyA[@"slot"] isEqual:@0] && [copyA[@"id"] isEqual:aid],@"title edit is not a new assignment");
    FSWorkspaceStore *restart=[[FSWorkspaceStore alloc] initWithConfig:deep(store.config) defaultDisplay:@"monitor"];
    check(!restart.saveBlocked && [[restart record:aid inProfile:restart.activeProfile][@"slot"] isEqual:@0],@"restart remembers each plan and stack order");
    NSArray *candidates=@[@{@"key":@"a",@"bundle":@"chrome",@"title":@"new tab"},@{@"key":@"b",@"bundle":@"chrome",@"title":@"Docs"}];
    NSDictionary *match=[restart matchCandidates:candidates profile:restart.activeProfile usedRecordIDs:[NSSet set]];
    check([match[@"a"] isEqual:aid] && [match[@"b"] isEqual:bid],@"two windows of same app recover independently");
    NSArray *ambiguous=@[@{@"key":@"a",@"bundle":@"chrome",@"title":@"new tab"},@{@"key":@"b",@"bundle":@"chrome",@"title":@"new tab"}];
    check([[restart matchCandidates:ambiguous profile:restart.activeProfile usedRecordIDs:[NSSet set]] count]==0,@"ambiguous title cannot guess a saved owner");
    check([[restart matchCandidates:@[@{@"key":@"c",@"bundle":@"chrome",@"title":@"unknown"}] profile:restart.activeProfile usedRecordIDs:[NSSet set]] count]==0,@"application alone cannot match");
    check(![store moveRecord:aid toSlot:4 profile:favorite],@"invalid destination is rejected");
    check([store deleteFavorite:identifier] && ![store profileWithID:identifier],@"deleting favorite does not remove builtin");
    check([store profileWithID:builtin[@"id"]]!=nil,@"builtin remains");
    FSWorkspaceStore *bad=[[FSWorkspaceStore alloc] initWithConfig:@{@"version":@99,@"profiles":@[]} defaultDisplay:@"monitor"];
    check(bad.saveBlocked,@"unknown schema is preserved");
    NSURL *dir=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];NSURL *url=[dir URLByAppendingPathComponent:@"layouts.json"];
    NSData *original=[NSJSONSerialization dataWithJSONObject:legacy options:0 error:NULL];[original writeToURL:url atomically:YES];
    FSWorkspaceStore *disk=[[FSWorkspaceStore alloc] initWithURL:url defaultDisplay:@"monitor"];
    check([[NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"layouts-before-0.8.0.json"]] isEqual:original],@"original config backed up byte-for-byte");
    check([disk save:NULL],@"migration writes atomically");
    FSWorkspaceStore *diskRestart=[[FSWorkspaceStore alloc] initWithURL:url defaultDisplay:@"monitor"];
    check(!diskRestart.saveBlocked && [diskRestart.activeProfile[@"windows"] count]==4,@"disk restart retains migration");
    [@"broken JSON" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    FSWorkspaceStore *broken=[[FSWorkspaceStore alloc] initWithURL:url defaultDisplay:@"monitor"];
    check(broken.saveBlocked && ![broken save:NULL],@"unparseable JSON cannot be overwritten");
    [NSFileManager.defaultManager removeItemAtURL:dir error:NULL];
    puts("PASS: migration/backup, absent pins, focus stability, drag stacking, independent favorites, restart, conservative recovery, corrupt-file preservation.");
}return 0;}
