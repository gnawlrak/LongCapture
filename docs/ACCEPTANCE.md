# 验证与本机验收

## 已验证（2026-10-27 至 29，分片记录）

环境：Apple Silicon / macOS 27.2，Xcode 27.1、Swift 6.4；编译部署目标 macOS 14.0。没有在真实 macOS 14 系统上运行。

- 捕获边界分片：`swift test`，3 项通过（Retina/负坐标、跨屏拒绝、BGRA 复制与所有权）。
- 拼接/会话分片：`swift test`，28 项通过。
- 权限增量：8 项注入测试通过，覆盖不主动弹窗、已授权不重复申请、申请成功/拒绝、重启前仍阻止采集、外部允许/撤销、防重入及系统设置链接失败；权限分片时 `swift test` 共 36 项通过，累计位移修复后当前共 54 项通过。
- 完整 App/XCTest：横向/续张分片后共 120 项通过，0 失败（前版为 99 项）。包含真实 Vision 与 CoreText 的逐像素测试，不只检查图片高度；也包含原生 `NSWindow.performClose`、丢弃按钮和拒绝丢弃后的继续保存。
- 设置权限区的原生离屏渲染已检查，浅色/深色下状态、申请/打开设置/检查按钮完整显示；这不代表系统授权弹窗已实测。
- `./scripts/build.sh`：Release 构建成功，原生 arm64 可执行文件；应用包包含 MIT notice。
- `codesign --verify --deep --strict`：签名完整性通过。2026-10-28 起改为本机现有 Apple Development 证书签名，不再以 ad-hoc 交付；没有公证或商店签名。
- 已启动 Release 进程并确认持续运行；启动本身不申请屏幕权限，也不产生空白主窗口。这不是实际滚动截图验收。
- 权限接口静态检查：唯一显式隐私请求为 `CGRequestScreenCaptureAccess`；无 AX、全局输入监视、麦克风、网络 API。音频采集关闭。测试宿主专用 entitlement 不作为 Release 授权交付。

## 权限故障复查（2026-10-28）

- 报告“已开权限仍显示未授权”后，在当时运行的旧 Debug 进程内检查：`CGPreflightScreenCaptureAccess() == false`，ScreenCaptureKit 仅枚举内容也返回 `SCStreamErrorDomain/-3801`，没有读取画面像素。重新启动同一旧构建后仍复现。说明当时确为系统拒绝当前进程，不只是界面没有刷新。
- 旧 Debug 与 Release 使用同一个 bundle ID 和显示名，却有不同的 ad-hoc/CDHash 要求。未能读取受保护的 TCC 记录，因此不能断言用户具体勾选了哪一个历史条目；该身份混淆与不稳定问题已修复。
- 新 Debug 名称/标识与 Release 分开，均通过证书签名检查。`./scripts/test-signing.sh` 验证内容变化后的临时副本仍符合原证书身份要求；旧 ad-hoc 构建按预期被检查脚本拒绝。
- 修复后完整 XCTest 仍为 49 项通过，Release 构建及浅色/深色权限页渲染通过。实际重新授权与真实滚动截图仍需人工完成，不因签名检查通过而视为通过。

故障复查日志：`build/permission-runtime-probe.log`、`build/permission-runtime-sck.log`、`build/permission-runtime-relaunch.log`、`build/signing-regression-red.log`、`build/signing-regression-green.log`、`build/signing-xcode-tests.log`、`build/signing-release-build.log`。修改前的两份 App 保存在 `build/Backups/20261028-permission-identity/`，仅供回退，不应重新混用授权。

本地日志在 `build/capture-slice-tests.log`、`build/stitching-slice-tests.log`、`build/tests-final.log`、`build/permission-swift-tests.log`、`build/permission-xcode-tests.log` 和 `build/permission-release-build.log`；权限区离屏渲染在 `build/permission-settings-light.png`、`build/permission-settings-dark.png`，XCTest 结果包在 `build/DerivedData/Logs/Test/`。这些构建产物不入 Git。

## 接缝与边缘控件故障复查（2026-10-28）

