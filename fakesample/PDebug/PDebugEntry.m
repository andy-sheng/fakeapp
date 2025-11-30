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
#import "fishhook.h"
#import "BundleIDHook.h"

static void * (*orig_dlsym)(void *, const char *);

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

@implementation PDebugEntry

+(void)load
{
    // Hook dlsym for anti-debugging
    orig_dlsym = dlsym(RTLD_DEFAULT, "dlsym");
    rebind_symbols((struct rebinding[1]){{"dlsym", my_dlsym}}, 1);

    // Set original Bundle ID (TODO: read from config file)
    NSString *originalBundleID = @"com.ss.iphone.ugc.Aweme";  // Example: TikTok
    [BundleIDHook setOriginalBundleID:originalBundleID];

    // Install Bundle ID hooks (ObjC + C functions)
    [BundleIDHook installHooks];

    NSLog(@"[PDebug] Injected successfully");
}

@end
