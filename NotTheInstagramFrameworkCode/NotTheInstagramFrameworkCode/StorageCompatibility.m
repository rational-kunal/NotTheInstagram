#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "RuntimeHooks.h"
#import "Vendor/fishhook/fishhook.h"

// Re-signing can remove access to Meta's storage groups. Retry only the known
// failures using storage permitted to this installed copy of Instagram.
static NSString *const NTIMetaKeychainGroup = @"group.com.facebook.family";
static NSString *const NTIProbeService = @"wtf.rational.NotTheInstagram.keychain-group-probe";
static NSString *NTIImageRoot;
static NSString *NTIBundleIdentifier;
static NSString *NTIInstalledAppGroup;
static NSURL *NTIAppGroupsURL;
static NSLock *NTIKeychainGroupLock;
static NSString *NTIKeychainGroup;

// Saved implementations let hooks call the real APIs without calling themselves.
static OSStatus (*NTIOriginalAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*NTIOriginalCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*NTIOriginalUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*NTIOriginalDelete)(CFDictionaryRef);
static IMP NTIOriginalContainerURL;

#pragma mark - Keychain storage

// Probe through Security rather than guessing that a signing-team prefix grants
// access. Each probe contains no credentials, uses a unique account, and is
// deleted immediately. A private replacement group keeps broad group queries
// from reading/deleting items in Instagram's ordinary default group.
static NSString *NTIProbeKeychainGroup(NSString *requestedGroup) {
    NSMutableDictionary *cleanup = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: NTIProbeService,
        (__bridge id)kSecAttrAccount: NSUUID.UUID.UUIDString,
    } mutableCopy];
    if (requestedGroup) cleanup[(__bridge id)kSecAttrAccessGroup] = requestedGroup;
    NSMutableDictionary *probe = cleanup.mutableCopy;
    probe[(__bridge id)kSecValueData] = NSData.data;
    probe[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    probe[(__bridge id)kSecReturnAttributes] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = NTIOriginalAdd((__bridge CFDictionaryRef)probe, &result);
    id attributes = CFBridgingRelease(result);
    if (status != errSecSuccess) {
        NSLog(@"[NTI] keychain access-group probe failed: %d", (int)status);
        return nil;
    }
    id group = [attributes isKindOfClass:NSDictionary.class]
        ? attributes[(__bridge id)kSecAttrAccessGroup] : nil;
    // Delete only this probe's unique identity; never reuse a caller's query.
    if ([group isKindOfClass:NSString.class] && [group length] > 0) {
        cleanup[(__bridge id)kSecAttrAccessGroup] = group;
    } else {
        group = nil;
        NSLog(@"[NTI] keychain probe did not return an access group");
    }
    OSStatus cleanupStatus = NTIOriginalDelete((__bridge CFDictionaryRef)cleanup);
    if (cleanupStatus != errSecSuccess && cleanupStatus != errSecItemNotFound) {
        NSLog(@"[NTI] keychain probe cleanup failed: %d", (int)cleanupStatus);
    }
    return group;
}

static NSString *NTIReplacementKeychainGroup(void) {
    // Concurrent requests must share one mapping. Cache successes only: a probe
    // may fail while the device is locked and succeed after it is unlocked.
    [NTIKeychainGroupLock lock];
    @try {
        if (NTIKeychainGroup) return NTIKeychainGroup;
        NSString *defaultGroup = NTIProbeKeychainGroup(nil);
        if (!defaultGroup) return nil;
        NSRange separator = [defaultGroup rangeOfString:@"."];
        if (separator.location == NSNotFound || separator.location == 0) return nil;
        NSString *candidate = [NSString stringWithFormat:@"%@.%@.NotTheInstagram.MetaFamily",
                               [defaultGroup substringToIndex:separator.location], NTIBundleIdentifier];
        NSString *verifiedGroup = NTIProbeKeychainGroup(candidate);
        if ([verifiedGroup isEqualToString:candidate]) {
            NTIKeychainGroup = verifiedGroup;
            NSLog(@"[NTI] keychain compatibility using verified app-owned group");
        }
        // No fallback to an unscoped/default-group query. If the provisioning
        // profile denies the private group, preserve the original error.
        return NTIKeychainGroup;
    } @finally {
        [NTIKeychainGroupLock unlock];
    }
}