- 用户提供的成图可见重复向下箭头、变淡条带和接缝。没有原始帧，不能由成图证明每处瑕疵的来源。用固定在视口边缘的 72px 渐变和圆形按钮重现了同类现象：旧算法即使注入完全正确的位移，也会反复拼入遮罩。
- 最初 5 项回归产生 22 条失败断言：慢滚/反向回看逐像素不一致，无效接缝错误推进位置；真实 Vision 在等行距文字中还出现周期别名。通过候选/替代位移诊断定位，不靠放宽误差阈值解决。
- 新增共 11 项测试，覆盖上下边缘、双边缘、1–3px 慢滚、向上/向下反向回看、宽 Retina 文本、错误接缝不锁定方向/推进位置、上限时裁切前沿，以及有遮罩的完全重复列表仍拒绝。
- `swift test`：47 项通过；`swift test -c release`：47 项通过；`./scripts/test.sh`：60 项通过。像素比较覆盖整张 RGBA 数据，初始/最终边缘遮罩只保留一次，没有把输出高度正确当作图像正确。
- 优化后核心的 28 帧同源对照输出为 640×1460：旧版本与参考图有 87,746 个不同像素；新版注入位移和真实 Vision 两路均为 0。已离屏查看 `build/EdgeSeamProbe/before.png`、`build/EdgeSeamProbe/after-vision.png`。真实 Vision 分支平均处理约 36.83ms、单帧最大约 106.10ms；这是本次合成素材测量，不是实际屏幕流吞吐保证。
- 日志：`build/edge-seam-red.log`、`build/edge-seam-swift-tests.log`、`build/edge-seam-release-tests.log`、`build/edge-seam-xcode-tests.log`、`build/edge-seam-pixel-probe.log`。素材均为本地生成；用户原图不进入仓库。
- 正式版构建和签名回归通过；修复前 App 已备份到 `build/Backups/20261028-084143-edge-seams/Release.app`。向旧进程发送正常退出请求后，首次等待未观察到退出，随后独立系统进程检查确认它已结束，才替换 App；没有强制结束进程。新版已启动，前后证书身份要求逐字一致，没有修改系统授权。构建/签名/进程日志分别为 `build/edge-seam-release-build.log`、`build/edge-seam-signing.log`、`build/edge-seam-relaunch.log`。
- 最后仍被遮住的外边缘不会被凭空修复；任意位置的固定控件、动画和过小的正文重叠仍不保证可拼。此次未重新采集用户的 Codex 对话，也未把合成帧结果记作 Safari/TextEdit/微信实测通过。

## 匹配暂停与累计位置复查（2026-10-28）

- 用户明确反馈为「匹配暂停，请往回滚动恢复」，不能把它解释成 64MP/50K 上限。新增长流对照在修复前就通过：注入位移每方向 201 帧、输出 13,280px；真实 Vision 文字和边缘遮罩每方向 61 帧、输出 6,300px。因此没有复现单纯累计高度导致的截止点。
- 另外两类最小回归实际失败：连续 1/16px 移动被逐帧取整为 0，却不断更换可靠参照，丢失累计位置；规则纹理采样又可能只落到两像素成对图案的同一半，误判无纹理。真实 Vision 与注入估计均能触发后续暂停，首轮共 26 条失败断言。
- 修复后，取整为 0 的有效帧保留原参照；纹理查看 1/2px 邻居，重叠检查相邻像素。额外负例确认 65px 实际移动不能被误认成 64px，且邻居正确不能平均稀释原采样点的错误。误差阈值未放宽。
- 最终核心 Debug/Release 各 54 项、完整 Xcode 67 项通过，均为 0 失败。新增的上下方向输出逐像素等于参考图，空白/周期图案/动态区域/无重叠仍被拒绝；没有通过关闭校验使测试变绿。
- 日志在 `build/matching-recovery-*.log`、`build/matching-patch-red.log` 和 `build/matching-patch-dilution-red.log`。没有记录用户屏幕帧或对话内容，也未修改系统授权。
- 尚未取得用户现场的原始采样序列，不能宣称已证明那一固定页面位置的唯一根因；原页面和真实 ScreenCaptureKit 长流复测仍未完成。
- 受限会话阶段曾阻止进程查询、签名私钥访问和 Git 写入，失败日志保留。用户恢复权限后，正式版独立构建、严格签名校验和签名变更回归均通过，新旧证书身份要求逐字相同，没有临时签名或修改 TCC。
- 已正常退出旧 PID 49536，再通过已验证的副本和目录重命名替换正式版。新版从 `build/Release/LongCapture.app` 启动，PID 48090 已完成启动；恢复权限后优化核心复跑仍为 54 项通过。旧版备份在 `build/Backups/20261028-092932-matching-recovery/Release.app` 和该目录的 `InstalledRelease.app`。交付日志在 `build/matching-recovery-release-build-resumed.log`、`build/matching-recovery-signing-regression.log`、`build/matching-recovery-identity-comparison.log`、`build/matching-recovery-normal-quit.log`、`build/matching-recovery-install-relaunch.log`；这不代替原页面现场复测。

