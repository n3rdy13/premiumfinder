//
//  PremiumFinder.m
//  Runtime inspector for premium / IAP feature gates in an injected iOS app.
//  Pure ObjC runtime swizzling. No CydiaSubstrate, no Logos.
//
//  SAFETY MODEL:
//    - Constructor does almost nothing (no swizzling/scan at dyld time).
//    - The inspector is ARMED after the app has a key window (default), which
//      avoids touching the runtime during startup. Opt into load-time arming
//      with PF_EARLY=1 if you need to catch startup-time checks.
//    - The class scan/hook is restricted to the APP'S OWN CODE (main binary +
//      embedded frameworks) by default, so system/framework methods are never
//      swizzled. Opt into system classes with PF_SYSTEM=1.
//    - All NSUserDefaults taps guard that the key is an NSString.
//    - Kill switch: PF_DISABLE=1 / PremiumFinder.disable disables everything.
//
//  On launch it pops a keyword-entry box (deferred until a window exists).
//  Generic keywords in kKeywords[] are ALWAYS active.
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

#pragma mark - Logging

static NSArray<NSString *> *g_logPaths = nil;
static pthread_mutex_t g_logLock = PTHREAD_MUTEX_INITIALIZER;

static void PFLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[PremiumFinder] %@", msg);
    if (g_logPaths.count == 0) return;
    NSString *line = [msg stringByAppendingString:@"\n"];
    pthread_mutex_lock(&g_logLock);
    for (NSString *p in g_logPaths) {
        FILE *f = fopen(p.fileSystemRepresentation, "a");
        if (f) { const char *c = line.UTF8String; fwrite(c, 1, strlen(c), f); fclose(f); }
    }
    pthread_mutex_unlock(&g_logLock);
}

static NSMutableDictionary *g_counts = nil;
static pthread_mutex_t g_countLock = PTHREAD_MUTEX_INITIALIZER;

static BOOL PFShouldLog(SEL sel) {
    if (!g_counts) g_counts = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:sel_getName(sel)];
    pthread_mutex_lock(&g_countLock);
    int c = [g_counts[key] intValue];
    g_counts[key] = @(c + 1);
    pthread_mutex_unlock(&g_countLock);
    return c < 30;
}

#pragma mark - Keywords

static const char *kKeywords[] = {
    "premium", "ispremium", "haspremium", "premiumuser", "premiumfeature",
    "subscription", "subscribe", "subscriber", "subscribed", "renew",
    "purchase", "purchased", "purchasing", "restorepurchase",
    "unlock", "entitlement", "entitled",
    "fullversion", "full_version", "proversion", "pro_version",
    "ispro", "haspro", "prouser", "pro_user", "profeature",
    "ispurchased", "haspurchased", "ispaid", "haspaid",
    "vip", "membership",
    "freemium", "paywall", "pay_wall", "upgrade",
    "receipt", "storekit", "inapp", "in_app", "iap",
    "productidentifier", "product_id", "productid",
    "trial", "istrial", "trialperiod",
    "adfree", "ad_free", "noads", "no_ads", "removeads", "remove_ads", "adremoved",
    "licens", "activation", "coupon", "discount", "restore", "credit"
};

static NSArray<NSString *> *g_extraKeywords = nil;

static BOOL PFMatches(const char *s) {
    if (!s) return NO;
    char buf[512];
    size_t n = strlen(s);
    if (n >= sizeof(buf)) n = sizeof(buf) - 1;
    for (size_t i = 0; i < n; i++) buf[i] = (char)tolower((unsigned char)s[i]);
    buf[n] = 0;

    for (size_t i = 0; i < sizeof(kKeywords)/sizeof(kKeywords[0]); i++)
        if (strstr(buf, kKeywords[i])) return YES;

    NSArray *extra = g_extraKeywords;
    if (extra) {
        for (NSString *kw in extra) {
            const char *k = kw.UTF8String;
            if (k && k[0] && strstr(buf, k)) return YES;
        }
    }
    return NO;
}

#pragma mark - Keyword config (files / env / defaults)

static NSArray<NSString *> *pf_keyword_config_paths(void) {
    NSMutableArray *paths = [NSMutableArray array];
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

    [paths addObject:@"/var/mobile/Media/PremiumFinder.keywords"];
    [paths addObject:@"/tmp/PremiumFinder.keywords"];
    if (bid.length) {
        [paths addObject:[@"/var/mobile/Media" stringByAppendingPathComponent:
                       [bid stringByAppendingString:@".keywords"]]];
        [paths addObject:[@"/tmp" stringByAppendingPathComponent:
                       [bid stringByAppendingString:@".keywords"]]];
    }
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs) {
        [paths addObject:[docs stringByAppendingPathComponent:@"PremiumFinder.keywords"]];
        if (bid.length)
            [paths addObject:[docs stringByAppendingPathComponent:
                          [bid stringByAppendingString:@".keywords"]]];
    }
    NSString *b = [[NSBundle mainBundle] pathForResource:@"PremiumFinder" ofType:@"keywords"];
    if (b) [paths addObject:b];
    if (bid.length) {
        NSString *bb = [[NSBundle mainBundle] pathForResource:bid ofType:@"keywords"];
        if (bb) [paths addObject:bb];
    }
    return paths;
}

static NSUInteger pf_parse_keywords_text(NSString *content, NSMutableArray *out) {
    if (!content) return 0;
    NSUInteger added = 0;
    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"#"]) continue;
        NSArray *toks = [line componentsSeparatedByCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@", \t"]];
        for (NSString *t in toks) {
            NSString *tok = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (!tok.length) continue;
            NSString *low = tok.lowercaseString;
            if (low.length && ![out containsObject:low]) { [out addObject:low]; added++; }
        }
    }
    return added;
}

