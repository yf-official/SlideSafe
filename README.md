# SlideSafe

<p align="center">
  A native macOS utility that makes PowerPoint typography more portable.
</p>

SlideSafe creates a separate `.pptx` copy and replaces supported text objects with embedded image representations. This reduces layout changes caused by missing fonts, unavailable font variants, or different font environments on another computer. The original presentation is never overwritten.

> SlideSafe does not use PowerPoint's native “Convert to Shape” command. It renders text locally and embeds the result as SVG-based images with PNG compatibility fallbacks.

## Features

- Drag and drop or choose a `.pptx` file.
- Convert all supported text or only selected font families.
- Preserve text placement, rotation, line breaks, alignment, margins, solid and gradient colors, opacity, underline, outlines, bold, and italic styling where supported.
- Handle common WordArt warp presets, vertical text, and the visual appearance of hyperlinks.
- Replace text inside groups in place while preserving the group, sibling pictures, other shapes, and stacking order.
- Resolve fonts and theme styles through slides, layouts, masters, color maps, and East Asian font mappings.
- Keep unsupported objects unchanged and list them in a scrollable review report.
- Process presentations locally inside the macOS App Sandbox; no presentation data is uploaded.
- English and Simplified Chinese interface with light and dark appearance support.

## Requirements

- macOS 14 Sonoma or later
- A `.pptx` presentation
- Microsoft PowerPoint is recommended for checking the generated copy

## Download

Download the current build from [GitHub Releases](https://github.com/yf-official/SlideSafe/releases/latest).

The initial release is locally signed but not Apple-notarized. If macOS blocks the first launch, Control-click the app in Finder, choose **Open**, and confirm.

## How to use

1. Open SlideSafe and drop in a `.pptx` file.
2. Select **Analyze**.
3. Review unsupported items and choose **All Text** or **Selected Fonts**.
4. Create the safe copy.
5. Review the conversion summary, then open the new presentation.

The generated file is saved beside the source presentation with `- SlideSafe` appended to its name. Existing files are not replaced.

## Important behavior and limitations

- Converted text is no longer editable as text because it has been replaced by an image representation.
- Hyperlink text keeps its visual styling, but the click action is removed after conversion.
- Advanced per-letter, per-word, or per-paragraph animations are not converted.
- Tables, charts, SmartArt, equations, and text with unsupported shape-level effects remain unchanged and are reported for review.
- Unavailable fonts are not silently substituted. The affected text remains editable and is reported.
- Visual fidelity depends on the fonts installed on the Mac performing the conversion.

## Privacy

SlideSafe works locally. It does not require an account, network connection, analytics service, or cloud upload. File access is limited by the macOS App Sandbox to files selected by the user.

## Build from source

Open `SlideSafe.xcodeproj` in Xcode, or run:

```sh
xcodebuild \
  -project SlideSafe.xcodeproj \
  -scheme SlideSafe \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/DerivedData
```

The project builds a universal Apple silicon and Intel application.

<details>
<summary><strong>中文介绍</strong></summary>

## SlideSafe 是什么

SlideSafe 是一款原生 macOS 工具，用来降低 PowerPoint 在其他电脑上因字体缺失、字体版本差异或字形不可用而产生的排版变化。

它会创建一个新的 `.pptx` 副本，并把支持的文字对象替换为嵌入式图片表示。原演示文稿不会被覆盖。

> SlideSafe 并不是调用 PowerPoint 的原生“转换为形状”功能。它在本机渲染文字，再以 SVG 图片及 PNG 兼容后备资源的形式写入演示文稿。

## 主要功能

- 拖放或选择 `.pptx` 文件。
- 转换全部支持的文字，或只处理指定字体。
- 在支持范围内保留位置、旋转、换行、对齐、边距、纯色与渐变、透明度、下划线、描边、粗体和斜体效果。
- 支持常见艺术字弯曲效果、竖排文字以及链接文字的视觉样式。
- 可在组合内部原位替换文字，同时保留组合结构、同组图片、其他图形和层级顺序。
- 自动解析幻灯片、版式、母版、主题色与东亚字体映射。
- 不支持的对象会保持原状，并在可滚动的结果页面中列出。
- 所有处理均在本机和 macOS App Sandbox 内完成，不会上传演示文稿。
- 支持简体中文、英文以及系统浅色/深色外观。

## 使用方法

1. 打开 SlideSafe，拖入一个 `.pptx` 文件。
2. 点击“开始分析”。
3. 查看需要复核的对象，选择“全部文字”或“指定字体”。
4. 创建安全副本。
5. 查看转换报告并打开新文件。

新文件保存在原文件旁边，文件名会增加 `- SlideSafe`；已有文件不会被覆盖。

## 注意事项

- 转换后的文字已经成为图片表示，因此不能继续作为文字编辑。
- 链接文字会保留视觉样式，但点击动作会被移除。
- 复杂的逐字、逐词或逐段动画不会转换。
- 表格、图表、SmartArt、公式以及带有不支持形状级特效的文字会保持原状，并列入复核报告。
- 软件不会擅自替换缺失字体；相关文字会保持可编辑并列入报告。
- 转换效果取决于执行转换的 Mac 上实际安装的字体。

</details>