## 应用图标（2026-10-28）

- Swift/Core Graphics 直接绘制海绿色底、取景框和延展纸带；提供 16/32/128/256/512 点各 1x/2x 共 10 个 macOS 标准槽位，最大 1024px。已查看 512px、32px 和系统返回的 256px 图标，未使用截图内容或第三方图案。
- 先运行图标检查确认缺少资源而失败，再补资产与工程配置。初稿 16px 阴影外溢被透明角测试捕获，修正阴影缩放后，所有尺寸、透明角、中心不透明、覆盖率和配置检查通过。
- Debug/Release 均生成 `CFBundleIconName`、`CFBundleIconFile`、`AppIcon.icns` 和 `Assets.car`，已分别检查构建包；完整 Xcode XCTest 仍为 67 项通过、0 失败。默认构建脚本检查成品图标，测试脚本额外检查源资产。
- 正式版已同证书构建并启动，签名身份与更新前一致，未重置录屏权限。旧版备份在 `build/Backups/20261028-101009-app-icon/Release.app`，旧 PID 51661 正常退出，新 PID 77430 完成启动。`NSWorkspace.icon(forFile:)` 返回新版图标，已渲染检查 `build/app-icon-system-preview.png`；不代表所有已打开的 Finder 窗口缓存都已人工核对。
- 日志：`build/app-icon-red.log`、`build/app-icon-assets-tests.log`、`build/app-icon-xcode-tests.log`、`build/app-icon-debug-bundle-tests.log`、`build/app-icon-release-bundle-tests.log`、`build/app-icon-installed-release-build.log`、`build/app-icon-signing-regression.log`、`build/app-icon-normal-quit.log`、`build/app-icon-relaunch.log`。菜单栏单色模板与截图逻辑不变。

## 原生 Liquid Glass 界面（2026-10-28）

- 先增加五处界面的最小测试，旧实现五项均因缺少原生玻璃视图而失败；随后统一选区引导/尺寸、工具条、缩略图、预览、设置。macOS 26+ 使用 `NSGlassEffectView` 和原生玻璃按钮，macOS 27 支持原生交互材质。系统菜单、警告和文件面板保留原生实现。
- 新增 9 项 UI 回归：旧版材质兼容、减少透明度通知切换且保留控件、选框拖动/调整/移动及 Return 入口、采集框鼠标穿透和完成/取消、缩略图保存失败后仍可打开、预览图像不被玻璃过滤、全部操作/快捷键、浅深色最小窗口布局、设置展示不申请权限。原有 13 项结果流程测试继续通过。
- 首轮布局检查发现尺寸提示初始零宽度约束冲突，已设置合法初始尺寸，复跑没有约束冲突。系统合成检查又暴露预览新增符号后仅显示图标；最小回归实际产生 3 条失败，再显式设置 `imageLeading`，最终保持图标和操作文字同时显示。
- 完整 XCTest 76 项通过、0 失败；正式版独立目录构建、图标和证书内容变更回归通过。Vision 测试过程中系统缓存曾输出 `MDB_MAP_FULL` 诊断，但没有测试失败；没有因此修改匹配阈值或清理系统缓存。
- 已查看浅/深色的布局样张及真实系统合成样张。系统合成测试只包含测试进程自建窗口和生成背景，所有窗口按进程 ID 显式纳入；没有读取用户页面/聊天，也没有额外申请权限。减少透明度和旧版路径通过注入及通知测试验证，未改用户系统偏好；没有在真实 macOS 14/15/26 设备运行。
- 界面测试和渲染不等于 Safari/TextEdit/微信真实滚动采集验收，也不等于完整 VoiceOver 人工走查。无自定义动画；原生控件的动效交给系统管理。
- 更新前的正式版保存在 `build/Backups/20261028-124748-liquid-glass/Release.app`，实际被替换的安装包另存为同目录的 `InstalledRelease.app`。旧 PID 77430 正常退出并确认结束后才安装，新 PID 40731 从默认正式版路径完成启动；新旧证书身份要求逐字相同，没有强制退出或修改 TCC。
- 日志：`build/glass-ui-red.log`、`build/glass-ui-regression.log`、`build/glass-ui-action-label-red.log`、`build/glass-ui-xcode-tests-final.log`、`build/glass-ui-render.log`、`build/glass-ui-composited.log`、`build/glass-ui-release-build.log`、`build/glass-ui-signing-regression.log`、`build/glass-ui-normal-quit.log`、`build/glass-ui-relaunch.log`。样张：`build/GlassUI/`，`*-composited.png` 为包含生成背景的系统合成结果；默认 PNG 仅是离屏布局，不应作为完整材质效果的证据。