static NSUInteger pf_load_keywords_from_file(NSString *path, NSMutableArray *out) {
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    return pf_parse_keywords_text(content, out);
}

static void pf_reload_keywords(void) {
    NSMutableArray *kw = [NSMutableArray array];

    const char *env = getenv("PF_KEYWORDS");
    if (env && *env) {
        NSString *s = [NSString stringWithUTF8String:env];
        NSArray *toks = [s componentsSeparatedByCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@",\t "]];
        for (NSString *t in toks) {
            NSString *tok = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (tok.length) { NSString *low = tok.lowercaseString;
                if (![kw containsObject:low]) [kw addObject:low]; }
        }
    }

    NSArray *udList = [[NSUserDefaults standardUserDefaults] arrayForKey:@"PFKeywords"];
    if ([udList isKindOfClass:[NSArray class]]) {
        for (id o in udList) if ([o isKindOfClass:[NSString class]]) {
            NSString *low = [o lowercaseString];
            if (low.length && ![kw containsObject:low]) [kw addObject:low];
        }
    }

    NSMutableArray *loadedFrom = [NSMutableArray array];
    for (NSString *p in pf_keyword_config_paths()) {
        NSUInteger n = pf_load_keywords_from_file(p, kw);
        if (n) [loadedFrom addObject:[NSString stringWithFormat:@"%@ (+%lu)", p, (unsigned long)n]];
    }

    g_extraKeywords = kw.count ? [kw copy] : nil;

    PFLog(@"keywords: generic=%lu extra=%lu",
          (unsigned long)(sizeof(kKeywords)/sizeof(kKeywords[0])),
          (unsigned long)kw.count);
    if (loadedFrom.count)
        PFLog(@"keyword sources: %@", [loadedFrom componentsJoinedByString:@", "]);
    if (kw.count)
        PFLog(@"extra keywords: %@", kw);
}

static NSString *pf_kw_signature(void) {
    NSMutableString *sig = [NSMutableString string];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in pf_keyword_config_paths()) {
        NSDictionary *a = [fm attributesOfItemAtPath:p error:NULL];
        if (a) {
            NSTimeInterval m = [[a fileModificationDate] timeIntervalSince1970];
            [sig appendFormat:@"%@:%lld:%llu;", p, (long long)m,
             (unsigned long long)[a fileSize]];
        }
    }
    return sig;
}

#pragma mark - Hook table

#define PF_MAX_HOOKS 16384

typedef struct { char sel[256]; IMP orig; char rtype; Class cls; } PFHook;
static PFHook g_hooks[PF_MAX_HOOKS];
static int g_hookCount = 0;
static pthread_mutex_t g_hookLock = PTHREAD_MUTEX_INITIALIZER;

// SDK-portable return-type lookup.
static char pf_return_type_char(Method m) {
    char buf[64];
    buf[0] = 0;
    method_getReturnType(m, buf, sizeof(buf));
    return buf[0];
}

static BOOL PFHooked(Class cls, SEL sel) {
    const char *n = sel_getName(sel);
    pthread_mutex_lock(&g_hookLock);
    BOOL r = NO;
    for (int i = 0; i < g_hookCount; i++)
        if (g_hooks[i].cls == cls && strcmp(g_hooks[i].sel, n) == 0) { r = YES; break; }
    pthread_mutex_unlock(&g_hookLock);
    return r;
}

static IMP PFOrigFor(id self, SEL sel) {
    Class c = object_getClass(self);
    const char *n = sel_getName(sel);
    IMP found = NULL;
    pthread_mutex_lock(&g_hookLock);
    while (c && !found) {
        for (int i = 0; i < g_hookCount; i++)
            if (g_hooks[i].cls == c && strcmp(g_hooks[i].sel, n) == 0) { found = g_hooks[i].orig; break; }
        c = class_getSuperclass(c);
    }
    pthread_mutex_unlock(&g_hookLock);
    return found;
}

static void PFInstall(Class cls, SEL sel, IMP hook) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || !enc[0]) return;              // no reliable encoding -> don't hook
    char rc = pf_return_type_char(m);
    IMP orig = method_getImplementation(m);

    if (class_addMethod(cls, sel, hook, enc)) {
        // added to this class; `orig` remains the inherited implementation
    } else {
        Method own = class_getInstanceMethod(cls, sel);
        orig = method_getImplementation(own);
        method_setImplementation(own, hook);
    }

    pthread_mutex_lock(&g_hookLock);
    if (g_hookCount < PF_MAX_HOOKS) {
        PFHook *h = &g_hooks[g_hookCount++];
        strncpy(h->sel, sel_getName(sel), sizeof(h->sel) - 1);
        h->sel[sizeof(h->sel) - 1] = 0;
        h->orig = orig; h->rtype = rc; h->cls = cls;
    }
    pthread_mutex_unlock(&g_hookLock);
}

#pragma mark - Generic hooks

