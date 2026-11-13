// 非 ARC 单元：所有 MetaSec 动态调用都在这里，手工管理所有权（故意只 retain 不 release）。
//
// 为什么要分步：AwemeCore 内部在"未完成 config 初始化"时调业务方法会直接 SIGSEGV
// （真机已复现多次，addr 0x48，落在 IESAppLogger 附近），@try/@catch 抓不住。
// 因此每次只跑一步，调用方把步号落盘，崩溃后下次启动从断点继续。
#import "mscall.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static ms_log_fn gSink = NULL;
static id gCfg = nil;   // MSConfigML
static id gMgr = nil;   // MSManagerML

static void L(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (gSink) gSink([s UTF8String]);
}

static id send0(id o, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName(sel));
}
static BOOL send0b(id o, const char *sel) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, sel_registerName(sel));
}
static long long send0q(id o, const char *sel) {
    return ((long long (*)(id, SEL))objc_msgSend)(o, sel_registerName(sel));
}
static id send1id(id o, const char *sel, id a) {
    return ((id (*)(id, SEL, id))objc_msgSend)(o, sel_registerName(sel), a);
}
static id send2(id o, const char *sel, id a, id b) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(o, sel_registerName(sel), a, b);
}
static id send2i(id o, const char *sel, id a, id b, int c) {
    return ((id (*)(id, SEL, id, id, int))objc_msgSend)(o, sel_registerName(sel), a, b, c);
}
static void sendV1(id o, const char *sel, id a) {
    ((void (*)(id, SEL, id))objc_msgSend)(o, sel_registerName(sel), a);
}
static void sendV1q(id o, const char *sel, long long a) {
    ((void (*)(id, SEL, long long))objc_msgSend)(o, sel_registerName(sel), a);
}
// TTNet：URL + params + method + needCommonParams + callback(block)
static id sendReq(id o, const char *sel, id url, id params, id method, BOOL needCommon, id blk) {
    return ((id (*)(id, SEL, id, id, id, BOOL, id))objc_msgSend)(
        o, sel_registerName(sel), url, params, method, needCommon, blk);
}

static void logSelectors(Class cls, NSArray *sels) {
    for (NSString *n in sels) {
        SEL s = sel_registerName(n.UTF8String);
        Method m = class_getInstanceMethod(cls, s);
        const char *e = m ? method_getTypeEncoding(m) : NULL;
        L(@"    - %@  %s", n, e ? e : "(该类无此实例方法)");
    }
}

// 结果可能是 NSString / NSData / NSDictionary / 其他；统一压成一行短描述
static NSString *describe(id o) {
    if (!o) return @"nil";
    if ([o isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)o;
        NSUInteger n = d.length < 48 ? d.length : 48;
        NSMutableString *hex = [NSMutableString string];
        const unsigned char *p = d.bytes;
        for (NSUInteger i = 0; i < n; i++) [hex appendFormat:@"%02x", p[i]];
        return [NSString stringWithFormat:@"NSData(%lu) %@%@", (unsigned long)d.length, hex,
                                          d.length > n ? @"…" : @""];
    }
    NSString *s = [o description];
    if (s.length > 900) s = [[s substringToIndex:900] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"%@: %@", NSStringFromClass([o class]), s];
}

static NSString *kURL = @"https://aweme.snssdk.com/aweme/v1/feed/?aid=1128&count=10&offset=0";
static NSString *kBody = @"aid=1128&count=10&offset=0";

// 用 +new + 各个 setter 手工造配置（绕过 initWithAppID:License: 的 licenseStr 强校验）
static id ensureCfg(BOOL rebuild) {
    if (gCfg && !rebuild) return gCfg;
    Class cfgCls = objc_getClass("MSConfigML");
    if (!cfgCls) { L(@"  ❌ 运行时找不到 MSConfigML"); return nil; }
    id cfg = nil;
    @try {
        cfg = send0((id)cfgCls, "new");
        [cfg retain];
        L(@"  MSConfigML +new → %@", describe(cfg));
    } @catch (NSException *e) {
        L(@"  ❌ MSConfigML +new 抛异常 %@: %@", e.name, e.reason);
        return nil;
    }
    struct { const char *sel; id val; } setters[] = {
        {"setAppID:", @"1128"},
        {"setChannel:", @"App Store"},
        {"setDeviceID:", @"7312345678901234567"},
        {"setInstallID:", @"7312345678901234567"},
        {"setSessionID:", @"0123456789abcdef0123456789abcdef"},
        {"setClientType:", @"app"},
    };
    for (size_t i = 0; i < sizeof(setters) / sizeof(setters[0]); i++) {
        @try {
            sendV1(cfg, setters[i].sel, setters[i].val);
            L(@"  cfg.%s → OK", setters[i].sel);
        } @catch (NSException *e) {
            L(@"  ❌ cfg.%s 抛异常 %@: %@", setters[i].sel, e.name, e.reason);
        }
    }
    @try {
        sendV1q(cfg, "setMode:", 0);
        L(@"  cfg.setMode:0 → OK");
    } @catch (NSException *e) {
        L(@"  ❌ cfg.setMode: 抛异常 %@", e.reason);
    }
    gCfg = cfg;
    return gCfg;
}

