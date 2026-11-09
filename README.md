# Safe Vision for iOS

Safe Vision Android 版的 iOS 移植：本地敏感内容检测 + 打码工具。所有检测都在手机本地完成，不上传任何图片或视频。

> 注意：实时屏幕检测功能没有移植——iOS 不允许第三方应用监听别的 App 的屏幕、加悬浮遮罩，任何 iOS 应用都做不到。

## 功能

- **图片处理**：选图或拍照 → 本地模型检测敏感部位 → 打码预览（可逐个框改效果、调缩放）→ 保存到相册或应用内
- **视频处理**：选视频 → 逐帧检测打码（隔帧检测 + 框插值平滑）→ 重编码导出，保留原音轨，进度反馈，后台可继续
- **批量处理**：多选图片批量检测打码，逐项显示状态
- **相册**：浏览、查看、分享、删除、导出处理过的文件
- **设置**：标准/动漫两种模型、按标签开关与效果（马赛克/纯黑块/高斯模糊/素描/贴纸）、缩放、预设管理、主题、语言（简中/繁中/英文/韩文）
- **模型**：标准模型（18 标签）和动漫模型（10 标签），全部本地跑

## 工程结构

```text
SafeVision/
├── Podfile                      # TensorFlowLiteSwift + Metal
├── SafeVision.xcodeproj/        # Xcode 工程
├── SafeVision/                  # App 源码
│   ├── SafeVisionApp.swift      # App 入口
│   ├── Info.plist
│   ├── Core/                    # 推理层：Detection、DetectionConfig、检测引擎、TFLite 加载、YOLO 后处理、Vision 眼部区域
│   ├── Masking/                 # 打码渲染：五种效果、贴纸加载
│   ├── Services/                # 设置管理（隐私/通用）、媒体保存、批量处理
│   ├── Video/                   # 视频处理管线、框插值
│   ├── UI/                      # 五个 Tab 页面 + 检测框覆盖层组件
│   ├── Models/                  # 模型文件（见下）
│   └── Resources/               # 图标、贴纸、四语言字符串
└── .github/workflows/build-ipa.yml   # 云端编译工作流
```

## 模型文件

模型就是 Android 原版的两个 `.tflite` 文件，已经放在工程里：

- `SafeVision/Models/SafeVisionStandard.tflite`（标准模型，原 `nude26_best_float16.tflite`）
- `SafeVision/Models/SafeVisionAnime.tflite`（动漫模型，原 `anime_320n_float16.tflite`）

它们作为 Bundle 资源打包进 App，推理用 TensorFlow Lite Swift 库（CocoaPods 引入，Metal GPU 加速，失败回退 CPU）。不要删除或替换这两个文件；如果上游模型更新，把新文件按同名放进来重新编译即可。

## 怎么编译出 .ipa（GitHub Actions，免费，不需要 Apple 开发者账号）

1. 在 GitHub 上新建一个仓库（公开或私有都可以），把本目录下的**全部文件**传上去（包括 `.github/`、`Podfile`、`SafeVision.xcodeproj/`、`SafeVision/`）。
2. 推送到 `main` 分支后，工作流自动开始；也可以在仓库的 **Actions** 页面点 **Run workflow** 手动触发。
3. 工作流在 GitHub 的免费 macOS 电脑上跑：先 `pod install` 安装 TensorFlow Lite，再用 `xcodebuild` 编出**未签名**的 App，打包成 `.ipa`。
4. 跑完后，在那次运行的页面底部 **Artifacts** 里下载 `SafeVision-unsigned-ipa`（里面是 `SafeVision-unsigned.ipa`）。

## 怎么装到 iPhone 上（SideStore）

1. 把下载到的 `SafeVision-unsigned.ipa` 传到 iPhone（隔空投送、微信文件、iCloud 都行）。
2. 在 iPhone 上用 **SideStore** 打开这个 `.ipa` 安装——SideStore 会用你自己的开发者证书给它签名。
3. 注意：免费 Apple ID 最多装 3 个侧载应用（SideStore 自己占 1 个），如果槽位满了，需要先删一个不用的，或装进 LiveContainer。
4. 首次打开时按提示允许相册权限；处理全部在本地，不上传。

## 要求

- iOS 17.0 及以上
- 首次打开需要相册权限（选图、保存结果）和相机权限（拍照）

## 已知限制

- 实时屏幕检测：iOS 系统限制，无法实现，已砍掉。
- 未签名的 `.ipa` 每 7 天需要用 SideStore 重新签名一次（免费账号的限制，SideStore 里点一下刷新就行）。
- 视频处理较耗电，大视频建议插着充电线处理。