static void pf_imp_void(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    if (o) ((void(*)(id, SEL))o)(self, _cmd);
    else PFLog(@"!! missing original for -[%s]; call skipped", sel_getName(_cmd));
    if (PFShouldLog(_cmd))
        PFLog(@"%@ -[%s] called", NSStringFromClass(object_getClass(self)), sel_getName(_cmd));
}
static BOOL pf_imp_bool(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    BOOL r = o ? ((BOOL(*)(id, SEL))o)(self, _cmd) : NO;
    if (PFShouldLog(_cmd))
        PFLog(@"%@ -[%s] -> %@", NSStringFromClass(object_getClass(self)), sel_getName(_cmd), r ? @"YES" : @"NO");
    return r;
}
static id pf_imp_id(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    id r = o ? ((id(*)(id, SEL))o)(self, _cmd) : nil;
    if (PFShouldLog(_cmd)) {
        @try { PFLog(@"%@ -[%s] -> %@", NSStringFromClass(object_getClass(self)), sel_getName(_cmd), r); }
        @catch (__unused NSException *e) { PFLog(@"%@ -[%s] -> <unprintable>", NSStringFromClass(object_getClass(self)), sel_getName(_cmd)); }
    }
    return r;
}
static long long pf_imp_int(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    long long r = o ? ((long long(*)(id, SEL))o)(self, _cmd) : 0;
    if (PFShouldLog(_cmd))
        PFLog(@"%@ -[%s] -> %lld", NSStringFromClass(object_getClass(self)), sel_getName(_cmd), r);
    return r;
}
static float pf_imp_float(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    float r = o ? ((float(*)(id, SEL))o)(self, _cmd) : 0;
    if (PFShouldLog(_cmd))
        PFLog(@"%@ -[%s] -> %f", NSStringFromClass(object_getClass(self)), sel_getName(_cmd), r);
    return r;
}
static double pf_imp_double(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    double r = o ? ((double(*)(id, SEL))o)(self, _cmd) : 0;
    if (PFShouldLog(_cmd))
        PFLog(@"%@ -[%s] -> %f", NSStringFromClass(object_getClass(self)), sel_getName(_cmd), r);
    return r;
}
static IMP pf_hook_for_type(char rt) {
    switch (rt) {
        case 'v': return (IMP)pf_imp_void;
        case 'B': case 'c': return (IMP)pf_imp_bool;
        case '@': return (IMP)pf_imp_id;
        case 'i': case 'I': case 'l': case 'L':
        case 'q': case 'Q': case 's': case 'S': case 'C': return (IMP)pf_imp_int;
        case 'f': return (IMP)pf_imp_float;
        case 'd': return (IMP)pf_imp_double;
        default: return NULL;
    }
}

#pragma mark - NSUserDefaults hooks (key-guarded)

static inline NSString *pf_str(id o) {
    return [o isKindOfClass:[NSString class]] ? (NSString *)o : nil;
}

static id pf_ud_objectForKey(id self, SEL _cmd, id key) {
    IMP o = PFOrigFor(self, _cmd);
    id r = o ? ((id(*)(id, SEL, id))o)(self, _cmd, key) : nil;
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) { @try { PFLog(@"defaults[%@] object = %@", k, r); } @catch (id e) {} }
    return r;
}
static BOOL pf_ud_boolForKey(id self, SEL _cmd, id key) {
    IMP o = PFOrigFor(self, _cmd);
    BOOL r = o ? ((BOOL(*)(id, SEL, id))o)(self, _cmd, key) : NO;
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) PFLog(@"defaults[%@] bool = %@", k, r ? @"YES" : @"NO");
    return r;
}
static long long pf_ud_integerForKey(id self, SEL _cmd, id key) {
    IMP o = PFOrigFor(self, _cmd);
    long long r = o ? ((long long(*)(id, SEL, id))o)(self, _cmd, key) : 0;
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) PFLog(@"defaults[%@] integer = %lld", k, r);
    return r;
}
static float pf_ud_floatForKey(id self, SEL _cmd, id key) {
    IMP o = PFOrigFor(self, _cmd);
    float r = o ? ((float(*)(id, SEL, id))o)(self, _cmd, key) : 0;
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) PFLog(@"defaults[%@] float = %f", k, r);
    return r;
}
static double pf_ud_doubleForKey(id self, SEL _cmd, id key) {
    IMP o = PFOrigFor(self, _cmd);
    double r = o ? ((double(*)(id, SEL, id))o)(self, _cmd, key) : 0;
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) PFLog(@"defaults[%@] double = %f", k, r);
    return r;
}
static id pf_ud_stringForKey(id self, SEL _cmd, id key) {
    IMP o = PFOrigFor(self, _cmd);
    id r = o ? ((id(*)(id, SEL, id))o)(self, _cmd, key) : nil;
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) PFLog(@"defaults[%@] string = %@", k, r);
    return r;
}
static id pf_ud_arrayForKey(id self, SEL _cmd, id key)      { IMP o=PFOrigFor(self,_cmd); id r=o?((id(*)(id,SEL,id))o)(self,_cmd,key):nil; NSString *k=pf_str(key); if(k&&PFMatches(k.UTF8String)) PFLog(@"defaults[%@] array = %@",k,r); return r; }
static id pf_ud_dictionaryForKey(id self, SEL _cmd, id key) { IMP o=PFOrigFor(self,_cmd); id r=o?((id(*)(id,SEL,id))o)(self,_cmd,key):nil; NSString *k=pf_str(key); if(k&&PFMatches(k.UTF8String)) PFLog(@"defaults[%@] dict = %@",k,r); return r; }
static id pf_ud_dataForKey(id self, SEL _cmd, id key)       { IMP o=PFOrigFor(self,_cmd); id r=o?((id(*)(id,SEL,id))o)(self,_cmd,key):nil; NSString *k=pf_str(key); if(k&&PFMatches(k.UTF8String)) PFLog(@"defaults[%@] data = %@",k,r); return r; }

