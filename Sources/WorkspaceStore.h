#import <Foundation/Foundation.h>

/* Schema 4: an ordered record per window, rather than one occupant per zone.
   Record order is back-to-front within each zone; minimized/closed records stay.
   Runtime AX identities are held by the coordinator, never serialized. */
@interface FSWorkspaceStore : NSObject
@property(nonatomic,strong,readonly) NSMutableDictionary *config;
@property(nonatomic,strong,readonly) NSURL *url;
@property(nonatomic,copy,readonly) NSString *loadNote;
@property(nonatomic,readonly) BOOL saveBlocked;
- (instancetype)initWithURL:(NSURL *)url defaultDisplay:(NSString *)display;
- (instancetype)initWithConfig:(NSDictionary *)config defaultDisplay:(NSString *)display;
- (NSMutableDictionary *)activeProfile;
- (NSMutableDictionary *)profileWithID:(NSString *)identifier;
- (NSMutableDictionary *)builtin:(NSInteger)preset name:(NSString *)name display:(NSString *)display
                           layout:(NSInteger)layout ratio:(double)ratio;
- (NSMutableDictionary *)saveFavorite:(NSString *)name;
- (BOOL)deleteFavorite:(NSString *)identifier;
- (BOOL)save:(NSError **)error;
- (NSMutableDictionary *)record:(NSString *)identifier inProfile:(NSDictionary *)profile;
- (NSMutableDictionary *)addWindow:(NSDictionary *)descriptor slot:(NSInteger)slot profile:(NSMutableDictionary *)profile;
- (void)updateRecord:(NSMutableDictionary *)record descriptor:(NSDictionary *)descriptor;
- (BOOL)moveRecord:(NSString *)identifier toSlot:(NSInteger)slot profile:(NSMutableDictionary *)profile;
- (BOOL)promoteRecord:(NSString *)identifier profile:(NSMutableDictionary *)profile;
/* Conservative recovery: both the saved record and live candidate must be
   unique for a document or title. Application name alone never matches. */
- (NSDictionary<NSString *,NSString *> *)matchCandidates:(NSArray<NSDictionary *> *)candidates
                                                profile:(NSDictionary *)profile
                                             usedRecordIDs:(NSSet<NSString *> *)used;
@end
