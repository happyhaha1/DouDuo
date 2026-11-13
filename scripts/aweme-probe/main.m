// Aweme 原生请求栈探测（真机自签运行）
// 目的：确认把抖音 AwemeCore + 依赖 framework 打进第三方 App 后能否 dlopen、MetaSec 类能否实例化。
// 只有真机能跑：framework 的 LC_BUILD_VERSION 是 iOS，macOS 会以 incompatible platform 拒绝 dlopen。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <sys/time.h>
#import <os/log.h>
#import <execinfo.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import "mscall.h"

static UITextView *gLog;
static NSMutableArray<NSString *> *gLines;
static int gLogFD = -1;

// 每次启动把结果追加到 Documents/probe.log，并显示历史：崩溃后下次启动仍能看到最后一行
static NSString *probeLogPath(void) {
    static NSString *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        p = [dir stringByAppendingPathComponent:@"probe.log"];
    });
    return p;
}

static void appendToFile(const char *s, size_t len) {
    if (gLogFD < 0) return;
    write(gLogFD, s, len);
    write(gLogFD, "\n", 1);
    fsync(gLogFD);
}

// 信号处理里只做 write/backtrace，随后 _exit：拿到崩溃点所在的 image + offset
static void crashHandler(int sig, siginfo_t *info, void *ctx) {
    char buf[256];
    int n = snprintf(buf, sizeof buf, "💥 CRASH signal %d (%s) addr %p", sig, strsignal(sig),
                     info ? info->si_addr : NULL);
    appendToFile(buf, (size_t)n);
    void *frames[48];
    int cnt = backtrace(frames, 48);
    backtrace_symbols_fd(frames, cnt, gLogFD);
    fsync(gLogFD);
    _exit(90);
}

static void installCrashHandler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = crashHandler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
}

static void logline(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[awemeprobe] %@", s);
    // NSLog 的载荷在 Pinky/Console 里是 <private>，用 os_log 的 {public} 才能被读出
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[awemeprobe] %{public}@", s);
    appendToFile(s.UTF8String, strlen(s.UTF8String));
    dispatch_async(dispatch_get_main_queue(), ^{
        [gLines addObject:s];
        gLog.text = [gLines componentsJoinedByString:@"\n"];
        if (gLines.count) [gLog scrollRangeToVisible:NSMakeRange(gLog.text.length - 1, 1)];
    });
}

// 非 ARC 单元的日志回调
static void probeSink(const char *utf8) {
    if (utf8) logline(@"%s", utf8);
}

static double now_ms(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

// 从 Frameworks 目录读依赖顺序：先装依赖，最后装 AwemeCore
static NSArray<NSString *> *frameworkOrder(NSString *fwDir) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fwDir error:NULL];
    files = [files sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *f in files) {
        if (![f hasSuffix:@".framework"]) continue;
        if ([f isEqualToString:@"AwemeCore.framework"]) continue;
        [out addObject:[fwDir stringByAppendingPathComponent:f]];
    }
    [out addObject:[fwDir stringByAppendingPathComponent:@"AwemeCore.framework"]];
    return out;
}

static NSString *stepFilePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"step.txt"];
}

// 换 build 时重置断点：内容形如 "build10|13"
static NSString *const kProbeBuild = @"build10";
static const int kProbeStartStep = 13;

static int readStepIndex(void) {
    NSString *s = [NSString stringWithContentsOfFile:stepFilePath() encoding:NSUTF8StringEncoding error:NULL];
    if (!s.length) return kProbeStartStep;
    NSArray *parts = [s componentsSeparatedByString:@"|"];
    if (parts.count == 2 && [parts[0] isEqualToString:kProbeBuild]) return [parts[1] intValue];
    return kProbeStartStep;
}

static void writeStepIndex(int idx) {
    [[NSString stringWithFormat:@"%@|%d", kProbeBuild, idx] writeToFile:stepFilePath()
                                                            atomically:YES
                                                              encoding:NSUTF8StringEncoding
                                                                 error:NULL];
}

