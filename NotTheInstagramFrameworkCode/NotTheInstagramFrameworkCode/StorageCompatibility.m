#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import "Vendor/fishhook/fishhook.h"

// Re-signing can remove access to Meta's storage groups. Retry only the known
// failures using storage permitted to this installed copy of Instagram.
static NSString *const NTIMetaKeychainGroup = @"group.com.facebook.family";
static NSString *const NTIProbeService = @"wtf.rational.NotTheInstagram.keychain-group-probe";
static NSString *NTIImageRoot;
static NSString *NTIBundleIdentifier;
static NSURL *NTIAppGroupsURL;
static NSLock *NTIKeychainGroupLock;
static NSString *NTIKeychainGroup;

// Saved implementations let hooks call the real APIs without calling themselves.
static OSStatus (*NTIOriginalAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*NTIOriginalCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*NTIOriginalUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*NTIOriginalDelete)(CFDictionaryRef);
static NSURL *(*NTIOriginalContainerURL)(id, SEL, NSString *);

#pragma mark - Keychain storage

// Probe through Security rather than guessing that a signing-team prefix grants
// access. Each probe contains no credentials, uses a unique account, and is
// deleted immediately. A private replacement group keeps broad group queries
// from reading/deleting items in Instagram's ordinary default group.
static NSString *NTIProbeKeychainGroup(NSString *requestedGroup) {
    NSDictionary *identity = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: NTIProbeService,
        (__bridge id)kSecAttrAccount: NSUUID.UUID.UUIDString,
    };
    NSMutableDictionary *probe = identity.mutableCopy;
    if (requestedGroup) probe[(__bridge id)kSecAttrAccessGroup] = requestedGroup;
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
    NSMutableDictionary *cleanup = identity.mutableCopy;
    if ([group isKindOfClass:NSString.class] && [group length] > 0) {
        cleanup[(__bridge id)kSecAttrAccessGroup] = group;
    } else {
        group = nil;
        if (requestedGroup) cleanup[(__bridge id)kSecAttrAccessGroup] = requestedGroup;
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

typedef OSStatus (*NTIKeychainResultFunction)(CFDictionaryRef, CFTypeRef *);
static OSStatus NTICallWithResult(NTIKeychainResultFunction original, CFDictionaryRef query, CFTypeRef *result) {
    // Forward the final retained result to the caller. If a retry replaces an
    // intermediate result, release that object first to preserve CF ownership.
    CFTypeRef value = NULL;
    OSStatus status = original(query, result ? &value : NULL);
    if (status == errSecMissingEntitlement && NTIHasMetaGroup(query)) {
        NSString *group = NTIReplacementKeychainGroup();
        if (group) {
            if (value) { CFRelease(value); value = NULL; }
            NSDictionary *mapped = NTIMapGroup(query, group);
            status = original((__bridge CFDictionaryRef)mapped, result ? &value : NULL);
        }
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
    if (status != errSecMissingEntitlement ||
        (!NTIHasMetaGroup(query) && !NTIHasMetaGroup(attributes))) return status;
    NSString *group = NTIReplacementKeychainGroup();
    if (!group) return status;
    NSDictionary *mappedQuery = NTIMapGroup(query, group);
    // An update may specify the access group in either dictionary.
    NSDictionary *mappedAttributes = NTIMapGroup(attributes, group);
    return NTIOriginalUpdate((__bridge CFDictionaryRef)mappedQuery,
                             (__bridge CFDictionaryRef)mappedAttributes);
}

static OSStatus NTISecItemDelete(CFDictionaryRef query) {
    OSStatus status = NTIOriginalDelete(query);
    if (status != errSecMissingEntitlement || !NTIHasMetaGroup(query)) return status;
    NSString *group = NTIReplacementKeychainGroup();
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
           [identifier isEqualToString:[@"group." stringByAppendingString:NTIBundleIdentifier]];
}

static NSURL *NTIContainerURL(id manager, SEL selector, NSString *identifier) {
    NSURL *original = NTIOriginalContainerURL(manager, selector, identifier);
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

static BOOL NTIInstallContainerHook(void) {
    Class managerClass = NSFileManager.class;
    SEL selector = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    Method method = class_getInstanceMethod(managerClass, selector);
    if (!method) return NO;
    NTIOriginalContainerURL = (void *)method_getImplementation(method);
    // Redirect the Objective-C lookup; the replacement still calls the original.
    class_replaceMethod(managerClass, selector, (IMP)NTIContainerURL, method_getTypeEncoding(method));
    return YES;
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
        struct rebinding bindings[] = {
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
    if (![identifier isEqualToString:@"com.burbn.instagram"] &&
        ![identifier hasPrefix:@"com.burbn.instagram."]) return;
    NTIBundleIdentifier = identifier;
    NTIImageRoot = [NTINormalizeImagePath(bundle.bundlePath) stringByAppendingString:@"/"];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                        inDomains:NSUserDomainMask].firstObject;
    NTIAppGroupsURL = [support URLByAppendingPathComponent:@"NotTheInstagram/AppGroups" isDirectory:YES];
    NTIKeychainGroupLock = NSLock.new;
    NTIOriginalAdd = dlsym(RTLD_DEFAULT, "SecItemAdd");
    NTIOriginalCopyMatching = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    NTIOriginalUpdate = dlsym(RTLD_DEFAULT, "SecItemUpdate");
    NTIOriginalDelete = dlsym(RTLD_DEFAULT, "SecItemDelete");
    BOOL containerHook = NTIInstallContainerHook();
    BOOL keychainReady = NTIOriginalAdd && NTIOriginalCopyMatching && NTIOriginalUpdate && NTIOriginalDelete;
    // dyld invokes this for existing images and for images loaded later.
    if (keychainReady) _dyld_register_func_for_add_image(NTIRebindImage);
    NSLog(@"[NTI] storage compatibility initialized (container=%d, keychain imports registered=%d)",
          containerHook, keychainReady);
}
@end
