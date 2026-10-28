# 验证与本机验收

## 已验证（2026-10-27/28，分片记录）

环境：Apple Silicon / macOS 27.2，Xcode 27.1、Swift 6.4；编译部署目标 macOS 14.0。没有在真实 macOS 14 系统上运行。

- 捕获边界分片：`swift test`，3 项通过（Retina/负坐标、跨屏拒绝、BGRA 复制与所有权）。
- 拼接/会话分片：`swift test`，28 项通过。
- 权限增量：8 项注入测试通过，覆盖不主动弹窗、已授权不重复申请、申请成功/拒绝、重启前仍阻止采集、外部允许/撤销、防重入及系统设置链接失败；权限分片时 `swift test` 共 36 项通过，接缝修复后当前共 47 项通过。
- 完整 App/XCTest：`./scripts/test.sh` 当前 60 项通过，0 失败（此前权限分片为 49 项）。包含真实 Vision 与 CoreText 的逐像素测试，不只检查图片高度；也包含原生 `NSWindow.performClose`、丢弃按钮和拒绝丢弃后的继续保存。
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

## 尚未验证

以下条目**未完成，不标为通过**：

- Safari 真实长网页的 ScreenCaptureKit 实际画面、手动滚动、缩略图与最终 PNG。
- TextEdit 真实长文档采集，尤其慢滚与反向恢复。
- 微信向上聊天记录。没有用户确认的非敏感测试会话，未打开或采集用户聊天。
- 真实多显示器设备、混合缩放、锁屏/拔屏时的系统通知和安全结束。已有坐标/中断注入测试，但不代替硬件实测。
- 实际拒绝/允许屏幕录制、系统桌面文件夹访问提示及快捷键与其他应用冲突。已有注入失败/注册错误保底逻辑，未擅自修改系统授权。

## 安全测试素材

```sh
python3 scripts/make-fixtures.py
open -a Safari build/Fixtures/LongCapture-test.html
open -a TextEdit build/Fixtures/LongCapture-test.txt
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