static void pf_ud_setBool(id self, SEL _cmd, BOOL v, id key) {
    IMP o = PFOrigFor(self, _cmd);
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) PFLog(@"defaults SET [%@] bool = %@", k, v ? @"YES" : @"NO");
    if (o) ((void(*)(id, SEL, BOOL, id))o)(self, _cmd, v, key);
}
static void pf_ud_setInteger(id self, SEL _cmd, long long v, id key) {
    IMP o = PFOrigFor(self, _cmd);
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) PFLog(@"defaults SET [%@] integer = %lld", k, v);
    if (o) ((void(*)(id, SEL, long long, id))o)(self, _cmd, v, key);
}
static void pf_ud_setFloat(id self, SEL _cmd, float v, id key) {
    IMP o = PFOrigFor(self, _cmd);
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) PFLog(@"defaults SET [%@] float = %f", k, v);
    if (o) ((void(*)(id, SEL, float, id))o)(self, _cmd, v, key);
}
static void pf_ud_setObject(id self, SEL _cmd, id v, id key) {
    IMP o = PFOrigFor(self, _cmd);
    NSString *k = pf_str(key);
    if (k && PFMatches(k.UTF8String)) { @try { PFLog(@"defaults SET [%@] obj = %@", k, v); } @catch (id e) {} }
    if (o) ((void(*)(id, SEL, id, id))o)(self, _cmd, v, key);
}
static void pf_ud_registerDefaults(id self, SEL _cmd, NSDictionary *reg) {
    IMP o = PFOrigFor(self, _cmd);
    if ([reg isKindOfClass:[NSDictionary class]])
        for (id kk in reg) { NSString *k = pf_str(kk);
            if (k && PFMatches(k.UTF8String)) { @try { PFLog(@"registerDefaults[%@] = %@", k, reg[kk]); } @catch (id e) {} } }
    if (o) ((void(*)(id, SEL, id))o)(self, _cmd, reg);
}
static id pf_ud_dictRep(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    id r = o ? ((id(*)(id, SEL))o)(self, _cmd) : nil;
    if (PFShouldLog(_cmd) && [r isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)r;
        for (id kk in d) { NSString *k = pf_str(kk);
            if (k && PFMatches(k.UTF8String)) { @try { PFLog(@"defaults snapshot [%@] = %@", k, d[kk]); } @catch (id e) {} } }
    }
    return r;
}

#pragma mark - Bundle / FileManager / StoreKit hooks

static id pf_bundle_receiptURL(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    id r = o ? ((id(*)(id, SEL))o)(self, _cmd) : nil;
    PFLog(@"NSBundle appStoreReceiptURL -> %@", r);
    return r;
}
static BOOL pf_fm_fileExists(id self, SEL _cmd, id path) {
    IMP o = PFOrigFor(self, _cmd);
    BOOL r = o ? ((BOOL(*)(id, SEL, id))o)(self, _cmd, path) : NO;
    NSString *s = pf_str(path);
    if (s && [s.lowercaseString containsString:@"receipt"]) PFLog(@"fileExistsAtPath:%@ -> %@", s, r ? @"YES" : @"NO");
    return r;
}
static void pf_sk_addPayment(id self, SEL _cmd, id payment) {
    IMP o = PFOrigFor(self, _cmd);
    @try { PFLog(@"[IAP] addPayment product=%@", [payment valueForKey:@"productIdentifier"]); } @catch (__unused NSException *e) {}
    if (o) ((void(*)(id, SEL, id))o)(self, _cmd, payment);
}
static void pf_sk_finish(id self, SEL _cmd, id txn) {
    IMP o = PFOrigFor(self, _cmd);
    @try { PFLog(@"[IAP] finishTransaction product=%@ state=%ld", [[txn valueForKey:@"payment"] valueForKey:@"productIdentifier"], (long)[[txn valueForKey:@"transactionState"] integerValue]); } @catch (__unused NSException *e) {}
    if (o) ((void(*)(id, SEL, id))o)(self, _cmd, txn);
}
static void pf_sk_restore(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    PFLog(@"[IAP] restoreCompletedTransactions");
    if (o) ((void(*)(id, SEL))o)(self, _cmd);
}
static id pf_spr_init(id self, SEL _cmd, NSSet *ids) {
    IMP o = PFOrigFor(self, _cmd);
    id r = o ? ((id(*)(id, SEL, id))o)(self, _cmd, ids) : self;
    PFLog(@"[IAP] SKProductsRequest ids=%@", ids);
    return r;
}
static void pf_spr_start(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    PFLog(@"[IAP] SKProductsRequest start");
    if (o) ((void(*)(id, SEL))o)(self, _cmd);
}
static id pf_sk_generic_id(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    id r = o ? ((id(*)(id, SEL))o)(self, _cmd) : nil;
    if (PFShouldLog(_cmd)) PFLog(@"[IAP] -[%s] = %@", sel_getName(_cmd), r);
    return r;
}
static long long pf_txn_state(id self, SEL _cmd) {
    IMP o = PFOrigFor(self, _cmd);
    long long r = o ? ((long long(*)(id, SEL))o)(self, _cmd) : 0;
    if (PFShouldLog(_cmd)) PFLog(@"[IAP] transactionState = %lld", r);
    return r;
}
static void pf_pq_updated(id self, SEL _cmd, id q, NSArray *txns) {
    IMP o = PFOrigFor(self, _cmd);
    if (o) ((void(*)(id, SEL, id, id))o)(self, _cmd, q, txns);
    for (id t in txns) {
        @try {
            NSInteger state = [[t valueForKey:@"transactionState"] integerValue];
            id pid = [[t valueForKey:@"payment"] valueForKey:@"productIdentifier"];
            PFLog(@"[IAP] updatedTransactions product=%@ state=%ld", pid, (long)state);
        } @catch (__unused NSException *e) {}
    }
}
static void pf_pq_products(id self, SEL _cmd, id req, id resp) {
    IMP o = PFOrigFor(self, _cmd);
    @try { PFLog(@"[IAP] productsResponse products=%@ invalid=%@", [resp valueForKey:@"products"], [resp valueForKey:@"invalidProductIdentifiers"]); } @catch (__unused NSException *e) {}
    if (o) ((void(*)(id, SEL, id, id))o)(self, _cmd, req, resp);
}

