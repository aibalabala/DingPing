#import "WorkspaceStore.h"
#include <math.h>

static NSString *stringValue(id value) {return [value isKindOfClass:NSString.class]?value:@"";}
static NSMutableDictionary *descriptor(id value) {
    if(![value isKindOfClass:NSDictionary.class] || ![stringValue(value[@"bundle"]) length])return nil;
    NSMutableDictionary *d=[@{@"bundle":stringValue(value[@"bundle"]),@"app":stringValue(value[@"app"]),
                                @"title":stringValue(value[@"title"])} mutableCopy];
    if([stringValue(value[@"document"]) length])d[@"document"]=value[@"document"];
    return d;
}
static NSMutableDictionary *baseProfile(NSString *name,NSString *display) {
    return [@{@"id":NSUUID.UUID.UUIDString,@"name":name,@"display":display?:@"",@"layout":@0,
              @"ratio":@.5,@"gap":@8,@"preventDrag":@NO,@"newWindowInActiveSlot":@YES,
              @"restoreMinimized":@NO,@"favorite":@NO,@"windows":[NSMutableArray new]} mutableCopy];
}
@interface FSWorkspaceStore ()
@property(nonatomic,strong,readwrite) NSMutableDictionary *config;
@property(nonatomic,strong,readwrite) NSURL *url;
@property(nonatomic,copy,readwrite) NSString *loadNote;
@property(nonatomic,readwrite) BOOL saveBlocked;
@end
@implementation FSWorkspaceStore
- (instancetype)initWithURL:(NSURL *)url defaultDisplay:(NSString *)display {
    NSData *data=[NSData dataWithContentsOfURL:url];
    NSDictionary *loaded=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    self=[self initWithConfig:loaded defaultDisplay:display];if(!self)return nil;
    self.url=url;
    if(data && !loaded)self.saveBlocked=YES;
    if(data && self.saveBlocked)self.loadNote=@"配置格式无法识别，原文件已保留；本次不覆盖。";
    if(data && !self.saveBlocked && [loaded[@"version"] integerValue]<4) {
        NSURL *backup=[url.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"layouts-before-0.8.0.json"];
        NSError *error=nil;
        if(![NSFileManager.defaultManager fileExistsAtPath:backup.path] && ![data writeToURL:backup options:NSDataWritingAtomic error:&error]) {
            self.saveBlocked=YES;self.loadNote=[NSString stringWithFormat:@"旧配置备份失败，暂不保存迁移：%@",error.localizedDescription];
        } else self.loadNote=@"旧配置已备份；保存的窗口和固定位置已迁移为独立方案。";
    }
    return self;
}
- (instancetype)initWithConfig:(NSDictionary *)loaded defaultDisplay:(NSString *)display {
    self=[super init];if(!self)return nil;
    BOOL hasData=loaded!=nil;
    NSInteger version=[loaded isKindOfClass:NSDictionary.class] && [loaded[@"version"] isKindOfClass:NSNumber.class]?[loaded[@"version"] integerValue]:0;
    BOOL valid=[loaded isKindOfClass:NSDictionary.class] && version>=1 && version<=4 &&
               [loaded[@"profiles"] isKindOfClass:NSArray.class] && [loaded[@"profiles"] count]>0;
    NSMutableArray *profiles=[NSMutableArray new];NSMutableSet *profileIDs=[NSMutableSet new];
    if(valid)for(id old in loaded[@"profiles"]) {
        if(![old isKindOfClass:NSDictionary.class] || ![stringValue(old[@"id"]) length] ||
           ![stringValue(old[@"name"]) length] || [profileIDs containsObject:old[@"id"]] ||
           ![old[@"layout"] isKindOfClass:NSNumber.class] || [old[@"layout"] integerValue]<0 ||
           [old[@"layout"] integerValue]>=10 || ![old[@"ratio"] isKindOfClass:NSNumber.class] ||
           !isfinite([old[@"ratio"] doubleValue]) || ![old[@"gap"] isKindOfClass:NSNumber.class] ||
           !isfinite([old[@"gap"] doubleValue])) {valid=NO;break;}
        for(NSString *key in @[@"preventDrag",@"newWindowInActiveSlot",@"restoreMinimized",@"favorite"])
            if(old[key] && ![old[key] isKindOfClass:NSNumber.class])valid=NO;
        if(!valid)break;
        NSMutableDictionary *p=baseProfile(old[@"name"],stringValue(old[@"display"]));
        p[@"id"]=old[@"id"];p[@"layout"]=old[@"layout"];
        p[@"ratio"]=@(fmax(.2,fmin(.8,[old[@"ratio"] doubleValue])));
        p[@"gap"]=@(fmax(0,fmin(40,[old[@"gap"] doubleValue])));
        p[@"preventDrag"]=@([old[@"preventDrag"] boolValue]);
        p[@"newWindowInActiveSlot"]=old[@"newWindowInActiveSlot"]?:@YES;
        p[@"restoreMinimized"]=@([old[@"restoreMinimized"] boolValue]);
        p[@"favorite"]=version<4?@YES:@([old[@"favorite"] boolValue]);
        if(version==4 && [old[@"preset"] isKindOfClass:NSNumber.class])p[@"preset"]=old[@"preset"];
        if(version==4) {
            if(![old[@"windows"] isKindOfClass:NSArray.class]) {valid=NO;break;}
            NSMutableSet *recordIDs=[NSMutableSet new];
            for(id item in old[@"windows"]) {
                NSMutableDictionary *d=descriptor(item);
                if(!d || ![stringValue(item[@"id"]) length] || [recordIDs containsObject:item[@"id"]] ||
                   (item[@"pinned"] && ![item[@"pinned"] isKindOfClass:NSNumber.class]) ||
                   ![item[@"slot"] isKindOfClass:NSNumber.class] || [item[@"slot"] integerValue]<0 ||
                   [item[@"slot"] integerValue]>=4) {valid=NO;break;}
                d[@"id"]=item[@"id"];d[@"slot"]=item[@"slot"];d[@"pinned"]=@([item[@"pinned"] boolValue]);
                [p[@"windows"] addObject:d];[recordIDs addObject:d[@"id"]];
            }
            if(!valid)break;
            if([recordIDs containsObject:stringValue(old[@"lastWindow"])])p[@"lastWindow"]=old[@"lastWindow"];
        } else {
            NSArray *bindings=[old[@"bindings"] isKindOfClass:NSArray.class]?old[@"bindings"]:@[];
            NSArray *pins=[old[@"pins"] isKindOfClass:NSArray.class]?old[@"pins"]:@[];
            for(NSInteger slot=0;slot<4;slot++) {
                id binding=(NSUInteger)slot<bindings.count?bindings[slot]:@{};
                id pin=(NSUInteger)slot<pins.count?pins[slot]:@{};
                if(version<3 && [binding isKindOfClass:NSDictionary.class] && [binding[@"pinned"] boolValue])pin=binding;
                NSMutableDictionary *fixed=descriptor(pin),*occupant=descriptor(binding);
                if(fixed) {NSMutableDictionary *r=[self addWindow:fixed slot:slot profile:p];r[@"pinned"]=@YES;}
                if(occupant && ![occupant isEqual:fixed])[self addWindow:occupant slot:slot profile:p];
            }
        }
        [profiles addObject:p];[profileIDs addObject:p[@"id"]];
    }
    if(!valid) {
        [profiles removeAllObjects];NSMutableDictionary *p=baseProfile(@"左右平分",display);p[@"preset"]=@0;
        [profiles addObject:p];self.saveBlocked=hasData;
    }
    NSString *active=valid && [profileIDs containsObject:stringValue(loaded[@"active"])]?loaded[@"active"]:profiles.firstObject[@"id"];
    self.config=[@{@"version":@4,@"profiles":profiles,@"active":active,
                  @"mode":valid && [loaded[@"mode"] isEqual:@"auto"]?@"auto":@"free"} mutableCopy];
    return self;
}
- (NSMutableDictionary *)profileWithID:(NSString *)identifier {
    for(NSMutableDictionary *p in self.config[@"profiles"])if([p[@"id"] isEqual:identifier])return p;return nil;
}
- (NSMutableDictionary *)activeProfile {return [self profileWithID:self.config[@"active"]]?:[self.config[@"profiles"] firstObject];}
- (NSMutableDictionary *)builtin:(NSInteger)preset name:(NSString *)name display:(NSString *)display layout:(NSInteger)layout ratio:(double)ratio {
    for(NSMutableDictionary *p in self.config[@"profiles"])if(![p[@"favorite"] boolValue] &&
        [p[@"preset"] integerValue]==preset && p[@"preset"] && [p[@"display"] isEqual:display])return p;
    NSMutableDictionary *p=baseProfile(name,display);p[@"preset"]=@(preset);p[@"layout"]=@(layout);p[@"ratio"]=@(ratio);
    [self.config[@"profiles"] addObject:p];return p;
}
- (NSMutableDictionary *)saveFavorite:(NSString *)name {
    NSData *data=[NSJSONSerialization dataWithJSONObject:self.activeProfile options:0 error:NULL];
    NSMutableDictionary *copy=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    copy[@"id"]=NSUUID.UUID.UUIDString;copy[@"name"]=name;copy[@"favorite"]=@YES;[copy removeObjectForKey:@"preset"];
    [self.config[@"profiles"] addObject:copy];self.config[@"active"]=copy[@"id"];return copy;
}
- (BOOL)deleteFavorite:(NSString *)identifier {
    NSMutableDictionary *p=[self profileWithID:identifier];if(!p || ![p[@"favorite"] boolValue])return NO;
    [self.config[@"profiles"] removeObject:p];
    if(![self.config[@"profiles"] count]) {
        NSMutableDictionary *fallback=baseProfile(@"左右平分",p[@"display"]);fallback[@"preset"]=@0;
        [self.config[@"profiles"] addObject:fallback];
    }
    if([self.config[@"active"] isEqual:identifier])self.config[@"active"]=[self.config[@"profiles"] firstObject][@"id"];
    return YES;
}
- (BOOL)save:(NSError **)error {
    if(self.saveBlocked)return NO;if(!self.url)return YES;
    if(![NSFileManager.defaultManager createDirectoryAtURL:self.url.URLByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:error])return NO;
    NSData *data=[NSJSONSerialization dataWithJSONObject:self.config options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToURL:self.url options:NSDataWritingAtomic error:error];
}
- (NSMutableDictionary *)record:(NSString *)identifier inProfile:(NSDictionary *)profile {
    for(NSMutableDictionary *r in profile[@"windows"])if([r[@"id"] isEqual:identifier])return r;return nil;
}
- (NSMutableDictionary *)addWindow:(NSDictionary *)d slot:(NSInteger)slot profile:(NSMutableDictionary *)profile {
    NSMutableDictionary *r=descriptor(d);if(!r || slot<0 || slot>=4)return nil;
    r[@"id"]=NSUUID.UUID.UUIDString;r[@"slot"]=@(slot);r[@"pinned"]=@NO;[profile[@"windows"] addObject:r];return r;
}
- (void)updateRecord:(NSMutableDictionary *)record descriptor:(NSDictionary *)value {
    NSMutableDictionary *d=descriptor(value);if(!record || !d)return;
    for(NSString *field in @[@"bundle",@"app",@"title",@"document"]) {
        if(d[field])record[field]=d[field];else [record removeObjectForKey:field];
    }
}
- (BOOL)promoteRecord:(NSString *)identifier profile:(NSMutableDictionary *)profile {
    NSMutableDictionary *r=[self record:identifier inProfile:profile];if(!r)return NO;
    BOOL top=YES;BOOL seen=NO;
    for(NSDictionary *other in profile[@"windows"]) {
        if(other==r)seen=YES;
        else if(seen && [other[@"slot"] isEqual:r[@"slot"]])top=NO;
    }
    BOOL changed=!top || ![profile[@"lastWindow"] isEqual:identifier];
    if(!top){[profile[@"windows"] removeObjectIdenticalTo:r];[profile[@"windows"] addObject:r];}
    profile[@"lastWindow"]=identifier;return changed;
}
- (BOOL)moveRecord:(NSString *)identifier toSlot:(NSInteger)slot profile:(NSMutableDictionary *)profile {
    NSMutableDictionary *r=[self record:identifier inProfile:profile];if(!r || slot<0 || slot>=4)return NO;
    r[@"slot"]=@(slot);[self promoteRecord:identifier profile:profile];return YES;
}
- (NSDictionary<NSString *,NSString *> *)matchCandidates:(NSArray<NSDictionary *> *)candidates profile:(NSDictionary *)profile usedRecordIDs:(NSSet<NSString *> *)used {
    NSMutableDictionary *result=[NSMutableDictionary new];NSMutableSet *taken=[used mutableCopy]?:[NSMutableSet new];
    for(NSString *field in @[@"document",@"title"])for(NSDictionary *candidate in candidates) {
        if([candidate[@"bound"] boolValue] || result[candidate[@"key"]] || ![stringValue(candidate[field]) length])continue;
        NSUInteger liveCount=0;
        for(NSDictionary *other in candidates)if([other[@"bundle"] isEqual:candidate[@"bundle"]] &&
            [other[field] isEqual:candidate[field]])liveCount++;
        if(liveCount!=1)continue;
        NSMutableArray *matches=[NSMutableArray new];
        for(NSDictionary *r in profile[@"windows"])if(![taken containsObject:r[@"id"]] &&
            [r[@"bundle"] isEqual:candidate[@"bundle"]] && [r[field] isEqual:candidate[field]])[matches addObject:r];
        if(matches.count==1) {NSString *identifier=matches.firstObject[@"id"];result[candidate[@"key"]]=identifier;[taken addObject:identifier];}
    }
    return result;
}
@end
