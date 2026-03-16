//
//  ECProxyURIParser.m
//  ECMAIN
//
//  Parses various proxy URI formats into config dictionaries
//

#import "ECProxyURIParser.h"
#import "ECVPNConfigManager.h"

@implementation ECProxyURIParser

+ (NSDictionary *)parseProxyURI:(NSString *)uri {
  if (!uri || uri.length == 0)
    return nil;

  uri = [uri
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];

  if ([uri hasPrefix:@"vless://"]) {
    return [self parseVLESS:uri];
  } else if ([uri hasPrefix:@"vmess://"]) {
    return [self parseVMess:uri];
  } else if ([uri hasPrefix:@"ss://"]) {
    return [self parseShadowsocks:uri];
  } else if ([uri hasPrefix:@"ssr://"]) {
    return [self parseShadowsocksR:uri];
  } else if ([uri hasPrefix:@"trojan://"]) {
    return [self parseTrojan:uri];
  } else if ([uri hasPrefix:@"trojan://"]) {
    return [self parseTrojan:uri];
  } else if ([uri hasPrefix:@"socks://"]) {
    return [self parseSocks:uri];
  } else if ([uri hasPrefix:@"{"] || [uri hasPrefix:@"["]) {
    // Loose JSON / Object Syntax
    return [self parseLooseJSON:uri];
  }

  return nil;
}

#pragma mark - Loose JSON Parser