static void dumpClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) { logline(@"  [class] %@ 缺失", name); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    logline(@"  [class] %@ 存在，实例方法 %u 个", name, n);
    for (unsigned int i = 0; i < n; i++) {
        logline(@"      - %s  %s", sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
    }
    free(ms);
    Class meta = object_getClass(cls);
    unsigned int cn = 0;
    Method *cms = class_copyMethodList(meta, &cn);
    if (cn) logline(@"    (%@ 类方法 %u 个)", name, cn);
    for (unsigned int i = 0; i < cn; i++) {
        logline(@"      + %s  %s", sel_getName(method_getName(cms[i])), method_getTypeEncoding(cms[i]));
    }
    free(cms);
}

static void runProbe(void) {
    @autoreleasepool {
        logline(@"===== aweme 原生栈探测 %@ =====", [NSDate date]);
        logline(@"bundle id = %@", [NSBundle mainBundle].bundleIdentifier);
        NSString *fwDir = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks"];
        NSArray *order = frameworkOrder(fwDir);
        logline(@"Frameworks 里 %lu 个 framework", (unsigned long)order.count);

        double t0 = now_ms();
        int ok = 0, fail = 0;
        for (NSString *path in order) {
            NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
            NSString *bin = [path stringByAppendingPathComponent:name];
            double t = now_ms();
            void *h = dlopen(bin.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            if (h) {
                ok++;
                logline(@"  ✅ %@ (%.0fms)", name, now_ms() - t);
            } else {
                fail++;
                logline(@"  ❌ %@ (%.0fms): %s", name, now_ms() - t, dlerror());
            }
            // AwemeCore 之后不再需要继续装依赖
            if ([name isEqualToString:@"AwemeCore"]) break;
        }
        logline(@"dlopen 结果：成功 %d / 失败 %d，总耗时 %.0fms", ok, fail, now_ms() - t0);

        logline(@"---- 关键类 ----");
        for (NSString *c in @[@"MSConfigML", @"MSManagerML", @"MSSettingsLoader", @"MSKunPeng",
                             @"MSSenManager", @"TTNetworkManager", @"TTNetworkManagerChromium"]) {
            dumpClass(c);
        }

        // 所有动态调用放在非 ARC 单元里：ARC 会对 IMP 强调的结果过度释放（真机 SIGSEGV 已复现）
        // 分步执行：AwemeCore 在未完成 config 初始化时调业务方法会直接 SIGSEGV（@try 抓不住），
        // 所以每步跑完就把步号落盘，崩溃后下次启动从断点继续。
        logline(@"---- MetaSec 动态调用（分步，崩溃后从断点续跑）----");
        int start = readStepIndex();
        int total = ms_step_count();
        logline(@"从步骤 %d 开始，共 %d 步", start, total);
        for (int i = start; i < total; i++) {
            logline(@">>> 步骤 %d/%d", i, total);
            // 先记账再跑：崩溃的步骤下次启动会被跳过，避免死循环
            writeStepIndex(i + 1);
            ms_step(i, probeSink);
            usleep(200 * 1000);
        }
        logline(@"===== 全部 %d 步跑完 =====", total);
    }
}

@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    gLogFD = open(probeLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    installCrashHandler();
    gLines = [NSMutableArray array];
    UIViewController *vc = [UIViewController new];
    gLog = [[UITextView alloc] initWithFrame:vc.view.bounds];
    gLog.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gLog.editable = NO;
    gLog.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    gLog.textContainerInset = UIEdgeInsetsMake(44, 8, 8, 8);
    [vc.view addSubview:gLog];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    // 先显示上次运行留下的日志（含崩溃回溯），再跑本次
    NSString *prev = [NSString stringWithContentsOfFile:probeLogPath() encoding:NSUTF8StringEncoding error:NULL];
    if (prev.length) {
        NSArray *lines = [prev componentsSeparatedByString:@"\n"];
        if (lines.count > 40) lines = [lines subarrayWithRange:NSMakeRange(lines.count - 40, 40)];
        [gLines addObjectsFromArray:lines];
        [gLines addObject:@"──────── 本次运行 ────────"];
        gLog.text = [gLines componentsJoinedByString:@"\n"];
    }
    // 先让界面把上次日志渲染出来，再延时跑探测：崩溃后下次启动仍可读到上一次的最后几行
    logline(@"=== build 10 · 5s 后开始探测（此间屏幕显示的是上次运行的日志）===");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        runProbe();
    });
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    return YES;
}
// iOS 26+ 强制 scene 生命周期：不实现这条会在 UIApplicationMain 里 SIGTRAP（no scene lifecycle adoption）
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                  options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *cfg = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    cfg.delegateClass = [ProbeSceneDelegate class];
    return cfg;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); }
}
