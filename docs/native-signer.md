# 原生抖音请求栈复用（实验）

目标：把 DouDuo 的接口请求从「隐藏 WKWebView 里跑抖音网页 JS 补 a_bogus/msToken」换成「直接用官方
MetaSec/TTNet 签名」，摆脱 WebView。

结论：**静态上可行**，唯一未验证的是运行时（framework 能否在第三方 App 里 dlopen 并实例化 MetaSec）。
本文记录证据、已落地的脚本，以及按探测结果走的下一步。

## 1. 为什么可行（证据）

抖音 41.1.0 App Store 包（`抖音_41.1.0.ipa`，745MB）主程序全脱壳，`cryptid == 0`：

| 项 | 值 |
|---|---|
| AwemeCore 体积 | 1,051,394,160 B（1010MB），install name `@rpath/AwemeCore.framework/AwemeCore` |
| 硬依赖（非 weak） | 17 个 framework，合计约 1.1GB（AwemeCore + RTCLive 20MB + TTFFmpeg 3.5MB + boringssl 1.3MB + bytevc0/bytevc1enc/isecgm/libvcn/nativeserver/AudioXAAC/byteaudio/TXStartSDK/StreamCore/OmniStream/ByteRtsEngineKit/RTCLiveNICOExtension/RTCLiveScreenCapturer/AAAWELoadManager） |
| ObjC 类数 | 136,677 |
| 代码签名/权限校验 | AwemeCore 内 `SecCode` / `SecStaticCode` / `SecTaskCopyValueForEntitlement` / `com.apple.developer` 命中 **0** 次 → 重签、打进别的 bundle 不被这一层拦 |
| 反调试 | `frida`×15、`substrate`×12、`ptrace`×138，只在被调试时触发，正常运行不触发 |

关键 API（从 ObjC 元数据解出，见第 4 节工具）：

- `MSManagerML`（24 方法）：`initWithAppID:` / `initWithConfig:`、`setDeviceID`、`setInstallID`、
  `setSessionID`、`setChannel`、`setMsSettingConfig`、`setCustomInfo`、`reportForScene:`、
  **`getReportRaw:customInfo:mode:`**、**`getFeatureHash:Body:`**（两条签名出口）。
- `MSConfigML`（68 方法）：`initWithAppID:License:Mode:`、`initWithSDKID:SubAppID:License:Mode:`，以及
  一整套 block 注入 —— `setFetchDeviceIdBlock`、`setSettingConfigBlock`、`setFetchSettingByKeyBlock`、
  `setCheckSettingUpdatedBlock`、`setDefaultReportHost`、`setALogProxy`。
  → MetaSec 本身就是「配置由宿主注入 + 设置从服务端拉」的可嵌入 SDK，不绑 bundle id。
- `TTNetworkManager`（234 方法）= 完整 TTNet：`+shareInstance`、请求/响应 filter、`setCommonParamsblock:`、
  `isEncryptQuery`、重试与序列化器。`+[TTNetworkManager shareInstance]` 可用。
- `MSSettingsLoader`（`+registerKitchen`）、`MSKunPeng`（`+sharedInstance`，方法名被混淆成
  `addWing`/`wingsFlap`）、`MSSenManager`、`MSSmileSweet`（keychain 存储）。

配套：`isecgm.framework` 是国密库（SM2/3/4），不参与请求签名。

## 2. 已落地的东西

```sh
./scripts/fetch-aweme-sdk.sh ~/Downloads/抖音_41.1.0.ipa   # → Vendor/Aweme/（1.0G，18 个 framework）
./scripts/aweme-probe/build-probe.sh                        # → $TMPDIR/aweme-probe/AwemeProbe.ipa（448M）
```

- `scripts/fetch-aweme-sdk.sh`：解 `Payload/Aweme.app/Frameworks`，拒收 `cryptid != 0` 的加密包，
  按 `otool -L` 递归算非 weak 依赖闭包，拷到 `Vendor/Aweme/` 并写 `frameworks.txt`。
- `scripts/aweme-probe/`：独立探测 App（纯 ObjC，clang 直编，无需 XcodeGen）。启动后：
  1. 逐个 `dlopen` 18 个 framework（依赖先、AwemeCore 后），打印每个的耗时/失败原因；
  2. 用 `class_copyMethodList` 把 `MSConfigML`/`MSManagerML`/`MSSettingsLoader`/`MSKunPeng`/
     `TTNetworkManager` 的运行时方法表全打到屏幕上；
  3. 实例化 `[MSManagerML initWithAppID:1128]`，然后直调 `getFeatureHash:Body:`、
     `getReportRaw:customInfo:mode:`，把返回值打出来。全程 `@try/@catch`，单步失败不影响后面。

