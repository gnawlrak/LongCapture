# 验证与本机验收

## 已验证（2026-10-27）

环境：Apple Silicon / macOS 27.2，Xcode 27.1、Swift 6.4；编译部署目标 macOS 14.0。没有在真实 macOS 14 系统上运行。

- 捕获边界分片：`swift test`，3 项通过（Retina/负坐标、跨屏拒绝、BGRA 复制与所有权）。
- 拼接/会话分片：`swift test`，28 项通过。
- 完整 App/XCTest：`./scripts/test.sh`，41 项通过，0 失败。包含真实 Vision 与 CoreText 的逐像素测试，不只检查图片高度；也包含原生 `NSWindow.performClose`、丢弃按钮和拒绝丢弃后的继续保存。
- `./scripts/build.sh`：Release 构建成功，原生 arm64 可执行文件；应用包包含 MIT notice。
- `codesign --verify --deep --strict`：本地 ad-hoc 签名通过。没有公证或商店签名。
- 已启动 Release 进程并确认持续运行；启动本身不申请屏幕权限，也不产生空白主窗口。这不是实际滚动截图验收。
- 权限接口静态检查：唯一显式隐私请求为 `CGRequestScreenCaptureAccess`；无 AX、全局输入监视、麦克风、网络 API。音频采集关闭。测试宿主专用 entitlement 不作为 Release 授权交付。

本地日志在 `build/capture-slice-tests.log`、`build/stitching-slice-tests.log`、`build/tests-final.log` 和 `build/release-build.log`；XCTest 结果包在 `build/DerivedData/Logs/Test/`。这些构建产物不入 Git。

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
2. 在测试文档前按 `⌃⌥S`，框选正文，调整边缘/移动；Esc 取消一次，再重新框选回车开始。首次允许屏幕录制；拒绝时保留菜单并显示正确提示。
3. Safari 向下慢滚，暂停、反向回看、再超出前沿，确认增长不重复；同一路径快滚到无重叠，检查暂停提示并回滚恢复。若未恢复直接结束，预览必须明确提示不完整。
4. TextEdit 从中间向上滚动，检查导出从早到晚的行号顺序、无裁掉旧内容；反方向回看不增长错误的一端。用图片查看器检查接缝和真实像素分辨率。
5. 完成后等待 5 秒确认桌面 PNG；另一次悬停暂停、移开继续；另一次点击打开预览并等待，确保不会再自动保存。
6. 预览测试缩放、滚动、明确复制、保存、完成和普通关闭；丢弃后不应产生文件。未处理结果时再按快捷键，只能打开现有结果，不得覆盖。
7. 设置不可写目录，确认失败不丢图，能选择新目录重试；同一时间戳再次保存不覆盖。保存中不允许丢弃。快捷键改为一个未占用组合，并试一次冲突提示；菜单入口始终保留。
8. 有设备时测不同缩放显示器；框选不得跨屏；捕获中改分辨率、锁屏或断流，确认安全保留已确认部分并提示原因。
9. 仅在用户明确确认后，对指定微信非敏感测试会话重复向上、回看、恢复和导出检查；不得以自动化测试代替该项。