static void dumpCfgGetters(id cfg) {
    if (!cfg) { L(@"  (没有 cfg 可 dump)"); return; }
    NSArray *objs = @[ @"appID", @"licenseStr", @"channel", @"sdkID", @"subAppID", @"deviceID",
                       @"bdDeviceID", @"installID", @"sessionID", @"idfa", @"fetchedID",
                       @"clientType", @"customInfo", @"advanceInfo", @"customHost" ];
    for (NSString *n in objs) {
        SEL s = sel_registerName(n.UTF8String);
        if (![cfg respondsToSelector:s]) { L(@"    cfg.%@ → (无此 getter)", n); continue; }
        @try { L(@"    cfg.%@ → %@", n, describe(send0(cfg, n.UTF8String))); }
        @catch (NSException *e) { L(@"    ❌ cfg.%@ 抛异常 %@", n, e.reason); }
    }
    @try { L(@"    cfg.mode → %lld", send0q(cfg, "mode")); }
    @catch (NSException *e) { L(@"    ❌ cfg.mode 抛异常 %@", e.reason); }
    @try { L(@"    cfg.isSDK → %d", (int)send0b(cfg, "isSDK")); }
    @catch (NSException *e) { L(@"    ❌ cfg.isSDK 抛异常 %@", e.reason); }
}

static id ensureMgr(void) {
    if (gMgr) return gMgr;
    Class ml = objc_getClass("MSManagerML");
    if (!ml) { L(@"  ❌ 运行时找不到 MSManagerML"); return nil; }
    // 注意：initWithConfig: 在真机上会直接 abort（AwemeCore 内部断言），这里不再尝试
    @try {
        id inst = send0((id)ml, "new");
        [inst retain];
        L(@"  ↪ 退回 +new → %@", describe(inst));
        gMgr = inst;
    } @catch (NSException *e) {
        L(@"  ❌ +new 抛异常 %@: %@", e.name, e.reason);
    }
    return gMgr;
}

int ms_step_count(void) { return 16; }

// TTNet 直发一次 aweme 请求：看框架自己会不会补签名头/公共参数
static void ttnetSend(BOOL needCommon) {
    Class tn = objc_getClass("TTNetworkManager");
    if (!tn) { L(@"  ❌ 找不到 TTNetworkManager"); return; }
    id tt = nil;
    @try { tt = send0((id)tn, "shareInstance"); [tt retain]; L(@"  instance → %@", describe(tt)); }
    @catch (NSException *e) { L(@"  ❌ shareInstance %@: %@", e.name, e.reason); }
    if (!tt) return;
    void (^cb)(id, id) = ^(id err, id resp) {
        L(@"  ▼ 回调 err=%@", describe(err));
        L(@"  ▼ resp=%@", describe(resp));
    };
    L(@"  → 调用前（needCommon=%d）", needCommon);
    @try {
        sendReq(tt, "requestForJSONWithURL:params:method:needCommonParams:callback:",
                @"https://aweme.snssdk.com/aweme/v1/feed/",
                @{ @"aid": @"1128", @"count": @"10", @"offset": @"0" },
                @"GET", needCommon, [cb copy]);
        L(@"  → 调用已返回（异步等待回调）");
    } @catch (NSException *e) { L(@"  ❌ 发送 %@: %@", e.name, e.reason); }
}

