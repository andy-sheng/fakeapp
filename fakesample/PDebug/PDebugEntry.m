//
//  PDebugEntry.m
//  Portal
//
//  Created by Ethan on 15/3/5.
//  Copyright (c) 2015年 com. All rights reserved.
//

#import "PDebugEntry.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>
#import "fishhook.h"

static void * (*orig_dlsym)(void *, const char *);

// Original Bundle ID from IPA (will be set at runtime)
static NSString *kOriginalBundleID = nil;

// C function pointers
static CFStringRef (*orig_CFBundleGetIdentifier)(CFBundleRef bundle);
static CFTypeRef (*orig_CFBundleGetValueForInfoDictionaryKey)(CFBundleRef bundle, CFStringRef key);

int my_ptrace(int _request, pid_t _pid, caddr_t _addr, int _data)
{
    return 0;
}

void * my_dlsym(void * __handle, const char * __symbol)
{
    if (strcmp(__symbol, "ptrace") == 0) {
        return &my_ptrace;
    }

    return orig_dlsym(__handle, __symbol);
}

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

#pragma mark - NSBundle Hook

@implementation NSBundle (BundleIDHook)

+ (void)hookBundleIdentifier
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class bundleClass = [NSBundle class];

        // 1. Hook bundleIdentifier
        [self swizzleInstanceMethod:bundleClass
                           original:@selector(bundleIdentifier)
                          swizzled:@selector(hook_bundleIdentifier)];

        // 2. Hook objectForInfoDictionaryKey:
        [self swizzleInstanceMethod:bundleClass
                           original:@selector(objectForInfoDictionaryKey:)
                          swizzled:@selector(hook_objectForInfoDictionaryKey:)];

        // 3. Hook infoDictionary
        [self swizzleInstanceMethod:bundleClass
                           original:@selector(infoDictionary)
                          swizzled:@selector(hook_infoDictionary)];

        NSLog(@"[PDebug] NSBundle methods hooked");
    });
}

+ (void)swizzleInstanceMethod:(Class)class original:(SEL)originalSelector swizzled:(SEL)swizzledSelector
{
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);

    if (!originalMethod || !swizzledMethod) {
        NSLog(@"[PDebug] Failed to swizzle %@ - method not found", NSStringFromSelector(originalSelector));
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

#pragma mark - PDebugEntry

@implementation PDebugEntry

+(void)load
{
    // Hook dlsym for anti-debugging
    orig_dlsym = dlsym(RTLD_DEFAULT, "dlsym");
    rebind_symbols((struct rebinding[1]){{"dlsym", my_dlsym, (void **)&orig_dlsym}}, 1);

    // Set original Bundle ID (TODO: read from config file)
    kOriginalBundleID = @"com.ss.iphone.ugc.Aweme";  // Example: TikTok

    // Hook C functions for Bundle ID
    rebind_symbols((struct rebinding[2]){
        {"CFBundleGetIdentifier", hook_CFBundleGetIdentifier, (void **)&orig_CFBundleGetIdentifier},
        {"CFBundleGetValueForInfoDictionaryKey", hook_CFBundleGetValueForInfoDictionaryKey, (void **)&orig_CFBundleGetValueForInfoDictionaryKey}
    }, 2);

    // Hook ObjC NSBundle methods
    [NSBundle hookBundleIdentifier];

    NSLog(@"[PDebug] Injected successfully");
    NSLog(@"[PDebug] Original Bundle ID set to: %@", kOriginalBundleID);
    NSLog(@"[PDebug] ObjC methods hooked: bundleIdentifier, objectForInfoDictionaryKey:, infoDictionary");
    NSLog(@"[PDebug] C functions hooked: CFBundleGetIdentifier, CFBundleGetValueForInfoDictionaryKey");
    NSLog(@"[PDebug] Current Bundle ID (via ObjC): %@", [[NSBundle mainBundle] bundleIdentifier]);

    // Test C API
    CFStringRef cBundleID = CFBundleGetIdentifier(CFBundleGetMainBundle());
    if (cBundleID) {
        NSLog(@"[PDebug] Current Bundle ID (via C API): %@", (__bridge NSString *)cBundleID);
    }
}

@end