#pragma mark - Platform hook installation

static void pf_install_platform(void) {
    Class ud = objc_getClass("NSUserDefaults");
    if (ud) {
        PFInstall(ud, sel_registerName("objectForKey:"),        (IMP)pf_ud_objectForKey);
        PFInstall(ud, sel_registerName("boolForKey:"),          (IMP)pf_ud_boolForKey);
        PFInstall(ud, sel_registerName("integerForKey:"),       (IMP)pf_ud_integerForKey);
        PFInstall(ud, sel_registerName("floatForKey:"),         (IMP)pf_ud_floatForKey);
        PFInstall(ud, sel_registerName("doubleForKey:"),        (IMP)pf_ud_doubleForKey);
        PFInstall(ud, sel_registerName("stringForKey:"),        (IMP)pf_ud_stringForKey);
        PFInstall(ud, sel_registerName("arrayForKey:"),         (IMP)pf_ud_arrayForKey);
        PFInstall(ud, sel_registerName("dictionaryForKey:"),    (IMP)pf_ud_dictionaryForKey);
        PFInstall(ud, sel_registerName("dataForKey:"),          (IMP)pf_ud_dataForKey);
        PFInstall(ud, sel_registerName("setBool:forKey:"),      (IMP)pf_ud_setBool);
        PFInstall(ud, sel_registerName("setInteger:forKey:"),   (IMP)pf_ud_setInteger);
        PFInstall(ud, sel_registerName("setFloat:forKey:"),     (IMP)pf_ud_setFloat);
        PFInstall(ud, sel_registerName("setObject:forKey:"),    (IMP)pf_ud_setObject);
        PFInstall(ud, sel_registerName("registerDefaults:"),    (IMP)pf_ud_registerDefaults);
        PFInstall(ud, sel_registerName("dictionaryRepresentation"), (IMP)pf_ud_dictRep);
    }
    Class nb = objc_getClass("NSBundle");
    if (nb) PFInstall(nb, sel_registerName("appStoreReceiptURL"), (IMP)pf_bundle_receiptURL);

    Class fm = objc_getClass("NSFileManager");
    if (fm) PFInstall(fm, sel_registerName("fileExistsAtPath:"), (IMP)pf_fm_fileExists);

    Class skq = objc_getClass("SKPaymentQueue");
    if (skq) {
        PFInstall(skq, sel_registerName("addPayment:"),                 (IMP)pf_sk_addPayment);
        PFInstall(skq, sel_registerName("finishTransaction:"),          (IMP)pf_sk_finish);
        PFInstall(skq, sel_registerName("restoreCompletedTransactions"),(IMP)pf_sk_restore);
    }
    Class spr = objc_getClass("SKProductsRequest");
    if (spr) {
        PFInstall(spr, sel_registerName("initWithProductIdentifiers:"), (IMP)pf_spr_init);
        PFInstall(spr, sel_registerName("start"),                       (IMP)pf_spr_start);
    }
    Class sp = objc_getClass("SKProduct");
    if (sp) {
        PFInstall(sp, sel_registerName("productIdentifier"), (IMP)pf_sk_generic_id);
        PFInstall(sp, sel_registerName("localizedTitle"),    (IMP)pf_sk_generic_id);
        PFInstall(sp, sel_registerName("price"),             (IMP)pf_sk_generic_id);
    }
    Class st = objc_getClass("SKPaymentTransaction");
    if (st) PFInstall(st, sel_registerName("transactionState"), (IMP)pf_txn_state);
}

#pragma mark - Class scan (app-owned classes by default)

static NSMutableSet *g_loggedClasses = nil;
static NSMutableSet *g_seenMethods   = nil;

static const char *kNever[] = {
    "dealloc", "init", "initialize", "load", "alloc", "new", "copy", "mutableCopy",
    "retain", "release", "autorelease", "hash", "class", "self", "description",
    "debugDescription", "superclass", "delegate"
};

// Is this class defined inside the app bundle (main binary or embedded framework)?
static BOOL pf_class_in_app(Class cls) {
    const char *img = class_getImageName(cls);
    if (!img) return NO;
    static NSString *marker = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];   // .../App.app
        NSString *name = bundlePath.lastPathComponent;               // App.app
        if (name.length) marker = [NSString stringWithFormat:@"/%@/", name];
    });
    if (!marker) return NO;
    NSString *p = [NSString stringWithUTF8String:img];
    return p && [p containsString:marker];
}

static BOOL pf_system_classes_enabled(void) {
    const char *e = getenv("PF_SYSTEM");
    if (e && e[0] && e[0] != '0') return YES;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"PFSystemClasses"]) return YES;
    return NO;
}