static BOOL NTIHasMetaGroup(CFDictionaryRef dictionary) {
    if (!dictionary || CFGetTypeID(dictionary) != CFDictionaryGetTypeID()) return NO;
    id group = ((__bridge NSDictionary *)dictionary)[(__bridge id)kSecAttrAccessGroup];
    return [group isKindOfClass:NSString.class] && [group isEqualToString:NTIMetaKeychainGroup];
}

static NSDictionary *NTIMapGroup(CFDictionaryRef dictionary, NSString *group) {
    if (!NTIHasMetaGroup(dictionary)) return (__bridge NSDictionary *)dictionary;
    // Keep the caller's dictionary intact and change only its access group.
    NSMutableDictionary *mapped = [(__bridge NSDictionary *)dictionary mutableCopy];
    mapped[(__bridge id)kSecAttrAccessGroup] = group;
    return mapped;
}

static NSString *NTIRetryGroup(OSStatus status, CFDictionaryRef query, CFDictionaryRef attributes) {
    if (status != errSecMissingEntitlement || (!NTIHasMetaGroup(query) && !NTIHasMetaGroup(attributes))) return nil;
    return NTIReplacementKeychainGroup();
}

typedef OSStatus (*NTIKeychainResultFunction)(CFDictionaryRef, CFTypeRef *);
static OSStatus NTICallWithResult(NTIKeychainResultFunction original, CFDictionaryRef query, CFTypeRef *result) {
    // Forward the final retained result to the caller. If a retry replaces an
    // intermediate result, release that object first to preserve CF ownership.
    CFTypeRef value = NULL;
    OSStatus status = original(query, result ? &value : NULL);
    NSString *group = NTIRetryGroup(status, query, NULL);
    if (group) {
        if (value) CFRelease(value);
        value = NULL;
        NSDictionary *mapped = NTIMapGroup(query, group);
        status = original((__bridge CFDictionaryRef)mapped, result ? &value : NULL);
    }
    if (result) *result = value;
    return status;
}

static OSStatus NTISecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    return NTICallWithResult(NTIOriginalAdd, attributes, result);
}

static OSStatus NTISecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    return NTICallWithResult(NTIOriginalCopyMatching, query, result);
}

// Save, read, update and delete must use the same group across app launches.
// Each hook tries the original call first, preserving successes and other errors.
static OSStatus NTISecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    OSStatus status = NTIOriginalUpdate(query, attributes);
    NSString *group = NTIRetryGroup(status, query, attributes);
    if (!group) return status;
    NSDictionary *mappedQuery = NTIMapGroup(query, group);
    // An update may specify the access group in either dictionary.
    NSDictionary *mappedAttributes = NTIMapGroup(attributes, group);
    return NTIOriginalUpdate((__bridge CFDictionaryRef)mappedQuery,
                             (__bridge CFDictionaryRef)mappedAttributes);
}

static OSStatus NTISecItemDelete(CFDictionaryRef query) {
    OSStatus status = NTIOriginalDelete(query);
    NSString *group = NTIRetryGroup(status, query, NULL);
    if (!group) return status;
    NSDictionary *mapped = NTIMapGroup(query, group);
    return NTIOriginalDelete((__bridge CFDictionaryRef)mapped);
}

#pragma mark - Shared file storage

static BOOL NTIRecognizesAppGroup(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return NO;
    return [identifier isEqualToString:@"group.com.burbn.instagram"] ||
           [identifier isEqualToString:@"group.com.facebook.family"] ||
           [identifier isEqualToString:@"group.com.facebook.msysstorage"] ||
           [identifier isEqualToString:NTIInstalledAppGroup];
}

