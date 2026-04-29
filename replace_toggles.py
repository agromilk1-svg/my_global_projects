import re

file_path = "/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m"

with open(file_path, "r") as f:
    content = f.read()

replacements = {
    r'\[config\s+spoofBoolForKey:@"enableNetworkInterception"\s+defaultValue:YES\]': 'EC_ENABLE_NETWORK_INTERCEPT',
    r'\[config\s+spoofBoolForKey:@"enableMethodSwizzling"\s+defaultValue:YES\]': '1',
    r'\[config\s+spoofBoolForKey:@"enableNSCFLocaleHooks"\s+defaultValue:YES\]': 'EC_ENABLE_NSCFLOCALE_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableCFLocaleHooks"\s+defaultValue:YES\]': 'EC_ENABLE_CFLOCALE_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableCarrierHooks"\s+defaultValue:NO\]': 'EC_ENABLE_CARRIER_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableTikTokHooks"\s+defaultValue:YES\]': 'EC_ENABLE_TIKTOK_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableSysctlHooks"\s+defaultValue:YES\]': 'EC_ENABLE_SYSCTL_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableMobileGestaltHooks"\s+defaultValue:YES\]': 'EC_ENABLE_MOBILEGESTALT_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableCFBundleFishhook"\s+defaultValue:YES\]': 'EC_ENABLE_CFBUNDLE_FISHHOOK',
    r'\[config\s+spoofBoolForKey:@"enableISASwizzling"\s+defaultValue:YES\]': 'EC_ENABLE_ISA_SWIZZLING',
    r'\[config\s+spoofBoolForKey:@"enableDiskBatteryHooks"\s+defaultValue:YES\]': 'EC_ENABLE_DISK_BATTERY_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableAntiDetectionHooks"\s+defaultValue:YES\]': 'EC_ENABLE_ANTI_DETECTION',
    r'\[config\s+spoofBoolForKey:@"enableKeychainIsolation"\s+defaultValue:YES\]': 'EC_ENABLE_KEYCHAIN_ISOLATION',
    r'\[config\s+spoofBoolForKey:@"enableUIDeviceHooks"\s+defaultValue:YES\]': 'EC_ENABLE_UIDEVICE_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableIDFVHook"\s+defaultValue:YES\]': 'EC_ENABLE_IDFV_HOOK',
    r'\[config\s+spoofBoolForKey:@"enableUIScreenHooks"\s+defaultValue:YES\]': 'EC_ENABLE_UISCREEN_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableNetworkL1"\s+defaultValue:YES\]': 'EC_ENABLE_NETWORK_INTERCEPT',
    r'\[config\s+spoofBoolForKey:@"enableNetworkL2"\s+defaultValue:YES\]': 'EC_ENABLE_NETWORK_INTERCEPT',
    r'\[config\s+spoofBoolForKey:@"enableNetworkL3"\s+defaultValue:YES\]': 'EC_ENABLE_NETWORK_INTERCEPT',
}

# Add multiline version of the same replacements
replacements_multiline = {
    r'\[config\s+spoofBoolForKey:@"enableNetworkInterception"[\s\n]+defaultValue:YES\]': 'EC_ENABLE_NETWORK_INTERCEPT',
    r'\[config\s+spoofBoolForKey:@"enableMethodSwizzling"[\s\n]+defaultValue:YES\]': '1',
    r'\[config\s+spoofBoolForKey:@"enableNSCFLocaleHooks"[\s\n]+defaultValue:YES\]': 'EC_ENABLE_NSCFLOCALE_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableMobileGestaltHooks"[\s\n]+defaultValue:YES\]': 'EC_ENABLE_MOBILEGESTALT_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableCFBundleFishhook"[\s\n]+defaultValue:YES\]': 'EC_ENABLE_CFBUNDLE_FISHHOOK',
    r'\[config\s+spoofBoolForKey:@"enableDiskBatteryHooks"[\s\n]+defaultValue:YES\]': 'EC_ENABLE_DISK_BATTERY_HOOKS',
    r'\[config\s+spoofBoolForKey:@"enableAntiDetectionHooks"[\s\n]+defaultValue:YES\]': 'EC_ENABLE_ANTI_DETECTION',
    r'\[config\s+spoofBoolForKey:@"enableKeychainIsolation"[\s\n]+defaultValue:YES\]': 'EC_ENABLE_KEYCHAIN_ISOLATION',
}

for pattern, replacement in replacements.items():
    content = re.sub(pattern, replacement, content)

for pattern, replacement in replacements_multiline.items():
    content = re.sub(pattern, replacement, content)

with open(file_path, "w") as f:
    f.write(content)

print("Done replacing.")
