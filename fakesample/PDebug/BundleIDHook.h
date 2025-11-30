//
//  BundleIDHook.h
//  PDebug
//
//  Created by fakeapp on 2025-11-30.
//  Hook Bundle ID related methods to return original IPA's Bundle ID
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BundleIDHook : NSObject

/**
 * Set the original Bundle ID from IPA
 * Call this before installing hooks
 */
+ (void)setOriginalBundleID:(NSString *)bundleID;

/**
 * Install all Bundle ID hooks (ObjC methods + C functions)
 */
+ (void)installHooks;

/**
 * Get the current fake Bundle ID
 */
+ (NSString * _Nullable)originalBundleID;

@end

NS_ASSUME_NONNULL_END