## 框选提示条菜单栏避让（2026-10-28）

- 用户照片中的框选提示条压进菜单栏。读取当前屏幕：顶部 `visibleFrame` 避让为 33 点，刘海安全区为 32 点，旧提示条固定下移 28 点。先加入实际屏幕布局测试，浅色/深色均失败，测得提示条顶边压入菜单栏约 5 点。
- 改为取菜单栏避让与刘海安全区的较大值，再留 16 点间距；不移动/缩小整屏选区，不改拼接、权限和结果流程。新增实际屏幕浅深色检查，以及 0/24/33/64 点顶部避让、原点/负坐标屏幕的注入布局测试。
- 相关 UI/结果流程 24 项和完整 XCTest 78 项全部通过；正式版构建、图标、严格签名及签名身份内容变更回归通过。已查看浅/深色选区布局和仅包含自建窗口的系统合成样张；这不等同于正式版真实页面采集或自动隐藏菜单栏的人工验收。
- 更新前 App 备份在 `build/Backups/20261028-130657-menu-safe-area/Release.app`；被替换安装包另存为同目录 `InstalledRelease.app`。旧 PID 40731 正常退出并确认结束后才替换，新 PID 71611 从默认路径完成启动。新旧签名身份要求逐字一致，没有强制结束进程或修改 TCC。
- 日志：`build/menu-safe-area-red.log`、`build/menu-safe-area-regression.log`、`build/menu-safe-area-full-tests.log`、`build/menu-safe-area-render.log`、`build/menu-safe-area-composited.log`、`build/menu-safe-area-release-build.log`、`build/menu-safe-area-signing.log`、`build/menu-safe-area-normal-quit.log`、`build/menu-safe-area-install-relaunch.log`。照片仅在忽略的 `build/` 内用于定位，不入 Git。

## 原生登录时启动（2026-10-28）

- 新入口：菜单栏 → 设置 → 通用 → 登录时启动。使用 `SMAppService.mainApp`，默认不注册；只在用户操作开关时注册/取消。读取系统真实状态，不使用独立的 UserDefaults 开启标记，也不安装 LaunchAgent/脚本/helper。
- 先加入缺少登录开关的失败检查；实现后修正离屏 SwiftUI 虚拟无障碍树的测试方式，改为实际操作底层原生 `NSSwitch`，不是通过放宽断言使其通过。开关测试检查默认关闭、展示无注册、点击开关调用注入服务、注册失败后复位，以及重新打开设置时读取外部更改。
- 新增 11 项状态/操作注入测试及 2 项原生 UI 集成测试。覆盖幂等注册/取消、待批准但未启用、取消待批准、开启/关闭失败与重试、调用返回但状态未改变、部分成功后抛错、系统外部允许/撤销、不可用服务、防重入、显式打开登录项设置。相关 37 项及完整 XCTest 91 项全部通过。
- 设置使用原有系统开关/玻璃外观；新增关闭、待批准、注册失败的浅/深色系统合成样张并检查，样张的登录项操作全部注入，不注册真实服务或打开系统设置。未改变启动时菜单栏待命、无普通主窗口和不自动申请录屏的行为。
- 正式版独立构建、图标、严格签名与内容变更身份回归通过；签名身份与旧版逐字相同。旧包备份在 `build/Backups/20261028-204950-login-item/Release.app` 及同目录 `InstalledRelease.app`。替换时旧正式版没有运行；新版 PID 27364 从默认路径完成启动。没有强制结束进程、改动 TCC 或自动启用登录项。
- 日志：`build/login-item-red.log`、`build/login-item-ui-probe.log`、`build/login-item-regression.log`、`build/login-item-full-tests.log`、`build/login-item-composited.log`、`build/login-item-release-build.log`、`build/login-item-signing.log`、`build/login-item-normal-quit.log`、`build/login-item-install-relaunch.log`。实际系统登录项注册/撤销及重新登录启动仍需用户选择开启后手动验收，不能以注入测试代替。