static void pf_scan(void) {
    if (!g_loggedClasses) g_loggedClasses = [NSMutableSet set];
    if (!g_seenMethods)   g_seenMethods   = [NSMutableSet set];

    BOOL includeSystem = pf_system_classes_enabled();

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);

    int nClasses = 0, nMethods = 0, nHooked = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];

        // Restrict to the app's own code unless explicitly widened.
        if (!includeSystem && !pf_class_in_app(cls)) continue;

        const char *cn = class_getName(cls);
        BOOL cm = PFMatches(cn);
        NSString *clsName = [NSString stringWithUTF8String:cn];

        if (cm) {
            if (![g_loggedClasses containsObject:clsName]) {
                [g_loggedClasses addObject:clsName];
                Class sup = class_getSuperclass(cls);
                PFLog(@"class: %s (super=%s)", cn, sup ? class_getName(sup) : "(none)");
            }
            nClasses++;
        }

        unsigned mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        for (unsigned j = 0; j < mc; j++) {
            SEL sel = method_getName(ms[j]);
            const char *sn = sel_getName(sel);
            if (!(cm || PFMatches(sn))) continue;

            unsigned nargs = method_getNumberOfArguments(ms[j]);
            char rc = pf_return_type_char(ms[j]);

            NSString *key = [NSString stringWithFormat:@"%s %s", cn, sn];
            if (![g_seenMethods containsObject:key]) {
                [g_seenMethods addObject:key];
                PFLog(@"  %s-[%s %s] argc=%u rt=%c", cm ? "*" : " ", cn, sn, nargs, rc);
                nMethods++;
            }

            if (PFHooked(cls, sel)) continue;

            if (strcmp(sn, "paymentQueue:updatedTransactions:") == 0) {
                PFInstall(cls, sel, (IMP)pf_pq_updated); nHooked++; continue;
            }
            if (strcmp(sn, "productsRequest:didReceiveResponse:") == 0) {
                PFInstall(cls, sel, (IMP)pf_pq_products); nHooked++; continue;
            }
            if (nargs == 2) {
                BOOL never = NO;
                for (size_t k = 0; k < sizeof(kNever)/sizeof(kNever[0]); k++)
                    if (strcmp(sn, kNever[k]) == 0) { never = YES; break; }
                if (never) continue;
                IMP h = pf_hook_for_type(rc);
                if (h) { PFInstall(cls, sel, h); nHooked++; }
            }
        }
        free(ms);

        unsigned pc = 0;
        objc_property_t *ps = class_copyPropertyList(cls, &pc);
        for (unsigned j = 0; j < pc; j++) {
            const char *pn = property_getName(ps[j]);
            if (cm || PFMatches(pn)) {
                NSString *pkey = [NSString stringWithFormat:@"%s.%s", cn, pn];
                if (![g_seenMethods containsObject:pkey]) {
                    [g_seenMethods addObject:pkey];
                    PFLog(@"  prop %s.%s", cn, pn);
                }
            }
        }
        free(ps);
    }
    free(classes);
    PFLog(@"scan complete: classes=%d methods=%d hooked=%d (scope=%@)",
          nClasses, nMethods, nHooked, includeSystem ? @"system+app" : @"app");
}

#pragma mark - Log path setup

static void pf_setup_log_paths(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];
    [cands addObject:@"/var/mobile/Media/PremiumFinder.log"];
    [cands addObject:@"/tmp/PremiumFinder.log"];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs) [cands addObject:[docs stringByAppendingPathComponent:@"PremiumFinder.log"]];

    NSMutableArray *ok = [NSMutableArray array];
    for (NSString *p in cands) {
        [fm createFileAtPath:p contents:nil attributes:nil];
        if ([fm isWritableFileAtPath:p]) [ok addObject:p];
    }
    g_logPaths = ok;
}

#pragma mark - ---------- Keyword entry UI ----------

static NSString *pf_keywords_doc_path(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return docs ? [docs stringByAppendingPathComponent:@"PremiumFinder.keywords"] : nil;
}

static BOOL pf_flag_file_present(NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *dirs = [NSMutableArray arrayWithObjects:@"/var/mobile/Media", @"/tmp", nil];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs) [dirs addObject:docs];
    for (NSString *d in dirs)
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:name]]) return YES;
    return NO;
}

static BOOL pf_flag(NSString *env, NSString *defaultsKey, NSString *fileName) {
    const char *e = getenv(env.UTF8String);
    if (e && e[0] && e[0] != '0') return YES;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:defaultsKey]) return YES;
    if (pf_flag_file_present(fileName)) return YES;
    return NO;
}

static BOOL pf_disabled(void)        { return pf_flag(@"PF_DISABLE",  @"PFDisabled",      @"PremiumFinder.disable"); }
static BOOL pf_early_enabled(void)   { return pf_flag(@"PF_EARLY",    @"PFEarly",         @"PremiumFinder.early"); }
static BOOL pf_autoprompt_enabled(void) {
    const char *e = getenv("PF_NO_AUTOPROMPT");
    if (e && e[0] && e[0] != '0') return NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"PFNoAutoPrompt"]) return NO;
    if (pf_flag_file_present(@"PremiumFinder.noautoprompt")) return NO;
    return YES;
}
static BOOL pf_button_enabled(void) {
    const char *e = getenv("PF_NO_BUTTON");
    if (e && e[0] && e[0] != '0') return NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"PFNoButton"]) return NO;
    if (pf_flag_file_present(@"PremiumFinder.nobutton")) return NO;
    return YES;
}

static UIView     *g_kwOverlay     = nil;
static UIView     *g_kwPanel       = nil;
static UITextView *g_kwTextView    = nil;
static UIButton   *g_kwFloatButton = nil;

static void pf_show_keyword_prompt(void);
static void pf_dismiss_prompt(void);
static void pf_show_float_button(void);

@interface PFTarget : NSObject
+ (PFTarget *)shared;
- (void)onRun;
- (void)onSkip;
- (void)onOpen:(id)sender;
- (void)onPan:(UIPanGestureRecognizer *)g;
- (void)kbShow:(NSNotification *)n;
- (void)kbHide:(NSNotification *)n;
@end

