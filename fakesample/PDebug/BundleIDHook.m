//
//  BundleIDHook.m
//  PDebug
//
//  Created by fakeapp on 2025-11-30.
//  Hook Bundle ID related methods to return original IPA's Bundle ID
//

#import "BundleIDHook.h"
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import "fishhook.h"

// Static storage for original Bundle ID
static NSString *kOriginalBundleID = nil;

// C function pointers
static CFStringRef (*orig_CFBundleGetIdentifier)(CFBundleRef bundle) = NULL;
static CFTypeRef (*orig_CFBundleGetValueForInfoDictionaryKey)(CFBundleRef bundle, CFStringRef key) = NULL;

#pragma mark - C Function Hooks

CFStringRef hook_CFBundleGetIdentifier(CFBundleRef bundle)
{
    // Check if it's main bundle
    if (bundle == CFBundleGetMainBundle() && kOriginalBundleID != nil) {
        return (__bridge CFStringRef)kOriginalBundleID;
    }

    // Call original function
    if (orig_CFBundleGetIdentifier) {
        return orig_CFBundleGetIdentifier(bundle);
    }

    return NULL;
}

CFTypeRef hook_CFBundleGetValueForInfoDictionaryKey(CFBundleRef bundle, CFStringRef key)
{
    // Call original function first
    CFTypeRef value = NULL;
    if (orig_CFBundleGetValueForInfoDictionaryKey) {
        value = orig_CFBundleGetValueForInfoDictionaryKey(bundle, key);
    }

    // Check if it's main bundle querying CFBundleIdentifier
    if (bundle == CFBundleGetMainBundle() &&
        key != NULL &&
        CFStringCompare(key, CFSTR("CFBundleIdentifier"), 0) == kCFCompareEqualTo &&
        kOriginalBundleID != nil) {
        return (__bridge CFStringRef)kOriginalBundleID;
    }

    return value;
}

#pragma mark - NSBundle Category Hook

@implementation NSBundle (BundleIDHook)

+ (void)swizzleInstanceMethod:(Class)class original:(SEL)originalSelector swizzled:(SEL)swizzledSelector
{
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);

    if (!originalMethod || !swizzledMethod) {
        NSLog(@"[BundleIDHook] Failed to swizzle %@ - method not found", NSStringFromSelector(originalSelector));
        return;
    }

    BOOL didAddMethod = class_addMethod(class,
                                       originalSelector,
                                       method_getImplementation(swizzledMethod),
                                       method_getTypeEncoding(swizzledMethod));

    if (didAddMethod) {
        class_replaceMethod(class,
                           swizzledSelector,
                           method_getImplementation(originalMethod),
                           method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

#pragma mark - Hook Implementations

- (NSString *)hook_bundleIdentifier
{
    NSString *originalBundleID = [self hook_bundleIdentifier]; // Call original

    // Return fake Bundle ID only for main bundle
    if (self == [NSBundle mainBundle] && kOriginalBundleID) {
        return kOriginalBundleID;
    }

    return originalBundleID;
}

- (id)hook_objectForInfoDictionaryKey:(NSString *)key
{
    id value = [self hook_objectForInfoDictionaryKey:key]; // Call original

    // Return fake Bundle ID for main bundle when querying CFBundleIdentifier
    if (self == [NSBundle mainBundle] &&
        [key isEqualToString:@"CFBundleIdentifier"] &&
        kOriginalBundleID) {
        return kOriginalBundleID;
    }

    return value;
}

- (NSDictionary *)hook_infoDictionary
{
    NSDictionary *originalDict = [self hook_infoDictionary]; // Call original

    // Return modified dictionary for main bundle
    if (self == [NSBundle mainBundle] && kOriginalBundleID) {
        NSMutableDictionary *modifiedDict = [originalDict mutableCopy];
        modifiedDict[@"CFBundleIdentifier"] = kOriginalBundleID;
        return [modifiedDict copy];
    }

    return originalDict;
}

@end

#pragma mark - BundleIDHook Implementation

@implementation BundleIDHook

+ (void)setOriginalBundleID:(NSString *)bundleID
{
    kOriginalBundleID = [bundleID copy];
    NSLog(@"[BundleIDHook] Original Bundle ID set to: %@", kOriginalBundleID);
}

+ (NSString *)originalBundleID
{
    return kOriginalBundleID;
}

+ (void)installHooks
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self installObjCHooks];
        [self installCFunctionHooks];
        [self testHooks];
    });
}

+ (void)installObjCHooks
{
    Class bundleClass = [NSBundle class];

    // 1. Hook bundleIdentifier
    [NSBundle swizzleInstanceMethod:bundleClass
                            original:@selector(bundleIdentifier)
                           swizzled:@selector(hook_bundleIdentifier)];

    // 2. Hook objectForInfoDictionaryKey:
    [NSBundle swizzleInstanceMethod:bundleClass
                            original:@selector(objectForInfoDictionaryKey:)
                           swizzled:@selector(hook_objectForInfoDictionaryKey:)];

    // 3. Hook infoDictionary
    [NSBundle swizzleInstanceMethod:bundleClass
                            original:@selector(infoDictionary)
                           swizzled:@selector(hook_infoDictionary)];

    NSLog(@"[BundleIDHook] ObjC methods hooked: bundleIdentifier, objectForInfoDictionaryKey:, infoDictionary");
}

+ (void)installCFunctionHooks
{
    // Hook C functions using fishhook
    rebind_symbols((struct rebinding[2]){
        {"CFBundleGetIdentifier", hook_CFBundleGetIdentifier, (void **)&orig_CFBundleGetIdentifier},
        {"CFBundleGetValueForInfoDictionaryKey", hook_CFBundleGetValueForInfoDictionaryKey, (void **)&orig_CFBundleGetValueForInfoDictionaryKey}
    }, 2);

    NSLog(@"[BundleIDHook] C functions hooked: CFBundleGetIdentifier, CFBundleGetValueForInfoDictionaryKey");
}

+ (void)testHooks
{
    if (!kOriginalBundleID) {
        NSLog(@"[BundleIDHook] WARNING: Original Bundle ID not set, hooks will not work!");
        return;
    }

    // Test ObjC API
    NSString *objcBundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSLog(@"[BundleIDHook] Test - Bundle ID via ObjC API: %@", objcBundleID);

    // Test C API
    CFStringRef cBundleID = CFBundleGetIdentifier(CFBundleGetMainBundle());
    if (cBundleID) {
        NSLog(@"[BundleIDHook] Test - Bundle ID via C API: %@", (__bridge NSString *)cBundleID);
    }

    // Verify hooks are working
    if ([objcBundleID isEqualToString:kOriginalBundleID]) {
        NSLog(@"[BundleIDHook] ✅ Hooks installed successfully!");
    } else {
        NSLog(@"[BundleIDHook] ❌ Hooks may not be working correctly!");
    }
}

@end