## 频繁误暂停的匹配改进（2026-10-28）

- 先增加真实 Vision 回归，复现两类误暂停：55–60% 视口移动仍有正文重叠，却因采样点占整帧的比例不足而被拒绝；每行只有编号不同的普通列表被当成完全重复。最初两项测试有 26 条失败断言。追加扰动/恢复回归又确认：干净的快滚帧只有 1–2 个可用 Vision 提案时，旧的「必须三个区域全部成功」条件会直接否决正确像素证据。
- 新增共 8 项测试，覆盖上下快滚、相似编号列表、不同数字字形、双边缘遮罩下的 1–3px 慢滚与反向回看、1 级 RGB 栅格扰动、损坏重叠拒绝后恢复，以及相似但无重叠、纯重复/孤立标记、分散动态内容的拒绝。增长/恢复测试逐像素比较整张输出，不只验证高度；原有无效接缝、双上限、内存、尾帧、取消和结果流程继续通过。
- 核心优化构建 62 项、完整 Xcode XCTest 99 项均通过，0 失败。核心 Debug 初轮 62 项也通过；后续补充的数字字形和第二采样相位改动，由最终完整 Xcode Debug 和核心 Release 再次覆盖。系统 Vision 缓存仍输出已有的 `MDB_MAP_FULL` 诊断，没有失败断言；未修改系统缓存或放宽重叠/接缝误差阈值。
- 同源优化构建对照：编号列表向上、向下各 61 帧，旧版各暂停 60 次且只保留 480px；新版各输出 640×2700，0 次暂停、0 个不同像素。7 帧较快的非重复文字输出 640×2160，5 帧部分 Vision 区域失效的纹理画面输出 240×1536，均为 0 次暂停、逐像素一致。已查看向上列表与快滚文字的 PNG；这些都是生成素材，不是用户页面。
- 上述正例的新版核心平均约 17–29ms/帧，最慢约 84ms；这是一次本机优化构建测量，不是实际 ScreenCaptureKit 长流的吞吐承诺。对照源码、前后 PNG 和参考图保存在忽略的 `build/RobustMatchingProbe/`，统计在 `build/robust-matching-pixel-probe-final.log`。
- 明确保留边界：把 55–60% 大步滚动与几乎相同的列表正文组合，正文可靠重叠只剩少量行时，探索对照仍出现 6/6 次暂停，仅导出 480px 并标记不完整。这项没有记作连续增长通过，也没有降低校验来强拼；需要减少每次滚动量，不能从其他正例推断所有相似页面都已解决。
- 正式版独立构建、图标、严格签名和内容变化后的身份回归通过。原包备份在 `build/Backups/20261028-214448-robust-matching/Release.app`；旧 PID 27364 正常退出并确认结束后，才替换安装包，被替换的包另存为同目录 `InstalledRelease.app`。新版 PID 46725 从默认正式版路径完成启动。新旧证书身份要求逐字相同，没有强制结束进程、改动 TCC 或注册登录项。
- 日志为 `build/robust-matching-*.log`。没有记录用户屏幕、微信或私密文档；尚无用户本次误暂停的原始帧序列，因此不把这些合成对照说成现场根因的唯一证明。实际页面回归仍列在下方。

## 用户日常使用反馈（2026-10-28）

- 作者报告已在 Codex 和其他日常应用中实际使用，感觉可用，暂未遇到 bug。这是用户实测反馈，不是自动化测试结论，也没有留存用户屏幕或私密内容。
- 未提供其他应用的具体名称、版本、采集长度和逐像素对照，因此不据此将下列专项验收标记为通过。

## 开源发布检查（2026-10-28）