// TTNet 初始化探针：startOnMainThread + isInitCompleted
static void ttnetInit(void) {
    Class tn = objc_getClass("TTNetworkManager");
    if (!tn) { L(@"  ❌ 找不到 TTNetworkManager"); return; }
    id tt = nil;
    @try { tt = send0((id)tn, "shareInstance"); [tt retain]; } @catch (NSException *e) {}
    if (!tt) { L(@"  ❌ shareInstance 为 nil"); return; }
    L(@"  responds start=%d startOnMainThread=%d", [tt respondsToSelector:sel_registerName("start")],
      [tt respondsToSelector:sel_registerName("startOnMainThread")]);
    @try { L(@"  isInitCompleted(前) = %d", (int)send0b(tt, "isInitCompleted")); }
    @catch (NSException *e) { L(@"  ❌ isInitCompleted %@", e.reason); }
    @try {
        if ([tt respondsToSelector:sel_registerName("startOnMainThread")]) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                L(@"  → 在主线程调 startOnMainThread");
                ((void (*)(id, SEL))objc_msgSend)(tt, sel_registerName("startOnMainThread"));
                L(@"  → startOnMainThread 已返回");
            });
        } else if ([tt respondsToSelector:sel_registerName("start")]) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                L(@"  → 在主线程调 start");
                ((void (*)(id, SEL))objc_msgSend)(tt, sel_registerName("start"));
                L(@"  → start 已返回");
            });
        } else {
            L(@"  ❌ 没有 start/startOnMainThread");
        }
    } @catch (NSException *e) { L(@"  ❌ start %@", e.reason); }
    usleep(3 * 1000 * 1000);
    @try { L(@"  isInitCompleted(3s后) = %d", (int)send0b(tt, "isInitCompleted")); }
    @catch (NSException *e) { L(@"  ❌ %@", e.reason); }
}