+ (NSDictionary *)parseLooseJSON:(NSString *)content {
  // Basic cleanup: remove { } [ ]
  content = [content stringByReplacingOccurrencesOfString:@"{" withString:@""];
  content = [content stringByReplacingOccurrencesOfString:@"}" withString:@""];
  content = [content stringByReplacingOccurrencesOfString:@"[" withString:@""];
  content = [content stringByReplacingOccurrencesOfString:@"]" withString:@""];

  NSMutableDictionary *config = [NSMutableDictionary dictionary];

  // Split by comma
  NSArray *pairs = [content componentsSeparatedByString:@","];
  for (NSString *pair in pairs) {
    NSRange colon = [pair rangeOfString:@":"];
    if (colon.location != NSNotFound) {
      NSString *key = [[pair substringToIndex:colon.location]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSString *val = [[pair substringFromIndex:colon.location + 1]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];

      // Map keys
      if ([key isEqualToString:@"type"]) {
        if ([val.lowercaseString isEqualToString:@"ssr"])
          config[@"type"] = @"ShadowsocksR";
        else if ([val.lowercaseString isEqualToString:@"ss"])
          config[@"type"] = @"Shadowsocks";
        else
          config[@"type"] = val;
      } else if ([key isEqualToString:@"server"])
        config[@"server"] = val;
      else if ([key isEqualToString:@"port"])
        config[@"port"] = val;
      else if ([key isEqualToString:@"password"])
        config[@"password"] = val;
      else if ([key isEqualToString:@"cipher"] ||
               [key isEqualToString:@"method"])
        config[@"cipher"] = val;
      else if ([key isEqualToString:@"protocol"])
        config[@"protocol"] = val;
      else if ([key isEqualToString:@"obfs"])
        config[@"obfs"] = val;
      else if ([key isEqualToString:@"protocol-param"])
        config[@"protocol-param"] = val;
      else if ([key isEqualToString:@"obfs-param"])
        config[@"obfs-param"] = val;
      else if ([key isEqualToString:@"udp"]) {
        config[@"udp"] =
            [val.lowercaseString isEqualToString:@"true"] ? @YES : @NO;
      }
    }
  }

  // Default type if missing but has SSR params
  if (!config[@"type"]) {
    if (config[@"protocol"] && config[@"obfs"]) {
      config[@"type"] = @"ShadowsocksR";
    } else {
      config[@"type"] = @"Shadowsocks";
    }
  }

  return config;
}

#pragma mark - Socks Parser

+ (NSDictionary *)parseSocks:(NSString *)uri {
  NSMutableDictionary *config = [NSMutableDictionary dictionary];
  config[@"type"] = @"Socks5";

  NSString *content = [uri substringFromIndex:8]; // "socks://".length

  // Extract query parameters and fragment
  NSDictionary *params = @{};
  NSString *name = nil;

  NSRange fragmentRange = [content rangeOfString:@"#"];
  if (fragmentRange.location != NSNotFound) {
    name = [content substringFromIndex:fragmentRange.location + 1];
    name = [name stringByRemovingPercentEncoding];
    content = [content substringToIndex:fragmentRange.location];
  }

  NSRange queryRange = [content rangeOfString:@"?"];
  if (queryRange.location != NSNotFound) {
    NSString *queryString =
        [content substringFromIndex:queryRange.location + 1];
    params = [self parseQueryString:queryString];
    content = [content substringToIndex:queryRange.location];
  }

  // content is usually Base64 encoded: user:pass@server:port
  NSString *decoded = [self decodeBase64:content];
  if (!decoded || decoded.length == 0) {
    // maybe it is just raw string
    decoded = content;
  }

  NSRange atRange = [decoded rangeOfString:@"@"];
  if (atRange.location != NSNotFound) {
    NSString *auth = [decoded substringToIndex:atRange.location];
    NSString *serverPort = [decoded substringFromIndex:atRange.location + 1];

    NSRange colonAuthRange = [auth rangeOfString:@":"];
    if (colonAuthRange.location != NSNotFound) {
      config[@"user"] = [auth substringToIndex:colonAuthRange.location];
      config[@"password"] =
          [auth substringFromIndex:colonAuthRange.location + 1];
    }

    NSRange colonRange = [serverPort rangeOfString:@":"
                                           options:NSBackwardsSearch];
    if (colonRange.location != NSNotFound) {
      config[@"server"] = [serverPort substringToIndex:colonRange.location];
      config[@"port"] = [serverPort substringFromIndex:colonRange.location + 1];
    }
  } else {
    // No auth
    NSRange colonRange = [decoded rangeOfString:@":" options:NSBackwardsSearch];
    if (colonRange.location != NSNotFound) {
      config[@"server"] = [decoded substringToIndex:colonRange.location];
      config[@"port"] = [decoded substringFromIndex:colonRange.location + 1];
    } else {
      config[@"server"] = decoded;
    }
  }

  if (name)
    config[@"name"] = name;

  if (params[@"method"])
    config[@"cipher"] = params[@"method"];
  if (params[@"dialer-proxy"]) {
    config[@"proxy_through_id"] =
        params[@"dialer-proxy"]; // Store the literal name/id
  }

  return config;
}

#pragma mark - VLESS Parser

+ (NSDictionary *)parseVLESS:(NSString *)uri {
  // Format: vless://[UUID]@[SERVER]:[PORT]?[PARAMS]#[NAME]
  NSMutableDictionary *config = [NSMutableDictionary dictionary];
  config[@"type"] = @"VLESS";

  // Remove prefix
  NSString *content = [uri substringFromIndex:8]; // "vless://".length

  // Extract fragment (name)
  NSString *name = nil;
  NSRange fragmentRange = [content rangeOfString:@"#"];
  if (fragmentRange.location != NSNotFound) {
    name = [content substringFromIndex:fragmentRange.location + 1];
    name = [name stringByRemovingPercentEncoding];
    content = [content substringToIndex:fragmentRange.location];
  }

  // Extract query parameters
  NSDictionary *params = @{};
  NSRange queryRange = [content rangeOfString:@"?"];
  if (queryRange.location != NSNotFound) {
    NSString *queryString =
        [content substringFromIndex:queryRange.location + 1];
    params = [self parseQueryString:queryString];
    content = [content substringToIndex:queryRange.location];
  }

  // Parse UUID@server:port
  NSRange atRange = [content rangeOfString:@"@"];
  if (atRange.location == NSNotFound)
    return nil;

  NSString *uuid = [content substringToIndex:atRange.location];
  NSString *serverPort = [content substringFromIndex:atRange.location + 1];

  // Parse server:port
  NSRange colonRange = [serverPort rangeOfString:@":"
                                         options:NSBackwardsSearch];
  if (colonRange.location == NSNotFound)
    return nil;

  NSString *server = [serverPort substringToIndex:colonRange.location];
  NSString *port = [serverPort substringFromIndex:colonRange.location + 1];

  config[@"uuid"] = uuid;
  config[@"server"] = server;
  config[@"port"] = port;

  // Map query params to config
  if (params[@"flow"])
    config[@"flow"] = params[@"flow"];
  if (params[@"type"])
    config[@"network"] = params[@"type"];
  if (params[@"sni"])
    config[@"servername"] = params[@"sni"];
  if (params[@"fp"])
    config[@"client-fingerprint"] = params[@"fp"];

  // Security/TLS handling
  NSString *security = params[@"security"];
  if ([security isEqualToString:@"reality"] ||
      [security isEqualToString:@"tls"]) {
    config[@"tls"] = @YES;
  }

  // Reality options
  if (params[@"pbk"]) {
    config[@"reality-opts"] =
        @{@"public-key" : params[@"pbk"], @"short-id" : params[@"sid"] ?: @""};
  }

  // UDP (default true for VLESS)
  config[@"udp"] = @YES;

  return config;
}

#pragma mark - VMess Parser

+ (NSDictionary *)parseVMess:(NSString *)uri {
  // Format: vmess://[BASE64_JSON]
  NSMutableDictionary *config = [NSMutableDictionary dictionary];
  config[@"type"] = @"VMess";

  NSString *content = [uri substringFromIndex:8]; // "vmess://".length

  // Decode Base64
  NSData *data = [[NSData alloc] initWithBase64EncodedString:content options:0];
  if (!data) {
    // Try URL-safe Base64
    content = [[content stringByReplacingOccurrencesOfString:@"-"
                                                  withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_"
                                  withString:@"/"];
    data = [[NSData alloc] initWithBase64EncodedString:content options:0];
  }
  if (!data)
    return nil;

  NSError *error = nil;
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:&error];
  if (error || !json)
    return nil;

  config[@"server"] = json[@"add"] ?: json[@"host"] ?: @"";
  config[@"port"] = [NSString stringWithFormat:@"%@", json[@"port"] ?: @"443"];
  config[@"uuid"] = json[@"id"] ?: @"";
  config[@"alterId"] = [NSString stringWithFormat:@"%@", json[@"aid"] ?: @"0"];
  config[@"cipher"] = json[@"scy"] ?: @"auto";
  config[@"network"] = json[@"net"] ?: @"tcp";

  if ([json[@"tls"] isEqualToString:@"tls"]) {
    config[@"tls"] = @YES;
  }

  if (json[@"path"])
    config[@"ws-path"] = json[@"path"];
  if (json[@"host"])
    config[@"ws-host"] = json[@"host"];

  return config;
}

#pragma mark - Shadowsocks Parser

+ (NSDictionary *)parseShadowsocks:(NSString *)uri {
  // Format 1 (SIP002): ss://[BASE64(method:password)]@server:port#name
  // Format 2 (Legacy): ss://[BASE64(method:password@server:port)]#name
  NSMutableDictionary *config = [NSMutableDictionary dictionary];
  config[@"type"] = @"Shadowsocks";

  NSString *content = [uri substringFromIndex:5]; // "ss://".length

  // Extract fragment (name)
  NSRange fragmentRange = [content rangeOfString:@"#"];
  if (fragmentRange.location != NSNotFound) {
    content = [content substringToIndex:fragmentRange.location];
  }

  // Check for SIP002 format (has @ after base64)
  NSRange atRange = [content rangeOfString:@"@"];
  if (atRange.location != NSNotFound) {
    // SIP002 format
    NSString *base64Part = [content substringToIndex:atRange.location];
    NSString *serverPart = [content substringFromIndex:atRange.location + 1];

    // Decode method:password
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Part
                                                       options:0];
    if (!data) {
      base64Part = [[base64Part stringByReplacingOccurrencesOfString:@"-"
                                                          withString:@"+"]
          stringByReplacingOccurrencesOfString:@"_"
                                    withString:@"/"];
      data = [[NSData alloc] initWithBase64EncodedString:base64Part options:0];
    }

    if (data) {
      NSString *decoded = [[NSString alloc] initWithData:data
                                                encoding:NSUTF8StringEncoding];
      NSRange colonRange = [decoded rangeOfString:@":"];
      if (colonRange.location != NSNotFound) {
        config[@"cipher"] = [decoded substringToIndex:colonRange.location];
        config[@"password"] =
            [decoded substringFromIndex:colonRange.location + 1];
      }
    }

    // Parse server:port
    NSRange portRange = [serverPart rangeOfString:@":"
                                          options:NSBackwardsSearch];
    if (portRange.location != NSNotFound) {
      config[@"server"] = [serverPart substringToIndex:portRange.location];
      config[@"port"] = [serverPart substringFromIndex:portRange.location + 1];
    }
  } else {
    // Legacy format - entire thing is base64
    NSData *data = [[NSData alloc] initWithBase64EncodedString:content
                                                       options:0];
    if (!data)
      return nil;

    NSString *decoded = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
    // Format: method:password@server:port
    NSRange atRange2 = [decoded rangeOfString:@"@"];
    if (atRange2.location == NSNotFound)
      return nil;

    NSString *methodPass = [decoded substringToIndex:atRange2.location];
    NSString *serverPort = [decoded substringFromIndex:atRange2.location + 1];

    NSRange colonRange = [methodPass rangeOfString:@":"];
    if (colonRange.location != NSNotFound) {
      config[@"cipher"] = [methodPass substringToIndex:colonRange.location];
      config[@"password"] =
          [methodPass substringFromIndex:colonRange.location + 1];
    }

    NSRange portRange = [serverPort rangeOfString:@":"
                                          options:NSBackwardsSearch];
    if (portRange.location != NSNotFound) {
      config[@"server"] = [serverPort substringToIndex:portRange.location];
      config[@"port"] = [serverPort substringFromIndex:portRange.location + 1];
    }
  }

  config[@"udp"] = @YES;

  return config;
}