- 新增项目自身的 MIT `LICENSE`，并与原有 `THIRD_PARTY_NOTICES.md` 一起打入 App；独立 Release 构建中逐字节校验两份资源与源码一致，签名和图标检查通过。
- 完整 Xcode XCTest 再次运行：99 项通过，0 失败。没有更改截图算法或替换正在使用的正式 App；本次只发布源码，不创建安装包 Release。
- README 本地链接、工程文件格式和差异空白检查通过；历史文件常见密钥格式与误入产物检查未发现匹配。这不代替专业安全审计。
- 日志在忽略的 `build/open-source-release-build.log`、`build/open-source-full-tests.log`，不会上传本机构建产物或私人素材。

## 横向、恢复引导与多张结果（2026-10-29）

- 新增横向入口和框选轴选择；横向逐像素转置后复用原有校验引擎，输出恢复自然方向。真实 Vision 和注入位移覆盖左右增长、慢滚、反向回看、续张与整图像素顺序；不支持单次采集混合两个轴。
- 匹配暂停显示最后可靠画面的缩略参考，不丢弃可靠锚点；单独显示无新增、反向回看、恢复和接近单张上限。原匹配/重叠/歧义/接缝阈值未放宽。
- 单张达到 64M 像素或沿轴 50K 长度后封存到私有临时目录，继续保留跨界视口、溢出像素和原增长方向；按阅读顺序整组保存。缩小上限的像素回归覆盖上下/左右续张、恰好触顶不输出重复尾张、临时磁盘失败和清理；会话测试验证仍在采集且结束处理尾帧。
- 分段导出按当前轴裁切，默认 2400px 长度、120px 重叠；检查完整像素、命名冲突、整组原子发布、失败重试、导出期间关闭阻止及原图继续保留。最终追加并修复分页读取在保存期间完成时错误重新启用分页菜单的竞态。
- 发现 ImageIO 最终写出会将预创建的 0600 文件替换成 0644；先由权限断言复现，再在 finalize 后对实际文件描述符设置 0600 并 fsync，未放宽断言。文件夹为 0700，保存和临时文件共用修复后的写出路径。
- 最终完整 XCTest **120/120**、优化构建核心测试 **73/73** 通过，图标检查通过。系统 Vision 的已有 `MDB_MAP_FULL` 诊断仍存在，但没有失败断言，也未修改系统缓存。日志：`build/multiaxis-full-final.log`、`build/multiaxis-core-final.log`、`build/multiaxis-permissions-fix.log`、`build/multiaxis-page-race-red.log`。
- 生成 20 张离屏和 20 张系统合成的浅/深色非敏感 UI 样张；检查横向多张预览、选择条和恢复参考图。合成采集仅包含素材程序自身窗口，不是用户应用内容；离屏图片不作为完整玻璃效果的证明。
- 独立 Release、两份许可资源、图标、严格签名与签名身份回归通过。旧包备份在 `build/Backups/20261029-200623-multiaxis/Release.app` 和 `InstalledRelease.app`；旧 PID 46725 正常退出后替换，新 PID 46147 已从默认路径完成启动，安装后可执行文件与验证构建一致。未强制退出、改动 TCC、注册登录项、推送或发布新 Release。

## 尚未验证

以下条目**未完成，不标为通过**：

- 新增横向模式在真实应用里的左右手动滚动、达到生产 64M/50K 单张上限后的持续长流续张及多张实际分享流程；已有合成像素、真实 Vision、注入尾帧和原生 UI 测试，不代替实际屏幕采集。
- Safari 真实长网页的 ScreenCaptureKit 实际画面、手动滚动、缩略图与最终 PNG。
- TextEdit 真实长文档采集，尤其慢滚与反向恢复。
- 微信向上聊天记录。没有用户确认的非敏感测试会话，未打开或采集用户聊天。
- 真实多显示器设备、混合缩放、锁屏/拔屏时的系统通知和安全结束。已有坐标/中断注入测试，但不代替硬件实测。
- 实际拒绝/允许屏幕录制、系统桌面文件夹访问提示及快捷键与其他应用冲突。已有注入失败/注册错误保底逻辑，未擅自修改系统授权。
- 实际系统登录项批准/撤销及注销或重启后登录启动。未为了测试替用户开启登录项或中断登录会话；已验证注入状态、原生开关及发布包签名。

## 安全测试素材

```sh
python3 scripts/make-fixtures.py
open -a Safari build/Fixtures/LongCapture-test.html
open -a TextEdit build/Fixtures/LongCapture-test.txt
open -a Safari build/Fixtures/LongCapture-horizontal-test.html
```

