//
//  ECProxyURIParser.h
//  ECMAIN
//
//  Utility to parse proxy URIs (vless://, vmess://, ss://, trojan://)
//

#import <Foundation/Foundation.h>

@interface ECProxyURIParser : NSObject

/**
 * Parse a proxy URI string into a configuration dictionary.
 * Supports: vless://, vmess://, ss://, trojan://, ssr://
 * @param uri The proxy URI string
 * @return Configuration dictionary compatible with VPNConfigViewController, or
 * nil if parsing fails
 */
+ (NSDictionary *)parseProxyURI:(NSString *)uri;

/**
 * Parse a subscription content string (could be base64 encoded or plain text
 * list)
 * @param content The subscription text
 * @return Array of configuration dictionaries
 */
+ (NSArray<NSDictionary *> *)parseSubscriptionContent:(NSString *)content;

/**
 * Parse a subscription content string (could be base64 encoded or plain text
 * list) with an optional group name.
 * @param content The subscription text
 * @param groupName An optional group name to assign to parsed nodes.
 * @return Array of configuration dictionaries
 */
+ (NSArray<NSDictionary *> *)parseSubscriptionContent:(NSString *)content
                                            withGroup:(NSString *)groupName;

/**
 * Parse Clash YAML proxy definitions.
 * @param yamlContent The Clash YAML content string.
 * @param groupName An optional group name to assign to parsed nodes.
 * @return Array of configuration dictionaries.
 */
+ (NSArray<NSDictionary *> *)parseClashYAMLProxies:(NSString *)yamlContent
                                         withGroup:(NSString *)groupName;

/**
 * 将节点配置字典导出为对应协议的 URI 字符串。
 * @param node 节点配置字典
 * @return URI 字符串，如 ss://... 或 vmess://... 等，失败返回 nil
 */
+ (NSString *)exportNodeToURI:(NSDictionary *)node;

@end