void ms_step(int step, ms_log_fn sink) {
    gSink = sink;
    @autoreleasepool {
        Class ml = objc_getClass("MSManagerML");
        Class cfgCls = objc_getClass("MSConfigML");
        switch (step) {
            case 0: {
                L(@"---- 步骤0：选择器编码 ----");
                if (ml) logSelectors(ml, @[ @"initWithAppID:", @"initWithConfig:", @"versionInfo",
                                            @"getFeatureHash:Body:", @"getReportRaw:customInfo:mode:" ]);
                if (cfgCls) logSelectors(cfgCls, @[ @"initWithAppID:License:Mode:", @"initWithAppID:License:",
                                                   @"initWithSDKID:SubAppID:License:Mode:", @"setAppID:",
                                                   @"setLicenseStr:", @"setMode:", @"setCustomInfo:",
                                                   @"licenseStr", @"mode", @"isSDK" ]);
                break;
            }
            case 1: {
                L(@"---- 步骤1：MSConfigML +new 的默认值 ----");
                id cfg = nil;
                @try { cfg = send0((id)cfgCls, "new"); [cfg retain]; L(@"  +new → %@", describe(cfg)); }
                @catch (NSException *e) { L(@"  ❌ +new 抛异常 %@: %@", e.name, e.reason); }
                dumpCfgGetters(cfg);
                break;
            }
            case 2: {
                L(@"---- 步骤2：setter 手工造配置 ----");
                id cfg = ensureCfg(YES);
                dumpCfgGetters(cfg);
                break;
            }
            case 3: {
                L(@"---- 步骤3：MSManagerML +new（initWithConfig: 已知会 abort，跳过）----");
                id mgr = ensureMgr();
                if (mgr) @try { L(@"  versionInfo → %@", describe(send0(mgr, "versionInfo"))); }
                @catch (NSException *e) { L(@"  ❌ versionInfo 抛异常 %@", e.reason); }
                break;
            }
            case 4: {
                L(@"---- 步骤4：对 +new 实例逐个 setter ----");
                id mgr = ensureMgr();
                if (!mgr) break;
                struct { const char *sel; id val; } setts[] = {
                    {"setDeviceID:", @"7312345678901234567"},
                    {"setInstallID:", @"7312345678901234567"},
                    {"setSessionID:", @"0123456789abcdef0123456789abcdef"},
                    {"setChannel:", @"App Store"},
                    {"setCustomInfo:", @{@"url": kURL, @"host": @"aweme.snssdk.com"}},
                };
                for (size_t i = 0; i < sizeof(setts) / sizeof(setts[0]); i++) {
                    @try { sendV1(mgr, setts[i].sel, setts[i].val); L(@"  mgr.%s → OK", setts[i].sel); }
                    @catch (NSException *e) { L(@"  ❌ mgr.%s 抛异常 %@: %@", setts[i].sel, e.name, e.reason); }
                }
                break;
            }
            case 5: {
                L(@"---- 步骤5：getReportRaw:customInfo:mode: 只传 URL ----");
                id mgr = ensureMgr();
                if (mgr) @try { L(@"  → %@", describe(send2i(mgr, "getReportRaw:customInfo:mode:", kURL, nil, 0))); }
                @catch (NSException *e) { L(@"  ❌ 抛异常 %@: %@", e.name, e.reason); }
                break;
            }
            case 6: {
                L(@"---- 步骤6：getReportRaw 带 customInfo ----");
                id mgr = ensureMgr();
                if (mgr) @try {
                    L(@"  → %@", describe(send2i(mgr, "getReportRaw:customInfo:mode:", kURL, @{@"url": kURL}, 0)));
                } @catch (NSException *e) { L(@"  ❌ 抛异常 %@: %@", e.name, e.reason); }
                break;
            }
            case 7: {
                L(@"---- 步骤7：getFeatureHash:Body: 传 NSData ----");
                id mgr = ensureMgr();
                if (mgr) @try {
                    L(@"  → %@", describe(send2(mgr, "getFeatureHash:Body:", kURL,
                                                [kBody dataUsingEncoding:NSUTF8StringEncoding])));
                } @catch (NSException *e) { L(@"  ❌ 抛异常 %@: %@", e.name, e.reason); }
                break;
            }
            case 8: {
                L(@"---- 步骤8：getFeatureHash:Body: 传 NSString ----");
                id mgr = ensureMgr();
                if (mgr) @try { L(@"  → %@", describe(send2(mgr, "getFeatureHash:Body:", kURL, kBody))); }
                @catch (NSException *e) { L(@"  ❌ 抛异常 %@: %@", e.name, e.reason); }
                break;
            }
            case 9: {
                L(@"---- 步骤9：setLicenseStr: 探针（空串/占位）----");
                id cfg = ensureCfg(NO);
                if (cfg) {
                    for (NSString *lic in @[ @"", @"0" ]) {
                        @try { sendV1(cfg, "setLicenseStr:", lic); L(@"  setLicenseStr:@\"%@\" → OK", lic); }
                        @catch (NSException *e) { L(@"  ❌ setLicenseStr:@\"%@\" 抛异常 %@: %@", lic, e.name, e.reason); }
                    }
                    dumpCfgGetters(cfg);
                }
                break;
            }
            case 10: {
                L(@"---- 步骤10：MSKunPeng（签名入口，方法名被混淆）----");
                Class kp = objc_getClass("MSKunPeng");
                if (!kp) { L(@"  ❌ 找不到 MSKunPeng"); break; }
                id kpi = nil;
                @try { kpi = send0((id)kp, "sharedInstance"); [kpi retain]; L(@"  sharedInstance → %@", describe(kpi)); }
                @catch (NSException *e) { L(@"  ❌ sharedInstance 抛异常 %@: %@", e.name, e.reason); }
                if (kpi) {
                    unsigned int cnt = 0;
                    Method *ms = class_copyMethodList([kpi class], &cnt);
                    L(@"  实例方法 %u 个：", cnt);
                    for (unsigned int i = 0; i < cnt && i < 40; i++) {
                        L(@"    - %s  %s", sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
                    }
                    free(ms);
                }
                break;
            }
            case 11: {
                L(@"---- 步骤11：MSSettingsLoader registerKitchen ----");
                Class loader = objc_getClass("MSSettingsLoader");
                if (!loader) { L(@"  ❌ 找不到 MSSettingsLoader"); break; }
                @try { L(@"  registerKitchen → %@", describe(send0((id)loader, "registerKitchen"))); }
                @catch (NSException *e) { L(@"  ❌ 抛异常 %@: %@", e.name, e.reason); }
                break;
            }
            case 12: {
                L(@"---- 步骤12：TTNetworkManager ----");
                Class tn = objc_getClass("TTNetworkManager");
                if (!tn) { L(@"  ❌ 找不到 TTNetworkManager"); break; }
                @try { L(@"  shareInstance → %@", describe(send0((id)tn, "shareInstance"))); }
                @catch (NSException *e) { L(@"  ❌ 抛异常 %@: %@", e.name, e.reason); }
                break;
            }
            case 13: {
                L(@"---- 步骤13：TTNet 初始化（startOnMainThread / isInitCompleted）----");
                ttnetInit();
                break;
            }
            case 14: {
                L(@"---- 步骤14：TTNet 直发 GET（needCommonParams=YES）----");
                ttnetSend(YES);
                break;
            }
            case 15: {
                L(@"---- 步骤15：TTNet 直发 GET（needCommonParams=NO）----");
                ttnetSend(NO);
                break;
            }
            default:
                L(@"  (无此步骤 %d)", step);
                break;
        }
    }
}
