# 字体目录

## 为什么字体要进仓库

用 `SystemFont` 时，Godot 找不到候选字体会**静默回退**到任意字族。后果是：
开发者机器上排版正常，玩家机器上换个字体，行宽、行高、标点位置全变，
长文本会溢出卡片、按钮文字被截断。这类问题不会报错，只会在别人的截图里出现。

所以正文与标题字体都必须**随包分发**，不依赖系统。

## 现有文件

| 文件 | 家族 | 体积 | 用途 | 进包 |
|---|---|---|---|---|
| `NotoSansSC-subset.ttf` | Noto Sans SC 子集 | 0.8 MB | 全局正文与控件默认字体 | ✅ |
| `NotoSerifSC-subset.ttf` | Noto Serif SC 子集 | 1.0 MB | 标题 / 章节名 / 结局 | ✅ |
| `NotoSansSC-VF.ttf` | Noto Sans SC（可变字重，全量） | 17.7 MB | 子集化的**源**，开发机保留 | ❌ |
| `NotoSerifSC-VF.ttf` | Noto Serif SC（全量） | 25.1 MB | 同上 | ❌ |
| `LICENSE-OFL.txt` | — | — | SIL OFL 1.1 全文（分发时必须随附） | ✅ |

两份全量版都在 `export_presets.cfg` 的 `exclude_filter` 里，发行包只带子集。
改文案后一定要重跑 `python tools/make_font_subset.py`，否则新出现的字会变豆腐块。

来源：Google Noto 字体计划，本机 `C:\Windows\Fonts\NotoSansSC-VF.ttf` 与 `NotoSerifSC-VF.ttf`。
版权与许可见 `LICENSE-OFL.txt`：**SIL Open Font License 1.1**，允许随软件免费分发与嵌入，
允许商用；限制是不得单独售卖字体本身、派生字体不得使用保留名称 `Source`。

> 我们不修改字体文件，只是原样嵌入，因此不涉及保留名称条款。
> 打包/上架时把 `LICENSE-OFL.txt` 一并带上即可满足 OFL 第 2 条。

## 加载方式

`ui/ui_kit.gd` 用 `FontFile.load_dynamic_font()` 在运行时直接读 `.ttf`：

```gdscript
var f := FontFile.new()
f.load_dynamic_font("res://fonts/NotoSansSC-VF.ttf")
```

**不用** `load("res://fonts/xxx.ttf")`——那要求编辑器先导入、生成 `.import` 与缓存，
在导出包、CI、以及「只拷源码不拷 `.godot/`」的场景里都会踩空。
`load_dynamic_font` 走 `FileAccess`，导出的 pck 内同样有效。

文件缺失时回退到 `SystemFont` 并 `push_warning`，不会白屏，但排版会漂移。

## 已知缺口：衬线字体尚未内置

`NotoSerifSC-VF.ttf` 有 25 MB，只用于标题（`Kit.serif_lbl`），当前仍走 `SystemFont`。
影响可控（大字号、字数少），发行前应当：

1. 用 `pyftsubset` 按游戏实际用字子集化，两个文件都能压到 1 MB 量级；
2. 子集化后再放进来，替换 `ui_kit.gd` 的 `EMBEDDED_SERIF` 路径。

子集化命令（需要 `pip install fonttools`，本机 sandbox 装不了，需在正常网络环境跑一次）：

```bash
pyftsubset NotoSansSC-VF.ttf \
  --text-file=charset.txt --flavor=woff2 --output-file=NotoSansSC-subset.woff2
```

`charset.txt` 的字符集可以用 `tools/gen_charset.py` 从 `content_full.py` 里直接抽。

## 踩坑

- **可变字体上不要调 `get_font_name()` / `get_font_style_count()`**：Godot 4.7.2
  headless 下会卡死（无输出直到超时）。字体身份校验放在 Python 侧解析 TTF `name` 表。
- 字体文件不需要 `.import`，但如果哪天改成 `load()` 加载，记得把 `.godot/` 一并保留。