static NSURL *NTIContainerURL(id manager, SEL selector, NSString *identifier) {
    NSURL *original = ((NSURL *(*)(id, SEL, NSString *))NTIOriginalContainerURL)(manager, selector, identifier);
    if (original || !NTIRecognizesAppGroup(identifier)) return original;
    // Instagram expects a real path even when its shared group is unavailable.
    // A separate persistent folder per group preserves the app's stored files.
    NSURL *directory = [NTIAppGroupsURL URLByAppendingPathComponent:identifier isDirectory:YES];
    if (!directory) return nil;
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                               withIntermediateDirectories:YES
                                                attributes:@{NSFilePosixPermissions: @0700}
                                                     error:&error]) {
        NSLog(@"[NTI] app-group fallback directory failed: %ld", (long)error.code);
        return nil;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ NSLog(@"[NTI] using persistent app-owned container for unavailable Instagram groups"); });
    return directory;
}

#pragma mark - Hook installation

static NSString *NTINormalizeImagePath(NSString *path) {
    // dyld and NSBundle can spell the same iOS app path with /var or
    // /private/var. Keep the bundle filter working for either representation.
    if ([path hasPrefix:@"/private/var/"]) {
        return [path substringFromIndex:8];
    }
    return path;
}

static void NTIRebindImage(const struct mach_header *header, intptr_t slide) {
    @autoreleasepool {
        Dl_info image;
        if (!dladdr(header, &image) || !image.dli_fname) return;
        NSString *path = NTINormalizeImagePath([NSString stringWithUTF8String:image.dli_fname]);
        // Only rewrite imports belonging to Instagram, leaving system images alone.
        if (![path hasPrefix:NTIImageRoot]) return;
        static const struct rebinding bindings[] = {
            {"SecItemAdd", (void *)NTISecItemAdd},
            {"SecItemCopyMatching", (void *)NTISecItemCopyMatching},
            {"SecItemUpdate", (void *)NTISecItemUpdate},
            {"SecItemDelete", (void *)NTISecItemDelete},
        };
        if (rebind_symbols_image((void *)header, slide, bindings, sizeof(bindings) / sizeof(bindings[0])) != 0) {
            NSLog(@"[NTI] could not register keychain imports for app image");
        }
    }
}

@interface NTIStorageCompatibility : NSObject
@end

@implementation NTIStorageCompatibility
+ (void)load {
    // Synchronous installation is intentional: Instagram caches container paths
    // with dispatch_once during startup. Main-queue installation would be late.
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *identifier = bundle.bundleIdentifier;
    if (!NTIIsInstagram(identifier)) return;
    NTIBundleIdentifier = identifier;
    NTIInstalledAppGroup = [@"group." stringByAppendingString:identifier];
    NTIImageRoot = [NTINormalizeImagePath(bundle.bundlePath) stringByAppendingString:@"/"];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                        inDomains:NSUserDomainMask].firstObject;
    NTIAppGroupsURL = [support URLByAppendingPathComponent:@"NotTheInstagram/AppGroups" isDirectory:YES];
    NTIKeychainGroupLock = NSLock.new;
    NTIOriginalAdd = dlsym(RTLD_DEFAULT, "SecItemAdd");
    NTIOriginalCopyMatching = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    NTIOriginalUpdate = dlsym(RTLD_DEFAULT, "SecItemUpdate");
    NTIOriginalDelete = dlsym(RTLD_DEFAULT, "SecItemDelete");
    const NTIHook container = {"containerURLForSecurityApplicationGroupIdentifier:", (IMP)NTIContainerURL,
        &NTIOriginalContainerURL, @encode(id), 1, {@encode(id)}};
    BOOL containerHook = NTIAppGroupsURL && NTIInstallHooks(NSFileManager.class, &container, 1);
    BOOL keychainReady = NTIOriginalAdd && NTIOriginalCopyMatching && NTIOriginalUpdate && NTIOriginalDelete;
    // dyld invokes this for existing images and for images loaded later.
    if (keychainReady) _dyld_register_func_for_add_image(NTIRebindImage);
    NSLog(@"[NTI] storage compatibility initialized (container=%d, keychain imports registered=%d)",
          containerHook, keychainReady);
}
@end
