import sys
import proxy_parser

uri = "ss://YWVzLTEyOC1nY206aGFNTE1YaXJCeW42ckdWaA@4e28daff-c517-4f78-9dfb-ed1090befc64.drive-glicloudccp.com:12022?plugin=obfs-local;obfs=http;obfs-host=4cb7bdbfb634.microsoft.com;obfs-uri=/#%F0%9F%87%AD%F0%9F%87%B0%20%E9%A6%99%E6%B8%AF%2001%E4%B8%A81x%20HK"
res = proxy_parser.parse_proxy_uri(uri)
print("Result:", res)