#pragma mark - ShadowsocksR Parser

+ (NSDictionary *)parseShadowsocksR:(NSString *)uri {
  // Format: ssr://[BASE64]
  NSMutableDictionary *config = [NSMutableDictionary dictionary];
  config[@"type"] = @"ShadowsocksR";

  NSString *content = [uri substringFromIndex:6]; // "ssr://".length
  NSString *rawContent = [content copy];          // Preserve for fallback

  // Decode Base64 (Standard SSR Link)
  content = [[content stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
      stringByReplacingOccurrencesOfString:@"_"
                                withString:@"/"];
  NSData *data = [[NSData alloc] initWithBase64EncodedString:content options:0];

  BOOL isPlaintextMode = NO;
  NSString *decoded = nil;
  if (data) {
    decoded = [[NSString alloc] initWithData:data
                                    encoding:NSUTF8StringEncoding];
    NSLog(@"[SSR] Base64 Decoded: %@", decoded);
  } else {
    // Fallback: Assume Plaintext (Use RAW content to avoid + / corruption)
    decoded = rawContent;
    isPlaintextMode = YES;
    NSLog(@"[SSR] Using Plaintext Fallback: %@", decoded);
  }

  if (!decoded) {
    NSLog(@"[SSR] Failed to decode content.");
    return nil;
  }

  // Separate Main Part and Query Params (Handle /?)
  // Doing this BEFORE splitting by ':' ensures params containing ':' aren't
  // broken.
  NSString *mainPart = decoded;
  NSString *queryString = nil;

  NSRange queryRange = [decoded rangeOfString:@"/?"];
  if (queryRange.location != NSNotFound) {
    mainPart = [decoded substringToIndex:queryRange.location];
    queryString = [decoded substringFromIndex:queryRange.location + 2];
  }

  // Parse Main Part: server:port:protocol:method:obfs:password
  NSArray *parts = [mainPart componentsSeparatedByString:@":"];
  if (parts.count < 6) {
    NSLog(@"[SSR] Error: Not enough parts. Count: %lu",
          (unsigned long)parts.count);
    return nil;
  }

  config[@"server"] = parts[0];
  config[@"port"] = parts[1];
  config[@"protocol"] = parts[2];
  config[@"cipher"] = parts[3];
  config[@"obfs"] = parts[4];

  NSString *passwordPart = parts[5];

  // Password Decoding
  if (isPlaintextMode) {
    config[@"password"] = passwordPart;
  } else {
    // Standard Mode: Try Base64, but without aggressive padding
    // This ensures that simple plaintext passwords (like "di15PV") which aren't
    // valid Base64 length don't get forced into garbage decoding.
    NSString *base64Pass =
        [passwordPart stringByReplacingOccurrencesOfString:@"-"
                                                withString:@"+"];
    base64Pass = [base64Pass stringByReplacingOccurrencesOfString:@"_"
                                                       withString:@"/"];

    NSData *passData = [[NSData alloc] initWithBase64EncodedString:base64Pass
                                                           options:0];
    if (passData) {
      config[@"password"] =
          [[NSString alloc] initWithData:passData
                                encoding:NSUTF8StringEncoding];
    } else {
      config[@"password"] = passwordPart;
    }
  }

  // Parse Query Params
  if (queryString) {
    NSDictionary *params = [self parseQueryString:queryString];

    // Helper block to safely decode param
    NSString * (^decodeParam)(NSString *) = ^NSString *(NSString *raw) {
      if (!raw)
        return nil;
      if ([raw containsString:@":"])
        return raw; // Plaintext check

      NSString *b64 = [raw stringByReplacingOccurrencesOfString:@"-"
                                                     withString:@"+"];
      b64 = [b64 stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
      NSInteger p = b64.length % 4;
      if (p > 0)
        b64 = [b64 stringByPaddingToLength:b64.length + (4 - p)
                                withString:@"="
                           startingAtIndex:0];

      NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
      if (d) {
        NSString *res = [[NSString alloc] initWithData:d
                                              encoding:NSUTF8StringEncoding];
        return res ?: raw;
      }
      return raw;
    };

    if (params[@"protoparam"]) {
      config[@"protocol-param"] = decodeParam(params[@"protoparam"]);
    }
    if (params[@"obfsparam"]) {
      config[@"obfs-param"] = decodeParam(params[@"obfsparam"]);
    }
  }

  return config;
}

#pragma mark - Trojan Parser

+ (NSDictionary *)parseTrojan:(NSString *)uri {
  // Format: trojan://[PASSWORD]@[SERVER]:[PORT]?[PARAMS]#[NAME]
  NSMutableDictionary *config = [NSMutableDictionary dictionary];
  config[@"type"] = @"Trojan";

  NSString *content = [uri substringFromIndex:9]; // "trojan://".length

  // Extract fragment (name)
  NSRange fragmentRange = [content rangeOfString:@"#"];
  if (fragmentRange.location != NSNotFound) {
    content = [content substringToIndex:fragmentRange.location];
  }

  // Extract query parameters
  NSDictionary *params = @{};
  NSRange queryRange = [content rangeOfString:@"?"];
  if (queryRange.location != NSNotFound) {
    NSString *queryString =
        [content substringFromIndex:queryRange.location + 1];
    params = [self parseQueryString:queryString];
    content = [content substringToIndex:queryRange.location];
  }

  // Parse password@server:port
  NSRange atRange = [content rangeOfString:@"@"];
  if (atRange.location == NSNotFound)
    return nil;

  NSString *password = [content substringToIndex:atRange.location];
  NSString *serverPort = [content substringFromIndex:atRange.location + 1];

  NSRange colonRange = [serverPort rangeOfString:@":"
                                         options:NSBackwardsSearch];
  if (colonRange.location == NSNotFound)
    return nil;

  config[@"password"] = [password stringByRemovingPercentEncoding];
  config[@"server"] = [serverPort substringToIndex:colonRange.location];
  config[@"port"] = [serverPort substringFromIndex:colonRange.location + 1];

  if (params[@"sni"])
    config[@"sni"] = params[@"sni"];
  if (params[@"type"])
    config[@"network"] = params[@"type"];

  return config;
}

#pragma mark - Helpers

+ (NSDictionary *)parseQueryString:(NSString *)queryString {
  NSMutableDictionary *params = [NSMutableDictionary dictionary];
  NSArray *pairs = [queryString componentsSeparatedByString:@"&"];

  for (NSString *pair in pairs) {
    NSRange eqRange = [pair rangeOfString:@"="];
    if (eqRange.location != NSNotFound) {
      NSString *key = [pair substringToIndex:eqRange.location];
      NSString *value = [pair substringFromIndex:eqRange.location + 1];
      value = [value stringByRemovingPercentEncoding];
      params[key] = value;
    }
  }

  return params;
}

+ (NSString *)decodeBase64:(NSString *)base64Str {
  if (!base64Str || base64Str.length == 0)
    return nil;
  NSString *padded = base64Str;
  if (padded.length % 4 != 0) {
    NSUInteger paddingLength = 4 - (padded.length % 4);
    padded = [padded stringByPaddingToLength:padded.length + paddingLength
                                  withString:@"="
                             startingAtIndex:0];
  }
  NSData *data = [[NSData alloc]
      initWithBase64EncodedString:padded
                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
  if (data) {
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  }
  return nil;
}

+ (NSArray<NSDictionary *> *)parseClashYAMLProxies:(NSString *)yamlContent
                                         withGroup:(NSString *)groupName {
  NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
  NSArray *lines = [yamlContent
      componentsSeparatedByCharactersInSet:[NSCharacterSet
                                               newlineCharacterSet]];

  NSRegularExpression *regex = [NSRegularExpression
      regularExpressionWithPattern:
          @"([a-zA-Z0-9_-]+)\\s*:\\s*(.*?)\\s*(?=,\\s*[a-zA-Z0-9_-]+\\s*:|$)"
                           options:0
                             error:nil];

  for (NSString *line in lines) {
    NSString *trimmed = [line
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"- {"] && [trimmed hasSuffix:@"}"]) {
      NSString *inner =
          [trimmed substringWithRange:NSMakeRange(3, trimmed.length - 4)];

      NSMutableDictionary *dict = [NSMutableDictionary dictionary];
      NSArray *matches = [regex matchesInString:inner
                                        options:0
                                          range:NSMakeRange(0, inner.length)];
      for (NSTextCheckingResult *match in matches) {
        NSString *key = [inner substringWithRange:[match rangeAtIndex:1]];
        NSString *value = [inner substringWithRange:[match rangeAtIndex:2]];

        if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""] &&
            value.length >= 2) {
          value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        } else if ([value hasPrefix:@"'"] && [value hasSuffix:@"'"] &&
                   value.length >= 2) {
          value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        }

        dict[key] = value;
      }

      if (dict[@"server"] && dict[@"port"]) {
        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"server"] = dict[@"server"];
        node[@"port"] = @([dict[@"port"] integerValue]);
        NSString *type = [dict[@"type"] lowercaseString];
        if ([type isEqualToString:@"ss"])
          node[@"type"] = @"Shadowsocks";
        else if ([type isEqualToString:@"ssr"])
          node[@"type"] = @"ShadowsocksR";
        else if ([type isEqualToString:@"vmess"])
          node[@"type"] = @"VMess";
        else if ([type isEqualToString:@"vless"])
          node[@"type"] = @"VLESS";
        else if ([type isEqualToString:@"trojan"])
          node[@"type"] = @"Trojan";
        else if ([type isEqualToString:@"hysteria"])
          node[@"type"] = @"Hysteria";
        else if ([type isEqualToString:@"hysteria2"])
          node[@"type"] = @"Hysteria2";
        else if ([type isEqualToString:@"tuic"])
          node[@"type"] = @"Tuic";
        else if ([type isEqualToString:@"wireguard"])
          node[@"type"] = @"WireGuard";
        else if ([type isEqualToString:@"socks5"])
          node[@"type"] = @"Socks5";
        else if ([type isEqualToString:@"http"])
          node[@"type"] = @"HTTP";
        else if ([type isEqualToString:@"https"])
          node[@"type"] = @"HTTPS";
        else if ([type isEqualToString:@"snell"])
          node[@"type"] = @"Snell";
        else
          continue;

        node[@"id"] = [[NSUUID UUID] UUIDString];
        node[@"name"] =
            dict[@"name"]
                ?: [NSString stringWithFormat:@"%@:%@", node[@"server"],
                                              node[@"port"]];
        node[@"password"] = dict[@"password"] ?: @"";
        if (dict[@"cipher"])
          node[@"cipher"] = dict[@"cipher"];
        if (dict[@"uuid"])
          node[@"uuid"] = dict[@"uuid"];
        if (dict[@"sni"])
          node[@"sni"] = dict[@"sni"];
        if (dict[@"obfs"])
          node[@"obfs"] = dict[@"obfs"];
        if (dict[@"protocol"])
          node[@"protocol"] = dict[@"protocol"];
        if (dict[@"obfs-param"])
          node[@"obfs-param"] = dict[@"obfs-param"];
        if (dict[@"protocol-param"])
          node[@"protocol-param"] = dict[@"protocol-param"];
        if (dict[@"network"])
          node[@"network"] = dict[@"network"];
        if (dict[@"tls"])
          node[@"tls"] = @([dict[@"tls"] boolValue]);
        if (dict[@"udp"])
          node[@"udp"] = @([dict[@"udp"] boolValue]);
        node[@"group"] = groupName ?: @"Default";

        [results addObject:node];
      }
    }
  }
  return results;
}

