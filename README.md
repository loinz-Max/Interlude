# 幕间 · Interlude _(localplayer)_

<p align="center">
  <img src="LocalPlayer/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="104" alt="幕间应用图标：深色背景上的棱镜">
</p>

![version](https://img.shields.io/badge/version-0.3.1-blue)
![platform](https://img.shields.io/badge/iOS-17.0%2B-informational)
![dependencies](https://img.shields.io/badge/dependencies-0-success)
![network](https://img.shields.io/badge/network-none-critical)
![build](https://img.shields.io/github/actions/workflow/status/loinz-Max/localplayer/ios-ipa.yml?label=build)
![license](https://img.shields.io/github/license/loinz-Max/localplayer)

iOS 本地视频播放器。视频存在手机里，离线播放，没有账号，也不需要联网。

代码 29 个文件、约 6600 行，用 SwiftUI 和 AVPlayer 写成，没有任何第三方依赖。

## 目录

- [隐私与安全](#隐私与安全)
- [安装](#安装)
- [使用](#使用)
- [功能](#功能)
- [截图](#截图)
- [兼容性](#兼容性)
- [项目结构](#项目结构)
- [维护与反馈](#维护与反馈)
- [致谢](#致谢)
- [许可证](#许可证)

## 隐私与安全

- 没有网络代码。全仓库搜 `URLSession`、`WKWebView`、`Network` 框架，命中为零；`Info.plist` 里没有 ATS 例外，也没有任何 `UsageDescription`。
- 没有账号、没有埋点、没有第三方 SDK。依赖清单是空的。
- 视频不出设备，与 iCloud 无关。卸载 App 会连文件一起删掉。
- 从相册导入用的是系统选择器，App 只拿到你选中的那几个文件，不会读取整个相册。

## 安装

发布的是未签名 ipa，装之前需要用你自己的 Apple ID 签一次名。

**[下载 v0.3.1](https://github.com/loinz-Max/localplayer/releases/latest)**　2.11 MB　需要 iOS 17.0 或更高版本

有 Mac 的话也可以直接编译。需要 Xcode 16 和 XcodeGen：

```sh
brew install xcodegen
git clone https://github.com/loinz-Max/localplayer.git
cd localplayer
xcodegen generate
open LocalPlayer.xcodeproj
```

项目没有 `Package.swift`，也没有 CocoaPods 或 SPM 依赖，打开就能编。

## 使用

**导入**　「文件」App 里把视频拷进「幕间」文件夹，或者从导入菜单选相册，也可以连上数据线在访达里拖进 App 的文件区。批量导入会显示进度，结束时说明成功几个、重名几个。

**播放**　点卡片就播，默认从上次的位置继续。控件会自动隐藏，点一下屏幕唤回。

| 手势 | 作用 |
|---|---|
| 横滑 | 拖进度，画面跟着走，松手前有目标帧预览 |
| 左半屏上下滑 | 亮度 |
| 右半屏上下滑 | 音量 |
| 右半屏长按 | 临时加速（1.5–3× 可设），松手复原 |
| 双击左 / 右 | 后退 / 前进 10 秒 |
| 双指捏合 | 切换画面比例 |
| 单击 | 唤出控件；锁定时看时间与进度 |

左半屏长按不加速，那一整片留给亮度，调光时不容易误触。

**追剧**　设置里打开「播完自动下一集」，同一文件夹里播完会直接切下一部。播放模式有列表循环、单集循环、播完暂停三档，播完自动标已看。

**边看边做别的**　切到后台声音继续；进画中画后小窗可以一直浮着，点「展开」带着进度回到播放页。

## 功能

### 资料库

- 文件夹新建、重命名、删除；长按视频可标已看、重命名、移动、删除
- 缩略图取时长 12% 处（不早于 3 秒），跳过片头台标
- 按名称或最近播放排序

### 播放

- 断点续播；列表循环、单集循环、播完暂停
- 倍速五档直选，长按临时加速
- 画面比例：适应、填充、拉伸
- 画中画，支持从小窗带进度回全屏
- 防误触锁。锁屏、控制中心、来电、拔耳机这些外部操作都会自动解锁

### 系统集成

- 锁屏与「正在播放」显示封面、进度、±10 秒与切集
- AirPods 与车机遥控可用
- 来电打断后自动续播，拔耳机自动暂停

### 界面

- 液态玻璃控件，屏幕通透度三档可调，全站一起变
- 进出播放页的转屏在黑幕后面完成，配竖屏 / 横屏的小动画
- 冷启动有一秒左右的棱镜 logo

## 截图

20 个界面，由 CI 在模拟器里实拍，点开可看原图：

<img src="docs/images/screens.png" alt="幕间的 20 个界面：空状态、资料库、文件夹、播放页、设置、长按菜单、移动面板、倍速、播放列表、亮度调节、列表视图、多选、卡片菜单、长按加速、搜索、设置各页">

## 兼容性

- 系统：iOS 17.0 及以上，iPhone 与 iPad
- 视频：`mp4`、`mov`、`m4v`、`3gp`、`mpg`、`mpeg`
- 能不能播取决于系统解码器，H.264 和 HEVC 最稳
- 不支持 `mkv`、`avi`、`rmvb` 等容器，这些文件不会出现在资料库里
- 不支持外挂字幕和多音轨切换
- 画中画只能真机用，模拟器不支持

## 项目结构

```text
LocalPlayer/
├── App/          入口、全局环境、场景生命周期
├── Models/       VideoItem、播放模式等数据模型
├── Player/       PlayerModel（AVPlayer 封装）、视频画面视图
├── Services/     资料库扫描、导入、进度、缩略图、锁屏信息
├── Support/      画中画、转屏幕布、亮度与音量、格式化
└── Views/        资料库、播放页、设置、卡片与菜单
docs/images/      README 里的截图
```

画面用 `AVPlayerLayer`，画中画用 `AVPictureInPictureController`，锁屏卡片用 `MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter`，缩略图用 `AVAssetImageGenerator`。

## 维护与反馈

[@loinz-Max](https://github.com/loinz-Max) 维护。

遇到崩溃、手势不对、某个文件播不了，欢迎开 [Issue](https://github.com/loinz-Max/localplayer/issues)，写上机型和 iOS 版本就够。想改代码的话，建议先开 Issue 说一声再动手：这个 App 的取舍比较个人化，方向不合适的改动不会合并，先说清楚能省双方时间。

## 致谢

谢谢 Apple 的 AVKit 文档和 [SF Symbols](https://developer.apple.com/sf-symbols/)，图标都来自它。

## 许可证

[MIT](LICENSE) © 2026 loinz-Max
