#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECVPNConfigManager : NSObject

+ (instancetype)sharedManager;

- (NSArray<NSDictionary *> *)allNodes;
- (void)saveNodes:(NSArray<NSDictionary *> *)nodes;
- (void)addNode:(NSDictionary *)node;
- (void)updateNode:(NSDictionary *)node;
- (void)deleteNodeWithID:(NSString *)nodeID;
- (nullable NSDictionary *)nodeWithID:(NSString *)nodeID;

- (void)setActiveNodeID:(nullable NSString *)nodeID;
- (nullable NSString *)activeNodeID;
- (nullable NSDictionary *)activeNode;

// 0: Config (配置), 1: Proxy (代理), 2: Direct (直连)
- (NSInteger)routingMode;
- (void)setRoutingMode:(NSInteger)mode;

- (NSDictionary *)globalNetworkSettings;
- (void)saveGlobalNetworkSettings:(NSDictionary *)settings;

@end

NS_ASSUME_NONNULL_END