+ (NSArray<NSDictionary *> *)parseSubscriptionContent:(NSString *)content {
  return [self parseSubscriptionContent:content withGroup:@"Default"];
}

+ (NSArray<NSDictionary *> *)parseSubscriptionContent:(NSString *)content
                                            withGroup:(NSString *)groupName {
  NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
  if (!content || content.length == 0)
    return results;

  // Detect Clash YAML format inline rules
  if ([content rangeOfString:@"proxies:"].location != NSNotFound &&
      [content rangeOfString:@"- {name:"].location != NSNotFound) {
    return [self parseClashYAMLProxies:content withGroup:groupName];
  }

  // Check if it's our powerful custom config array
  if ([content hasPrefix:@"ecnode://"]) {
    NSString *b64 = [content substringFromIndex:9];
    NSString *jsonStr = [self decodeBase64:b64];
    if (jsonStr) {
      NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
      id jsonObj = [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:nil];
      if ([jsonObj isKindOfClass:[NSArray class]]) {
        for (NSDictionary *dict in jsonObj) {
          NSMutableDictionary *mut = [dict mutableCopy];
          mut[@"group"] = groupName ?: @"Default";
          [results addObject:mut];
        }
        return results;
      }
    }
  }

  // Check if it's base64 encoded
  NSString *decodedContent = [self decodeBase64:content];
  if (decodedContent && decodedContent.length > 0 &&
      [decodedContent containsString:@"://"]) {
    content = decodedContent; // Replace with decoded multiline string if it
                              // contains standard scheme
  }

  // Split by newlines
  NSArray *lines =
      [content componentsSeparatedByCharactersInSet:[NSCharacterSet
                                                        newlineCharacterSet]];

  for (NSString *line in lines) {
    NSString *trimmed = [line
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
      continue;

    NSDictionary *parsed = [self parseProxyURI:trimmed];
    if (parsed) {
      NSMutableDictionary *mutableParsed = [parsed mutableCopy];
      mutableParsed[@"group"] = groupName ?: @"Default";
      [results addObject:mutableParsed];
    }
  }

  return results;
}

#pragma mark - 节点导出

+ (NSString *)exportNodeToURI:(NSDictionary *)node {
  NSMutableArray *exportList = [NSMutableArray arrayWithObject:node];
  NSString *proxyThroughId = node[@"proxy_through_id"];

  // 检查是否包含代理通过（链式中转）
  if (proxyThroughId && proxyThroughId.length > 0) {
    NSDictionary *target =
        [[ECVPNConfigManager sharedManager] nodeWithID:proxyThroughId];
    if (target) {
      [exportList addObject:target];
    }
  }

  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:exportList
                                                     options:0
                                                       error:nil];
  NSString *b64 = [jsonData base64EncodedStringWithOptions:0];
  return [NSString stringWithFormat:@"ecnode://%@", b64];
}

@end
