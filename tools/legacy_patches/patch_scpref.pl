#!/usr/bin/perl
undef $/;
my $file = "/Users/hh/Desktop/my/ECMAIN/Dylib/SCPrefLoader.m";
open my $fh, '<', $file or die "Cannot open $file: $!";
my $content = <$fh>;
close $fh;

my $search = qr/const char \*homeEnv = getenv\("HOME"\);.*?\}\s*\}\s*else\s*\{.*?self\.currentBundleId,\s*self\.currentCloneId\];\s*\}/s;

my $replace = <<'REPLACE';
    // [v2255 致命漏洞修复] 绝对禁止依赖 getenv("HOME")！
    // 在 TrollStore 或 AppExt/PluginKit 环境下，HOME 指向各个极其深且不断变化的动态沙盒，
    // 导致克隆版本永远读不到 ECMAIN 中控推送到设备公共存储区的 device.plist，被迫 fallback 回内置配置，从而所有号数据完全一致！
    // 我们强制统一使用设备的全局公共目录 (TrollStore app 具有访问权限)。
    NSString *globalPath = @"/var/mobile/Documents/.com.apple.UIKit.pboard";
    cachedDataDir = [NSString stringWithFormat:@"%@/session_%@", globalPath, self.currentCloneId];
REPLACE

if ($content =~ s/$search/$replace/) {
    open my $fh_out, '>', $file or die "Cannot open $file for writing: $!";
    print $fh_out $content;
    close $fh_out;
    print "Patched SCPrefLoader.m successfully.\n";
} else {
    print "Failed to find the target block in SCPrefLoader.m\n";
}
