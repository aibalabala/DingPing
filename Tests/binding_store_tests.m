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
    NSDictionary *fixedChrome=@{@"bundle":@"chrome",@"app":@"Google Chrome",@"title":@"fixed browser"};
    NSDictionary *workingChrome=@{@"bundle":@"chrome",@"app":@"Google Chrome",@"title":@"Codex"};
    NSDictionary *finder=@{@"bundle":@"finder",@"app":@"Finder",@"title":@"files"};
    NSMutableDictionary *layout=[@{@"bindings":@[fixedChrome,workingChrome,finder,@{}],
                                  @"pins":@[fixedChrome,@{},@{},@{}]} mutableCopy];
    FSProfileNormalize(layout,NO);
    NSCAssert(FSProfileExchangeSlots(layout,1,0),@"Right-to-left exchange must succeed");
    NSCAssert([FSProfilePin(layout,1) isEqual:fixedChrome] && ![FSProfilePin(layout,0) count],
              @"Fixed Chrome must follow to the right without fixing the other Chrome");
    NSCAssert([FSProfileOccupant(layout,0) isEqual:workingChrome] &&
              [FSProfileOccupant(layout,1) isEqual:fixedChrome] &&
              [FSProfileOccupant(layout,2) isEqual:finder],@"Only the two exchanged zones may change");
    NSData *saved=[NSJSONSerialization dataWithJSONObject:layout options:0 error:NULL];
    layout=[NSJSONSerialization JSONObjectWithData:saved options:NSJSONReadingMutableContainers error:NULL];
    FSProfileNormalize(layout,NO);
    NSCAssert([FSProfilePin(layout,1) isEqual:fixedChrome],@"New fixed position must survive restart");
    NSCAssert(FSProfileExchangeSlots(layout,1,0) && [FSProfilePin(layout,0) isEqual:fixedChrome],
              @"Reverse horizontal exchange must restore the original fixed position");
    NSDictionary *absentCode=@{@"bundle":@"code",@"app":@"Code",@"title":@"closed editor"};
    FSProfileSetPin(layout,1,absentCode);
    NSCAssert(FSProfileExchangeSlots(layout,0,1),@"Exchange with a borrowed fixed zone must succeed");
    NSCAssert([FSProfilePin(layout,0) isEqual:absentCode] && [FSProfilePin(layout,1) isEqual:fixedChrome],
              @"Both the visible pin and absent pin must be preserved");
    NSDictionary *before=[NSJSONSerialization JSONObjectWithData:
        [NSJSONSerialization dataWithJSONObject:layout options:0 error:NULL] options:0 error:NULL];
    NSCAssert(!FSProfileExchangeSlots(layout,-1,1) && !FSProfileExchangeSlots(layout,0,0) &&
              !FSProfileExchangeSlots(layout,0,4) && [layout isEqual:before],@"Invalid exchange cannot edit a profile");
    puts("PASS: pin migration, automatic isolation, same-app horizontal swap, restart, absent pin preservation, explicit unpin.");
}return 0;}
