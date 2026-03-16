#import "ECVPNConfigManager.h"

#define EC_VPN_SHARED_GROUP @"group.com.ecmain.shared"
#define EC_VPN_NODES_KEY @"VPNNodeList"
#define EC_VPN_ACTIVE_NODE_KEY @"VPNActiveNodeID"
#define EC_VPN_ROUTING_MODE_KEY                                                \
  @"VPNRoutingMode" // 0: Config, 1: Proxy, 2: Direct
#define EC_VPN_GLOBAL_NETWORK_KEY @"VPNGlobalNetworkSettings"

@implementation ECVPNConfigManager

+ (instancetype)sharedManager {
  static ECVPNConfigManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECVPNConfigManager alloc] init];
  });
  return instance;
}

- (NSUserDefaults *)sharedDefaults {
  return [[NSUserDefaults alloc] initWithSuiteName:EC_VPN_SHARED_GROUP];
}

- (NSArray<NSDictionary *> *)allNodes {
  NSArray *nodes = [[self sharedDefaults] arrayForKey:EC_VPN_NODES_KEY];
  return nodes ? nodes : @[];
}

- (void)saveNodes:(NSArray<NSDictionary *> *)nodes {
  [[self sharedDefaults] setObject:nodes forKey:EC_VPN_NODES_KEY];
  [[self sharedDefaults] synchronize];
}

- (void)addNode:(NSDictionary *)node {
  NSMutableArray *nodes = [[self allNodes] mutableCopy];
  NSMutableDictionary *newNode = [node mutableCopy];
  if (!newNode[@"id"]) {
    newNode[@"id"] = [[NSUUID UUID] UUIDString];
  }
  [nodes addObject:newNode];
  [self saveNodes:nodes];
}

- (void)updateNode:(NSDictionary *)node {
  if (!node[@"id"])
    return;

  NSMutableArray *nodes = [[self allNodes] mutableCopy];
  for (NSUInteger i = 0; i < nodes.count; i++) {
    if ([nodes[i][@"id"] isEqualToString:node[@"id"]]) {
      nodes[i] = node;
      [self saveNodes:nodes];
      return;
    }
  }
}

- (void)deleteNodeWithID:(NSString *)nodeID {
  NSMutableArray *nodes = [[self allNodes] mutableCopy];
  NSPredicate *predicate =
      [NSPredicate predicateWithFormat:@"id != %@", nodeID];
  [nodes filterUsingPredicate:predicate];
  [self saveNodes:nodes];

  if ([[self activeNodeID] isEqualToString:nodeID]) {
    [self setActiveNodeID:nil];
  }
}

- (NSDictionary *)nodeWithID:(NSString *)nodeID {
  if (!nodeID)
    return nil;
  for (NSDictionary *node in [self allNodes]) {
    if ([node[@"id"] isEqualToString:nodeID]) {
      return node;
    }
  }
  return nil;
}

- (void)setActiveNodeID:(NSString *)nodeID {
  if (nodeID) {
    [[self sharedDefaults] setObject:nodeID forKey:EC_VPN_ACTIVE_NODE_KEY];
  } else {
    [[self sharedDefaults] removeObjectForKey:EC_VPN_ACTIVE_NODE_KEY];
  }
  [[self sharedDefaults] synchronize];
}

- (NSString *)activeNodeID {
  return [[self sharedDefaults] stringForKey:EC_VPN_ACTIVE_NODE_KEY];
}

- (NSDictionary *)activeNode {
  return [self nodeWithID:[self activeNodeID]];
}

- (NSInteger)routingMode {
  return [[self sharedDefaults] integerForKey:EC_VPN_ROUTING_MODE_KEY];
}

- (void)setRoutingMode:(NSInteger)mode {
  [[self sharedDefaults] setInteger:mode forKey:EC_VPN_ROUTING_MODE_KEY];
  [[self sharedDefaults] synchronize];
}

- (NSDictionary *)globalNetworkSettings {
  NSDictionary *settings =
      [[self sharedDefaults] dictionaryForKey:EC_VPN_GLOBAL_NETWORK_KEY];
  return settings ? settings : @{};
}

- (void)saveGlobalNetworkSettings:(NSDictionary *)settings {
  if (settings) {
    [[self sharedDefaults] setObject:settings forKey:EC_VPN_GLOBAL_NETWORK_KEY];
  } else {
    [[self sharedDefaults] removeObjectForKey:EC_VPN_GLOBAL_NETWORK_KEY];
  }
  [[self sharedDefaults] synchronize];
}

@end