`Vendor/Aweme/` 已被全局 gitignore（`~/.config/git/ignore` 的 `vendor/`）覆盖，不会进仓库。

打包前自检（已跑过，全通过）：18 个 framework 逐个 `cryptid == 0`（无加密残留）；每个 framework 的
`@rpath` 依赖全部落在抽出的 18 个之内，没有缺失项：

```sh
cd Vendor/Aweme && for d in *.framework; do n=${d%.framework}
  otool -L "$d/$n" | tail -n +2 | while read -r dep rest; do case "$dep" in @rpath/*)
    dn=$(echo "${dep#@rpath/}" | sed 's|/.*||'); [ -d "$dn" ] || echo "缺依赖: $n → $dn";; esac; done
done
```

## 3. 探测怎么跑、结果怎么读

装 `$TMPDIR/aweme-probe/AwemeProbe.ipa`（Sideloadly / AltStore，个人证书 7 天有效），启动后看屏幕，
或 `Console.app` 过滤 `[awemeprobe]`。只有真机能跑：这些 framework 的 `LC_BUILD_VERSION` 是 iOS，
macOS 上 `dlopen` 直接报 `incompatible platform (have 'iOS', need 'macOS')`（已实测），模拟器同理由
platform=IOS ≠ IOS_SIMULATOR 也不行。

三种结局：

| 现象 | 含义 | 下一步 |
|---|---|---|
| 18 个 framework 全 ✅，MetaSec 类都在，`getReportRaw` 返回非空 | 打通，签名可直接取 | 把 `DouyinNativeSigner` 接进 DouDuo，用返回的签名拼请求头，替换 `DouyinBridge.call` 的 web 通道 |
| dlopen 全 ✅，但 `getReportRaw`/`getFeatureHash` 返回 nil 或抛异常 | 签名器要服务端配置（`MSSettingsLoader` 拉 `sec.snssdk.com` 设置） | 用 `MSConfigML` 的 block 注入补 device_id/install_id，或放行 `MSSettingsLoader` 的请求 |
| 某个 framework ❌ 或启动即崩 | 缺资源/初始化顺序 | 按报错缺的 bundle 从 `Aweme.app` 补进 App（顶层有 256 个 `*.bundle`，共 260MB） |

实测命中第二行（dlopen 全 ✅，MetaSec 缺 license / TTNet `ensureEngineStarted failed`），细节与证据见第 6 节。

## 4. 逆向工具（都留在 /tmp，非仓库文件）

`/tmp/dydump.py`（按类名 dump 实例方法 + 类型编码）、`/tmp/findsel.py`（按选择子正则反查所属类）。
自写 Mach-O 解析而不是 `otool -oV`/`nm`：这个 1GB 二进制上 `nm` 300s 超时，`otool -oV` 输出数百 MB。
解析要点：`LC_DYLD_INFO_ONLY`（无 chained fixups），`__objc_classlist` 在 `__DATA_CONST`，
`class_t+32 → class_ro_t`，方法表 `entsizeAndFlags = 0x8000000c`（相对方法列表，12 字节条目），
name/types 字段是「指向 selref 的指针」，要二次解引用。

## 5. 接进 DouDuo 的具体改法（探测通过后再做）

> 真机结论见第 6 节：MetaSec 与 TTNet 都缺抖音侧服务端配置，本节暂不适用，保留备查。

1. `project.yml` 加 framework 依赖（`Vendor/Aweme` 存在时才加，否则 XcodeGen 会报错）：

   ```yaml
   targets:
     DouDuo:
       dependencies:
         - package: VLCKitSPM
         - framework: Vendor/Aweme/AwemeCore.framework
           embed: true
           codeSign: true
         # …其余 17 个同理，或用脚本生成 dependencies 片段
   ```

2. 不要在主线程同步 `dlopen`：AwemeCore 有 13.6 万个类要注册，放到后台队列，首次用原生通道时懒加载。
3. `DouyinNativeSigner` 只暴露一个开关：加载失败就回落到现有 WKWebView 通道，绝不让抖音栈的崩溃
   影响 App 启动。
4. 代价：安装包 +448MB（探测包实测），App 常驻内存相应增加；只有确定原生通道稳定后再考虑
   `thinning` 或只保留 `MSManagerML` 真正用到的部分（不可裁剪，都在同一个 1GB 二进制里）。

## 6. 真机实测结论（iPhone 19,4 / iOS 27.2 / 探针进程独立于抖音）