@implementation PFTarget
+ (PFTarget *)shared {
    static PFTarget *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PFTarget new]; });
    return s;
}
- (void)onRun {
    NSString *text = g_kwTextView ? g_kwTextView.text : @"";
    NSString *p = pf_keywords_doc_path();
    if (p) {
        if (text.length)
            [text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        else
            [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    }
    PFLog(@"keyword prompt: submitted (saved to %@)", p);
    pf_dismiss_prompt();
    pf_reload_keywords();
    PFLog(@"=== rescan after keyword entry ===");
    @try { pf_scan(); } @catch (id e) { PFLog(@"scan exception: %@", e); }
}
- (void)onSkip {
    PFLog(@"keyword prompt: skipped");
    pf_dismiss_prompt();
}
- (void)onOpen:(id)sender { pf_show_keyword_prompt(); }
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIButton *b = (UIButton *)g.view;
    UIView *sup = b.superview;
    if (!sup) return;
    CGPoint t = [g translationInView:sup];
    CGPoint c = CGPointMake(b.center.x + t.x, b.center.y + t.y);
    CGFloat hw = b.bounds.size.width / 2, hh = b.bounds.size.height / 2;
    c.x = MAX(hw + 2, MIN(sup.bounds.size.width  - hw - 2, c.x));
    c.y = MAX(hh + 2, MIN(sup.bounds.size.height - hh - 2, c.y));
    b.center = c;
    [g setTranslation:CGPointZero inView:sup];
}
- (void)kbShow:(NSNotification *)n {
    if (!g_kwPanel) return;
    UIWindow *win = g_kwPanel.window;
    if (!win) return;
    g_kwPanel.transform = CGAffineTransformIdentity;
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbWin = [win convertRect:kb fromWindow:nil];
    CGRect panelWin = [g_kwPanel convertRect:g_kwPanel.bounds toView:win];
    CGFloat shift = CGRectGetMaxY(panelWin) - CGRectGetMinY(kbWin) + 16;
    if (shift < 0) shift = 0;
    [UIView animateWithDuration:0.25 animations:^{
        g_kwPanel.transform = CGAffineTransformMakeTranslation(0, -shift);
    }];
}
- (void)kbHide:(NSNotification *)n {
    if (!g_kwPanel) return;
    [UIView animateWithDuration:0.25 animations:^{
        g_kwPanel.transform = CGAffineTransformIdentity;
    }];
}
@end

static UIWindow *pf_key_window(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    if ([app respondsToSelector:@selector(connectedScenes)]) {
        for (id sc in app.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (app.keyWindow) return app.keyWindow;
    if (app.windows.count) return app.windows.lastObject;
#pragma clang diagnostic pop
    return nil;
}

static void pf_dismiss_prompt(void) {
    [[NSNotificationCenter defaultCenter] removeObserver:[PFTarget shared]];
    [g_kwOverlay removeFromSuperview];
    g_kwOverlay = nil;
    g_kwPanel = nil;
    g_kwTextView = nil;
}

static void pf_show_keyword_prompt(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ pf_show_keyword_prompt(); });
        return;
    }
    UIWindow *win = pf_key_window();
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ pf_show_keyword_prompt(); });
        return;
    }
    if (g_kwOverlay) {
        g_kwOverlay.frame = win.bounds;
        [win bringSubviewToFront:g_kwOverlay];
        return;
    }

    BOOL dark = (win.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    UIColor *bg = dark ? [UIColor colorWithWhite:0.14 alpha:1] : [UIColor whiteColor];
    UIColor *fg = dark ? [UIColor whiteColor] : [UIColor blackColor];

    UIView *overlay = [[UIView alloc] initWithFrame:win.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];

    CGFloat pw = MIN(340.0, win.bounds.size.width  - 40);
    CGFloat ph = MIN(360.0, win.bounds.size.height - 80);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    panel.backgroundColor = bg;
    panel.layer.cornerRadius = 14;
    panel.center = CGPointMake(CGRectGetMidX(overlay.bounds), CGRectGetMidY(overlay.bounds));
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                             UIViewAutoresizingFlexibleTopMargin  | UIViewAutoresizingFlexibleBottomMargin;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, pw - 32, 22)];
    title.text = @"PremiumFinder - extra keywords";
    title.font = [UIFont boldSystemFontOfSize:16];
    title.textColor = fg;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [panel addSubview:title];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, pw - 32, 34)];
    hint.text = @"One per line or comma/space separated. '#' hides a line. Generic keywords are always active.";
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = [fg colorWithAlphaComponent:0.7];
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [panel addSubview:hint];

    CGFloat tvY = 78;
    CGFloat tvH = ph - tvY - 64;
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(16, tvY, pw - 32, tvH)];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.backgroundColor = dark ? [UIColor colorWithWhite:0.22 alpha:1] : [UIColor colorWithWhite:0.96 alpha:1];
    tv.textColor = fg;
    tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    tv.layer.cornerRadius = 8;
    tv.autocorrectionType   = UITextAutocorrectionTypeNo;
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tv.spellCheckingType    = UITextSpellCheckingTypeNo;
    tv.keyboardType         = UIKeyboardTypeASCIICapable;
    NSString *docPath = pf_keywords_doc_path();
    if (docPath) {
        NSString *existing = [NSString stringWithContentsOfFile:docPath encoding:NSUTF8StringEncoding error:NULL];
        if (existing) tv.text = existing;
    }
    [panel addSubview:tv];
    g_kwTextView = tv;

    CGFloat by = ph - 52;
    CGFloat bw = (pw - 44) / 2;
    UIButton *skip = [UIButton buttonWithType:UIButtonTypeSystem];
    skip.frame = CGRectMake(16, by, bw, 36);
    [skip setTitle:@"Skip" forState:UIControlStateNormal];
    skip.backgroundColor = dark ? [UIColor colorWithWhite:0.25 alpha:1] : [UIColor colorWithWhite:0.9 alpha:1];
    [skip setTitleColor:fg forState:UIControlStateNormal];
    skip.layer.cornerRadius = 8;
    skip.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [skip addTarget:[PFTarget shared] action:@selector(onSkip) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:skip];

    UIButton *run = [UIButton buttonWithType:UIButtonTypeSystem];
    run.frame = CGRectMake(16 + bw + 12, by, bw, 36);
    [run setTitle:@"Run" forState:UIControlStateNormal];
    run.backgroundColor = [UIColor systemBlueColor];
    [run setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    run.layer.cornerRadius = 8;
    run.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [run addTarget:[PFTarget shared] action:@selector(onRun) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:run];

    [overlay addSubview:panel];
    [win addSubview:overlay];
    [win bringSubviewToFront:overlay];
    g_kwOverlay = overlay;
    g_kwPanel   = panel;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:[PFTarget shared] selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:[PFTarget shared] selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];

    PFLog(@"keyword prompt shown");
}

