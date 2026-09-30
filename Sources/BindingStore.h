#import <Foundation/Foundation.h>

/* Schema 3: pins are durable user choices; bindings remember recent occupants.
   Automatic placement is allowed to edit bindings only. */
void FSProfileNormalize(NSMutableDictionary *profile, BOOL migrateLegacyPins);
NSDictionary *FSProfilePin(NSDictionary *profile, NSInteger slot);
NSDictionary *FSProfileOccupant(NSDictionary *profile, NSInteger slot);
void FSProfileSetPin(NSMutableDictionary *profile, NSInteger slot, NSDictionary *descriptor);
void FSProfileSetOccupant(NSMutableDictionary *profile, NSInteger slot, NSDictionary *descriptor);