装法：LCSign 自签（证书 `iPhone Distribution: Serdar Almaz (DBX9497742)`）→ `签名并安装` →
系统弹窗 `"xx-i.lcsignx.com"想要安装"AwemeProbe"` 点安装（走 itms-services，节点 cf/hk/jp 轮换）。

### 6.1 framework 装载：全通

`dlopen` 18/18 成功，总耗 610ms，AwemeCore 本体 480ms；1GB 二进制和 13.6 万个 ObjC 类在第三方
bundle 里注册正常(崩溃报告的 Binary Images 里 `AwemeCore <29f1909c…>` 完整映射)。

### 6.2 MetaSec 签名器：拿不到签名（已在三条路径上确认）

| 调用 | 实测结果 |
|---|---|
| `[MSConfigML new]` + 各 setter | ✅ 可用；`setLicenseStr:` 只校验类型/非 nil，`@""`、`@"0"` 都接受 |
| `-[MSConfigML initWithAppID:License:(Mode:)]` | ❌ `MetaSec:licenseStr must be a kind of NSString and can't be nil or empty!`（license 由抖音侧服务端下发） |
| `-[MSManagerML initWithConfig:]` | ❌ AwemeCore 内部 `abort()`（SIGABRT，栈落在 `IESAppLogger` 一带） |
| `-[MSManagerML getReportRaw:customInfo:mode:]`（真配置形态：URL=NSString, customInfo=dict） | ❌ SIGSEGV，`KERN_INVALID_ADDRESS at 0x48`，栈顶 AwemeCore `+9457904` |
| `-[MSManagerML getFeatureHash:Body:]`（URL=NSString, Body=NSData） | ❌ SIGSEGV，同上（参数类型已由运行时 `method_getTypeEncoding` 确认：`@32@0:8@16@24`） |
| `+[MSKunPeng sharedInstance]` | ✅ 实例可用，但方法名被混淆成 `addWing`/`wingsFlap`，均无参无返回，无法传 URL |

结论：MetaSec 必须先由服务端下发的 license 与 settings（`metasec_sdk_config`）完成初始化，
空配置下签名 API 一律崩溃（`@try/@catch` 抓不住，属 SIGSEGV 而非异常）。

### 6.3 TTNet 网络栈：能初始化，但引擎起不来

| 调用 | 实测结果 |
|---|---|
| `+[TTNetworkManager shareInstance]` | ✅ `<TTNetworkManagerChromium: 0x…>` |
| `- isInitCompleted` | 初始 `0` |
| `- startOnMainThread`（必须主线程） | ✅ 返回；3s 后 `isInitCompleted = 1` |
| `- requestForJSONWithURL:params:method:needCommonParams:callback:`（`needCommonParams=YES`） | ❌ 回调 `NSError kTTNetworkErrorDomain Code=-7 "ensureEngineStarted failed 1"`，`resp=nil` |
| 同上（`needCommonParams=NO`） | ❌ TTNet 内部抛未捕获异常 → SIGABRT |

`isInitCompleted=1` 只代表 TNC 初始化对象建好了，真正请求还要过 `ensureEngineStarted`，而这一步
依赖抖音 App 侧的网络配置（TNC 的 appId/appKey/证书、`adlp_sec_settings` 等）。

### 6.4 结论

路线 B（把原生签名栈打包进第三方 App 复用）**不成立**：MetaSec 与 TTNet 都强依赖抖音自己的
服务端配置，缺配置时前者直接 SIGSEGV、后者 `ensureEngineStarted failed`。可留后路的只有原本
那条「隐藏 WKWebView 跑 web 端签名 JS」的通道。本目录的脚本与实测数据保留，供以后复核
（抖音版本升级后 license/配置可能变化，但获取途径仍是抖音侧）。

### 6.5 探测包工程经验（复用价值）

- 分步执行 + 断点落盘：AwemeCore 的 SIGSEGV 无法捕获，把每个探测动作编号并「先写步号再执行」，
  崩溃后重启自动跳过死路；换 build 时用 `buildN|index` 前缀让断点失效、从头跑。
- 日志三通道：`Documents/probe.log`（`UIFileSharingEnabled`）+ UITextView 回放 + 信号处理器写回溯。
  `NSLog` 载荷在 Console/Pinky 里是 `<private>`，`os_log` 的 `{public}` 也读不出；Pinky 的
  `phone_logs {kind:"logs"}` 在本机 1GB 进程下 30s 超时。所以"写文件 + 下次启动回放"最可靠。
- iOS 27 装 AppDelegate-only 的壳会 SIGTRAP（`UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`），
  必须走 `UIApplicationSceneManifest` + `UIWindowSceneDelegate`。
- 元数据用真机运行时 `method_getTypeEncoding`，离线解析器给出的编码不可靠（截断/乱码）。