static void pf_show_float_button(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ pf_show_float_button(); });
        return;
    }
    if (!pf_button_enabled()) return;
    UIWindow *win = pf_key_window();
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ pf_show_float_button(); });
        return;
    }
    if (g_kwFloatButton) {
        if (g_kwFloatButton.superview != win) {
            [g_kwFloatButton removeFromSuperview];
            [win addSubview:g_kwFloatButton];
            [win bringSubviewToFront:g_kwFloatButton];
        }
        return;
    }
    CGFloat s = 42;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(8, 70, s, s);
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    b.layer.cornerRadius = s / 2;
    [b setTitle:@"PF" forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [b addTarget:[PFTarget shared] action:@selector(onOpen:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[PFTarget shared]
                                                                         action:@selector(onPan:)];
    [b addGestureRecognizer:pan];
    [win addSubview:b];
    [win bringSubviewToFront:b];
    g_kwFloatButton = b;
    PFLog(@"floating PF button shown (tap to edit keywords)");
}

#pragma mark - Arm (install + scan), deferred

static BOOL g_armed = NO;

static void pf_arm(const char *why) {
    if (g_armed) return;
    g_armed = YES;
    PFLog(@"arming (%s)", why);
    @try { pf_install_platform(); } @catch (id e) { PFLog(@"platform install exception: %@", e); }
    @try { pf_scan(); } @catch (id e) { PFLog(@"scan exception: %@", e); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PFLog(@"=== rescan (late-loaded classes) ===");
        @try { pf_scan(); } @catch (id e) { PFLog(@"rescan exception: %@", e); }
    });
}

#pragma mark - Watchers

static void pf_watch_keywords(void) {
    __block NSString *last = pf_kw_signature();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                              4 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        NSString *sig = pf_kw_signature();
        if (![sig isEqualToString:last]) {
            last = sig;
            PFLog(@"keyword config changed -> reloading + rescan");
            pf_reload_keywords();
            if (g_armed) {
                PFLog(@"=== rescan after keyword reload ===");
                @try { pf_scan(); } @catch (id e) { PFLog(@"scan exception: %@", e); }
            }
        }
    });
    dispatch_resume(timer);
}

static void pf_watch_ui(void) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        UIWindow *w = pf_key_window();
        if (!w) return;
        if (g_kwFloatButton && g_kwFloatButton.superview != w) {
            [g_kwFloatButton removeFromSuperview];
            [w addSubview:g_kwFloatButton];
            [w bringSubviewToFront:g_kwFloatButton];
        }
        if (g_kwOverlay && g_kwOverlay.superview != w) {
            [g_kwOverlay removeFromSuperview];
            g_kwOverlay.frame = w.bounds;
            [w addSubview:g_kwOverlay];
            [w bringSubviewToFront:g_kwOverlay];
        }
    });
    dispatch_resume(timer);
}

static void pf_await_window(int attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = pf_key_window();
        if (w) {
            PFLog(@"window ready");
            if (!g_armed) pf_arm("window ready");   // SAFE default: arm after launch
            if (pf_autoprompt_enabled()) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ pf_show_keyword_prompt(); });
            }
            pf_show_float_button();
            return;
        }
        if (attempt < 120) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ pf_await_window(attempt + 1); });
        } else {
            PFLog(@"no key window found; inspector not armed");
        }
    });
}

#pragma mark - Entry

__attribute__((constructor))
static void pf_init(void) {
    @autoreleasepool {
        pf_setup_log_paths();
        pf_reload_keywords();

        PFLog(@"=== PremiumFinder loaded pid=%d bundle=%@ ===",
              getpid(), [[NSBundle mainBundle] bundleIdentifier]);

        if (pf_disabled()) {
            PFLog(@"disabled by flag; staying inert");
            return;
        }

        // Nothing dangerous happens here. Arm happens after launch (or early on request).
        if (pf_early_enabled()) {
            PFLog(@"PF_EARLY set: arming at load time (risky)");
            dispatch_async(dispatch_get_main_queue(), ^{ pf_arm("early"); });
        }

        pf_await_window(0);      // arms after launch, then shows UI
        pf_watch_keywords();
        pf_watch_ui();
    }
}

