#import "BindingStore.h"

static NSMutableDictionary *validDescriptor(id candidate) {
    if(![candidate isKindOfClass:NSDictionary.class] ||
       ![candidate[@"bundle"] isKindOfClass:NSString.class] ||
       ![candidate[@"app"] isKindOfClass:NSString.class] ||
       ![candidate[@"title"] isKindOfClass:NSString.class] ||
       ![candidate[@"bundle"] length])return [NSMutableDictionary new];
    NSMutableDictionary *result=[@{@"bundle":candidate[@"bundle"],@"app":candidate[@"app"],
                                    @"title":candidate[@"title"]} mutableCopy];
    if([candidate[@"document"] isKindOfClass:NSString.class] && [candidate[@"document"] length])
        result[@"document"]=candidate[@"document"];
    return result;
}

void FSProfileNormalize(NSMutableDictionary *profile, BOOL migrateLegacyPins) {
    NSArray *oldBindings=[profile[@"bindings"] isKindOfClass:NSArray.class]?profile[@"bindings"]:@[];
    NSArray *oldPins=[profile[@"pins"] isKindOfClass:NSArray.class]?profile[@"pins"]:@[];
    NSMutableArray *bindings=[NSMutableArray new],*pins=[NSMutableArray new];
    for(NSUInteger i=0;i<4;i++) {
        id old=i<oldBindings.count?oldBindings[i]:@{};
        [bindings addObject:validDescriptor(old)];
        id fixed=migrateLegacyPins && [old isKindOfClass:NSDictionary.class] &&
                 [old[@"pinned"] isEqual:@YES]?old:(i<oldPins.count?oldPins[i]:@{});
        [pins addObject:validDescriptor(fixed)];
    }
    profile[@"bindings"]=bindings;profile[@"pins"]=pins;
}

static NSDictionary *slotValue(NSDictionary *profile, NSString *key, NSInteger slot) {
    NSArray *entries=profile[key];
    return slot>=0 && slot<4 && [entries isKindOfClass:NSArray.class] &&
           (NSUInteger)slot<entries.count && [entries[slot] isKindOfClass:NSDictionary.class]?entries[slot]:@{};
}
NSDictionary *FSProfilePin(NSDictionary *profile, NSInteger slot) {return slotValue(profile,@"pins",slot);}
NSDictionary *FSProfileOccupant(NSDictionary *profile, NSInteger slot) {return slotValue(profile,@"bindings",slot);}
void FSProfileSetPin(NSMutableDictionary *profile, NSInteger slot, NSDictionary *descriptor) {
    if(slot<0 || slot>=4)return;
    ((NSMutableArray *)profile[@"pins"])[slot]=validDescriptor(descriptor);
}
void FSProfileSetOccupant(NSMutableDictionary *profile, NSInteger slot, NSDictionary *descriptor) {
    if(slot<0 || slot>=4)return;
    ((NSMutableArray *)profile[@"bindings"])[slot]=validDescriptor(descriptor);
}