素材全为本地生成、带唯一编号与图案的非敏感内容，不加载网络。

## 手动清单

1. 启动 `build/Release/LongCapture.app`，确认无普通主窗口；菜单图标、开始入口与设置可用。
2. 打开菜单栏 → 屏幕录制权限…，检查状态和申请/系统设置按钮。未授权时在测试文档前按 `⌃⌥S`，应先申请权限再框选；拒绝时不显示选框，保留菜单并提供系统设置入口。在系统设置允许后回到应用，状态应刷新；若仍未允许，退出重开。授权后框选正文，调整边缘/移动；Esc 取消一次，再重新框选回车开始。
3. Safari 向下慢滚，暂停、反向回看、再超出前沿，确认增长不重复；同一路径快滚到无重叠，检查暂停提示并回滚恢复。若未恢复直接结束，预览必须明确提示不完整。
4. TextEdit 从中间向上滚动，检查导出从早到晚的行号顺序、无裁掉旧内容；反方向回看不增长错误的一端。用图片查看器检查接缝和真实像素分辨率。
5. 完成后等待 5 秒确认桌面 PNG；另一次悬停暂停、移开继续；另一次点击打开预览并等待，确保不会再自动保存。
6. 预览测试缩放、滚动、明确复制、保存、完成和普通关闭；丢弃后不应产生文件。未处理结果时再按快捷键，只能打开现有结果，不得覆盖。
7. 设置不可写目录，确认失败不丢图，能选择新目录重试；同一时间戳再次保存不覆盖。保存中不允许丢弃。快捷键改为一个未占用组合，并试一次冲突提示；菜单入口始终保留。
8. 有设备时测不同缩放显示器；框选不得跨屏；捕获中改分辨率、锁屏或断流，确认安全保留已确认部分并提示原因。
9. 仅在用户明确确认后，对指定微信非敏感测试会话重复向上、回看、恢复和导出检查；不得以自动化测试代替该项。
10. 对有底部跳转箭头/渐变的非敏感测试页面，慢滚后再回看并恢复增长，检查箭头与遮罩不在图像内部重复。向上采集时检查顶部边缘同类现象；末端仍被控件盖住的内容不应被伪造补出。
11. 连续滚动至少 15 个视口，夹杂接近静止的慢滚、暂停和反向回看，再恢复原方向。对原来固定暂停的页面位置复测；若仍暂停，记录工具条的已确认高度及悬停显示的具体原因，不把通用恢复文案当成长度上限。
12. 在刘海屏/普通屏进入框选，提示条应在菜单栏和刘海下方至少留 16 点空隙，两个操作按钮完整可点；切换浅/深色及菜单栏自动隐藏后重试。框选、移动、调整与回车开始的坐标不能因避让偏移；多显示器仍需设备实测。
13. 由用户选择开启「设置 → 通用 → 登录时启动」。待批准时点击「打开登录项设置」按系统提示允许，回到应用应刷新为已开启；下次自行注销/重新登录后确认只有菜单栏待命、没有自动截图或录屏弹窗。关闭后确认系统登录项移除，当前应用仍继续运行；在系统设置撤销后回到应用应显示待批准，不得自动重新注册。测试期间保留正式版路径不移动，不把调试版当作同一个登录项。
14. 用非敏感、每行带不同编号但正文相似的长文档复测本次频繁暂停：上下正常滚动，夹杂 1–3px 慢滚与反向回看，再恢复增长。逐行检查编号连续、不重复、不缺失；额外试一次仍保留明显正文重叠的较快滚动。近重复内容加很短重叠仍可能暂停，不以隐藏提示或跳行当作修复。
15. 在生成的横向测试页使用「开始横向长截图」，分别从左向右及从中间向左采集，夹杂反向回看和慢滚；检查输出卡片按左到右排列、文字没有旋转、没有漏号或重复。单次采集只沿一个轴。
16. 暂停时参照工具条最后确认画面回滚，确认恢复提示；超长采集触及生产上限时应自动续张而不是结束。完成后逐张检查重叠、顺序和跨界内容，普通关闭应将整组保存到新文件夹。
17. 多张预览切换分页，复制只复制当前张；「分段导出…」检查纵向/横向裁切、默认重叠、编号和原图仍保留。导出中关闭应被阻止；导出后丢弃原图不删除已明确导出的副本。
