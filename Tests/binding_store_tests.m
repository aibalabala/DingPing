#import <Foundation/Foundation.h>
#import "../Sources/BindingStore.h"
#include <stdio.h>

int main(void) {@autoreleasepool {
    NSMutableDictionary *legacy=[@{@"bindings":[@[
        @{@"bundle":@"chrome",@"app":@"Google Chrome",@"title":@"old tab",@"pinned":@YES},
        @{@"bundle":@"code",@"app":@"Code",@"title":@"old file",@"pinned":@YES},
        @{@"bundle":@"terminal",@"app":@"终端",@"title":@"shell",@"pinned":@NO},@{}] mutableCopy]} mutableCopy];
    FSProfileNormalize(legacy,YES);
    NSCAssert([FSProfilePin(legacy,1)[@"bundle"] isEqual:@"code"],@"Code pin must migrate");
    NSDictionary *fixed=[FSProfilePin(legacy,1) copy];
    FSProfileSetOccupant(legacy,1,@{@"bundle":@"terminal",@"app":@"终端",@"title":@"another"});
    FSProfileSetOccupant(legacy,1,@{});
    NSCAssert([FSProfilePin(legacy,1) isEqual:fixed],@"Automatic placement cannot erase a pin");
    NSData *data=[NSJSONSerialization dataWithJSONObject:legacy options:0 error:NULL];
    NSMutableDictionary *roundTrip=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    FSProfileNormalize(roundTrip,NO);
    NSCAssert([FSProfilePin(roundTrip,1) isEqual:fixed],@"Pin must survive restart");
    FSProfileSetOccupant(roundTrip,1,@{@"bundle":@"finder",@"app":@"Finder",@"title":@"files"});
    NSCAssert([FSProfilePin(roundTrip,1) isEqual:fixed],@"Borrowing after restart cannot erase pin");
    FSProfileSetPin(roundTrip,1,@{});
    NSCAssert(![FSProfilePin(roundTrip,1)[@"bundle"] length],@"Explicit unpin must work");
    puts("PASS: v2 pin migration, borrowed occupant isolation, JSON restart, explicit unpin.");
}return 0;}
