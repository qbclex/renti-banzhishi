# 人体值班室 · Godot 迁移 POC

验证目标有两个，缺一不可：

1. **规则层等价**：把 `engine.py` 完整移植到 Godot 4 (GDScript)，并证明是**逐位等价**，而不是"能跑就行"；
2. **表现层可行**：用移植后的引擎做出**能点、能玩完整 25 班**的界面，证明引擎接口够 UI 用。

跑的是**全量内容**（43 张牌 / 65 个工单 / 5 章 25 班 / 22 条知识点 / 25 条抉择 / 5 封来信）。

## 一、打开界面玩

### 给玩家的一键入口（唯一真源）

```
08_可玩原型\启动游戏.bat        ← 双击这个（老入口，现在也指向 Godot 版）
08_可玩原型\启动Godot版.bat     ← 等价
08_可玩原型\launch_godot.bat    ← 真正干活的只有它，上面两个都只是 call 它
```

- **为什么合并**：`启动游戏.bat` 原来跑的是 Python 桌面残本 `game.py`（没接美术管线、Python 里没 PIL），
  结果是「图片一张都不显示、顶栏没有音效栏、只有一处有声音」。那三个现象是**入口指错了**，不是 Godot 版坏了。
  现在两个入口都 `call launch_godot.bat`，入口不会再和游戏分叉（`tests/` 里有 `TestEntryConsistency` 守着）。
- **全部纯 ASCII**：`cmd.exe` 按系统 ANSI 代码页（zh-CN = GBK）解析 `.bat`，与 `chcp` 无关，
  脚本里写中文会被吃成乱码并破坏 `set` 语句——这是真实踩过的坑。中文目录靠 `%~dp0` 运行时展开。
- **自检**：`启动游戏.bat --dry-run` 只打印解析出的 exe / 工程 / `project.godot` 是否存在，不开窗口。
- **日志**：所有输出写到 `godot_poc\godrun.log`；**运行成功时窗口直接关掉，只有失败才停下并显示末 40 行**。
- 参数会透传：`启动游戏.bat --autoplay --seed=12` 可从这个入口直接跑巡演。

### 直接用 Godot 打开（开发用）

```bat
cd 08_可玩原型\godot_poc
godot --path .            REM 或直接双击 Godot 打开本目录后按 F5
```

窗口 1280×820，五种模态串起完整流程：

```
开场简报 → 值班（选工单 → 点牌/等一刻/换签）→ 结果反馈 → 班中抉择
        → 结算评级 → 下一班 → …… → 25 班完成 → 通关 / 真结局
```

**操作**：点工单选中（默认已选第一张）→ 点手牌处置；`1`–`6` 出牌，`空格` 等一刻，`R` 换签。
鼠标悬停在工单/卡牌上会显示病情提示与知识点。

**存档与音效**（顶栏三个按钮，也有快捷键）：

| 键 | 作用 | 说明 |
|---|---|---|
| `Ctrl+S` / 点「存档」 | 手动存档 | 每班推进后还会**自动存一次**，硬关机最多丢一班 |
| `Ctrl+L` / 点「读档」 | 读档 | 读档后洗牌序列与存档时一致（`rng.state` 一起存） |
| `M` / 点「音效 开」 | 静音切换 | 静音不影响任何玩法信息 |

启动时若存在存档会自动续玩；想从零开始加 `--fresh`（巡演/截图模式内部已强制清档，保证可复现）。

界面截图在 `_shots/`（由 `--shot` 模式自动生成，见下）。

## 二、跑一致性验证（无头）

```bat
cd 08_可玩原型\godot_poc
godot --headless --path . --script main.gd -- 20261030 --check
```

输出形如：

```
TRACE_BEGIN
P|0|0|1|c_rest|o_stomach_0|65,35,34,30,25,50
...
S|4|1|82|A
TRACE_END
SUMMARY|cleared=true|incidents=0|misleading=0|true_ending=false
STATS|plays=59|dilemmas=15|combos=0|cures=0|emergencies=5|retries=0
RATINGS|A,B,C,B,C,A,B,B,C,B,A,C,B,C,A
SELF_CHECK_OK        ← 不变式断言全过（clock 不越界 / 指标 0–100 / 评级已生成 / 15 个评级槽位）
```

## 三、自动化模式一览

| 命令 | 作用 | 需要窗口 |
|---|---|---|
| `godot --headless --path . -- --autoplay` | 让**界面层自己**把 25 班走完（走的是和玩家点击完全相同的入口），并夹一次「存档→改动→读档」往返，输出 `AUTOPLAY_OK` + `SAVE_ROUNDTRIP OK` | 否 |
| `godot --headless --path . -- --autoplay --seed=12` | 指定种子巡演。固定种子只能验一条路径，很多分支（双红旗 / 低信任 / 透支结局）永远碰不到 | 否 |
| `godot --headless --path . -- --autoplay --chaos` | **混沌巡演**：故意把非转诊牌打到红旗上（制造事故→本班作废→重打）、随机选抉择项、随机换签与等一刻。正常巡演 `waits=rerolls=incidents=0`，这几条路径等于没测过 | 否 |
| `godot --headless --path . --script tools/refer_probe.gd` | 红旗可解性：突发红旗补牌 / 旧档读回自愈 / 补出来的牌真能打 | 否 |
| `godot --path . -- --shot` | 自动演一遍并截图到 `_shots/`（简报/值班/结果/抉择/结算/通关 共 6 张） | 是 |
| `godot --headless --path . --script main.gd -- <seed> --check` | 纯规则层的无头对局 + 自检 | 否 |
| `godot --headless --path . --script tools/save_probe.gd` | 存档确定性探针：同快照走两条路，逐步指纹必须逐字相同（含 `rng.state`） | 否 |
| `godot --headless --path . --script tools/audio_probe.gd` | 音效探针：15 条配方都要渲出正确长度且非静音的波形 | 否 |
| `godot --headless --path . --script tools/font_probe.gd` | 字体探针：**两支子集**都能加载、21 个正文采样字无缺、兜底链可用 | 否 |
| `godot --headless --path . --script tools/icon_sheet.gd` | 图标对照图：三档尺寸 + 空图/贴边/过窄检查 | 否 |
| `godot --headless --path . --script tools/bake_card_art.gd` | 插画烘焙：`assets/art_src/` → `assets/cards/`（无原图时明确 SKIP） | 否 |
| `godot --headless --path . --script tools/bake_selftest.gd` | 烘焙自测：三种极端比例 + 可复现 + 不压死黑 + 曝光能对齐 | 否 |
| `godot --headless --path . --script tools/hand_sheet.gd -- --layout-only` | 卡面布局检查：报出每张牌的真实高度，**一排牌必须等高** | 否 |
| `godot --path . --script tools/hand_sheet.gd -- c_sleep c_er` | 指定手牌样张：用真实卡面渲染成图（`user://hand_sheet.png`） | 是 |
| `godot --path . --script tools/char_sheet.gd -- --scale 1 --page 0` | 立绘对照表：**一行一个宿主的四个表情**，按显示尺寸 216×288 排 | 是 |
| `godot --headless --path . --script tools/char_probe.gd` | 立绘探针：照片实际尺寸 / 出窗 / 正文列宽 / 评级→表情映射 / 逐章换人 | 否 |
| `godot --path . --script tools/art_sheet.gd -- --scale 2 --page 0` | 插画对照表：43 张按**卡面真实尺寸 132×60** 排列，逐张判"还能不能认"（分页 0/1/2） | 是 |
| `godot --headless --path . -- --selfcheck` | 发行前自检：立绘 5×4 / 背景 3 / 图标全量 / 卡面 43 / **sans 与 serif 都是内置 ttf** / `user://` 能不能写。**资源没进包时游戏照样能跑，只有这条会红** | 否 |
| `godot --headless --path . -- --packlist` | 从包内部遍历 `res://`，逐个打印文件与字节数（核"到底打包了什么"） | 否 |
| `godot --path . -- --audiocheck` | 音频接线检查：BGM 是否真的在播、走的是不是 Music 总线、播放位置有没有在走。**只能在有窗口时跑**，dummy 驱动下不出声 | 是 |
| `godot --path . res://tools/store_art.tscn` | 出商店素材：9 张胶囊图 + 6 档图标像素（字体/立绘/配色都取自本体） | 是 |
| `python tools/make_ico.py` | 把 `_store/icon_*.rgba` 拼成 `assets/icon.ico`（6 档 BMP 条目） | 否 |
| `python tools/prepare_export_assets.py` | 导出前生成图标 `.raw` 副本（`build_win.bat` 自动调） | 否 |
| `python tools/png_edge.py _shots/02_shift.png 03080A` | 边缘裁切检查：读最后一行像素，判断面板有没有溢出窗口 | 否 |

`--autoplay` 是这次新增的关键一环：一致性测试只证明"规则一样"，它证明"**按钮 → 引擎 → 重画 → 弹窗**这条接线在 15 个班次里不会卡死"。实测：

```
SAVE_ROUNDTRIP OK before=[c0/8|energy=62,...] moved=[c1/8|...] back=[c0/8|...]
AUTOPLAY_OK cleared=true shifts=15 plays=59 waits=27 rerolls=12 dilemmas=11 incidents=0 save=true
ratings=ABCBCSBBCAACBCA
```

## 三·五、音效与存档的实现要点

**音效：零素材、三端同配方。** 配方唯一来源是 `content_full.SOUNDS`（15 条：波形/扫频/包络/和弦/噪声/脉冲），
网页用 WebAudio 实时合成，桌面版用 `wave` 离线合成，Godot 端 `audio/sfx.gd` 用同一条公式算 PCM 塞进
`AudioStreamWAV`（22050Hz / 16bit / 单声道）。好处是改一个数字三端同时生效，且**可测**——
`tools/audio_probe.gd` 直接检查每条音效的采样数与非静音峰值，不需要耳朵。

**清脆化调校（2026-11-02）。** 原配方偏"肉"：`sine/triangle` 无高频、攻击偏钝、衰减常数 3.4 拖尾。
改法在三端同一条公式里：① 新增 `tick` 起音瞬态——一段 4ms 的 5.5kHz 脉冲（平方窗快起快落）混入起音，
这是"敲击感"的主来源（`SOUNDS` 各条 `tick=0.1~0.5`）；② 衰减常数 3.4→4.2，尾音更收得住；
③ `ui/select/good/cure/card/combo/toast` 由 `sine` 提亮到 `triangle`，`ui/select/toast` 频率略升。
`tools/sfx_probe.gd` 量化验证：起音 `attack_idx` 降到 ~11 样本（≈0.5ms），前 4ms 过零 `zc_4ms` 由 6 升到 18（高频翻倍）。

**桌面版播放坑（2026-11-02 修）。** 桌面版 `audio.py` 原先用 `winsound.PlaySound(data, SND_MEMORY|SND_ASYNC)`，
但 CPython 的 winsound **禁止** `SND_MEMORY|SND_ASYNC` 组合，会抛 `RuntimeError: Cannot play asynchronously
from memory`；而 `play()` 把异常 `except: pass` 吞掉，于是「启动游戏.bat」全程静音且无报错。修法：先把 WAV 落盘到
临时目录 `hbn_sfx/`，再用 `SND_FILENAME|SND_ASYNC` 播文件（按音名会话级缓存，只写一次）；极端情况退回 `SND_MEMORY`
同步播。Godot 端与网页端不受影响（各自走 `AudioStreamPlayer` / WebAudio）。
`settle/shift/ending` 等舒缓音只给少量 `tick`，保留余韵。

触发点是"引擎置标志、表现层取走"：`combo_flash` / `cured_flash` / `emergency_flash` / `streak_flash`
由 `Game` 置位，`main_ui.gd::_consume_flashes()` 读完即清空，引擎一行都不用为表现层改动；
新增状态走 `_refresh()` 里的差集检测（`_sync_status_sfx`），所以"超时恶化 / 抉择附带 / 纠纷升级"
三条路径都不会漏音。

**存档：整局快照 + 保住随机数位置。** `Game.snapshot()/restore()` 序列化 `campaign`、
`rng.state` 和整班状态（`vitals/clock/orders/hand/deck/discard/log/stats/statuses/rerolls/escalated/dilemma/rating`）。
两个关键决定：

1. 用 `var_to_str / str_to_var` 而**不是 JSON**——JSON 往返会把 `int` 读成 `float`，
   而刻数、血量全是整数运算，一旦变浮点 `range()` 和 `%d` 都会炸；
2. `rng.state` 必须一起存，否则读档后洗牌序列换了一条线，玩家会发现"同样的操作，抽到的牌不一样"。

`tools/save_probe.gd` 把这件事验证死了：同一份快照，一条路直接继续跑 60 步，
另一条先写盘再读回**另一个 `Game` 实例**，两条路的逐步指纹（含 `rng.state`）必须逐字相同；
顺便还要求"读回来的快照再序列化一次，字符串一模一样"。实测 `SAVE_PROBE OK … restored=true reserialize=true`。

## 三·六、打包成 exe（发行）

```bat
cd 08_可玩原型
build_win.bat
```

产物是**单文件** `godot_poc\build\windows\RenTiBanZhiShi.exe`（109 MB，PCK 内嵌，拷走就能玩）。

前置只有一条：导出模板得在。没有的话：

```bat
python godot_poc\tools\fetch_templates.py --release-only
```

官方的 `export_templates.tpz` 是 1.28 GB 的全平台包，这里只从里面 Range 取
`windows_release_x86_64.exe` 那一段（36 MB 压缩 / 104 MB 解压）。脚本用 curl 分块续传，
断点记录是「`.part` 现在多长」，所以断了重跑不会从头来。

`build_win.bat` 干三件事：生成图标 `.raw` 副本 → `--export-release` → **用导出的 exe 自检**。
最后一步是硬闸门，退出码非 0 就判构建失败。

### 自检为什么必须存在

这个项目的美术全部是**运行时**读原文件（`Image.load_from_file`、`Image.load_svg_from_string`），
不走 Godot 的导入管线。代价是：**资源没进包时游戏不会崩，只会安静地少画东西**。
上一版 exe 就是活证据 —— 20 张立绘、3 张背景、25 个图标、整套字体全都不在包里，
而 `--autoplay` 依然打印 `AUTOPLAY_OK cleared=true`。

```
SELFCHECK OK art_missing=0 icons=25 chars=20 bgs=3 cards=43/43 font_embed=true serif_system=true save=true
```

判四条：立绘 5×4 / 背景 3 / 图标全量（清单从目录读，不写死）/ 字体必须来自内置 ttf（不是 `SystemFont` 兜底）/
`user://` 真的写得进去。

`--packlist` 则从**包内部**遍历 `res://`，打印每个文件的实际字节数 —— 想在外部手写
PCK 解析器是行不通的：4.7 的包把文件名压成了 GST2 表，肉眼和正则都读不出条目。

### 三个已经踩平的坑

1. **导入管线会吃掉原始资源。** `.png/.webp/.svg/.ttf` 都是"可导入"扩展名，导出时包里
   只剩 `.ctex/.fontdata`，原始文件一个字节都没有。而 `.import` 里那句
   `source_file="res://…"` 会让 `d.count("res://assets/…")` 数出 1 —— 看着像在，其实不在。
   解法见下：图标生成 `.raw` 副本（非资源文件，`include_filter="*.raw"` 能原样带走），
   立绘/背景/卡面/字体改成「先 `load()`，不行再现读」。
2. **`.gdignore` 不是"不导入"，是"当这个目录不存在"。** 放进去之后编辑器看不见、导出也
   看不见，包体直接掉到 156 KB，只剩脚本。想验证某个目录有没有进包，别用 golang 式的直觉。
3. **在桌面目录下跑 exe，本机策略禁止它写盘。** 同一个 exe 拷到 `%TEMP%` 或
   `%LOCALAPPDATA%` 就一切正常（存档、日志都写得进去）。所以闸门里先 `copy` 到
   `%TEMP%\rtbzs_verify\` 再自检，否则 `save=false` 会是假警报，查半天以为是代码问题。

## 四、结构

| 文件 | 作用 |
|---|---|
| `data.gd` | 全量数据，**自动生成**（`gen_data_gd.py` 从 `content_full.py` 生成），勿手改 |
| `engine.gd` | `Game` 类，纯逻辑、零节点依赖，逐行移植自 `engine.py`；含 `snapshot()/restore()` |
| `main.tscn` | 主场景：一个 `Control` 挂 `ui/main_ui.gd` |
| `ui/main_ui.gd` | 界面层：只负责「画」与「收输入」，规则一律调 `Game` 的方法 |
| `ui/ui_kit.gd` | 配色/字体/控件工具箱（与网页版 `src/css` 同一套设计令牌） |
| `ui/card_art.gd` | 卡牌插画条：读 `assets/cards/`，缺图时给占位条（不留空） |
| `ui/char_art.gd` | 角色立绘：读 `assets/chars/`，按 (宿主, 表情) 缓存，缺图返回 null |
| `ui/bg_art.gd` | 全屏背景：读 `assets/bg/`（webp 优先，png 兼容），只缓存一张，缺图返回 null；`scene_for` 三分支指向护理站/走廊/病房 |
| `assets/cards/` | 烘焙好的插画条 264×120（`bake_card_art.gd` 的产物） |
| `assets/chars/` | 烘焙好的立绘 432×576（`bake_char_art.gd` 的产物），20 张 |
| `assets/bg/` | 烘焙好的全屏背景 1920×1230 **WebP q=0.92**（`bake_bg.gd` 的产物） |
| `assets/bg_src/` | 背景原图 1536×1024，**不进包**（2.0 MB/张），见该目录 `README.md` |
| `assets/chars_src/` | 立绘原图 1024×1536，**不进包**；`_cand/` 留被换掉的一版 |
| `assets/icons/` | 手写 SVG 图标（24 网格 / 1.8 线宽 / `currentColor`） |
| `ui/save_sys.gd` | 存档槽：`user://save/slot1.sav`，带版本号与时间戳 |
| `audio/sfx.gd` | 程序化音效：`SOUNDS` 配方 → PCM → `AudioStreamWAV`，带播放器池与静音开关 |
| `ui/icons.gd` | 运行时 SVG 图标：零导入依赖、跟随语义色、按尺寸重新光栅化 |
| `assets/icons/*.svg` | 图标源文件（手写，规范见该目录 `README.md`） |
| `assets/art_src/` | AI 原图，**不进安装包**（实际 105 MB，43 张 1536×1024），见该目录 `README.md` |
| `fonts/NotoSansSC-subset.ttf` | 内置正文字体，子集版（OFL 1.1），见 `fonts/README.md` |
| `fonts/NotoSerifSC-subset.ttf` | 内置标题字体，子集版（OFL 1.1） |
| `fonts/charset.txt` | 本作实际用字 1273 个，供发行前子集化 |
| `tools/save_probe.gd` | 存档确定性探针（引擎级，无 UI） |
| `tools/audio_probe.gd` | 音效波形探针 |
| `tools/font_probe.gd` | 字体探针：内置字体是否真的加载、字形宽度、兜底链 |
| `tools/svg_probe.gd` | SVG 能力探针：运行时光栅化 / 缩放 / `currentColor` 替换 |
| `tools/icon_sheet.gd` | 图标对照图：32/16/12px 三档 + 安全区与外接框检查 |
| `tools/card_art.gd` | 插画烘焙逻辑（裁切 / 双色调 / 颗粒），纯函数可测 |
| `tools/bake_card_art.gd` | 插画烘焙入口：`assets/art_src/` → `assets/cards/` |
| `tools/bg_art.gd` | 背景烘焙逻辑（取景 / 亮度曲线 / 暗角 / 水印清除），纯函数可测 |
| `tools/bake_bg.gd` | 背景烘焙入口：`assets/bg_src/` → `assets/bg/`（输出 WebP） |
| `tools/bg_probe.gd` | 背景亮度普查：分位数 / 九宫格 / 四边 / 水印残留，输出机器可读的 `STATS` 行 |
| `tools/bake_selftest.gd` | 烘焙自测：三种极端比例 + 可复现 + 不压死黑 |
| `tools/gen_charset.py` | 从 `content_full.py` 抽字符集，供 `pyftsubset` 用 |
| `tools/hand_sheet.gd` | 指定手牌样张 / 等高检查（`--layout-only` 可无头跑） |
| `tools/art_sheet.gd` | 插画对照表：43 张按卡面真实尺寸 132×60 排列（分页，受主窗口 1280×820 限制） |
| `tools/png_edge.py` | PNG 边缘裁切检查 + 裁切放大（无 PIL 时的替代） |
| `main.gd` | 无头驱动整场战役 + 自检（`extends SceneTree`，入口 `_initialize`） |
| `project.godot` | 项目配置（主场景、1280×820、gl_compatibility 渲染器） |


数据与工具在上层目录：

| 文件 | 作用 |
|---|---|
| `../gen_data_gd.py` | 生成器：默认从 `content_full.py` 出全量 `data.gd`；`--mini` 出迷你集 `data_mini.gd` |
| `../poc_data.py` | 迷你数据集，用于把"数据问题"与"移植问题"分开排查 |
| `../tools/parity_check.py` | 双端一致性回归：多种子跑 Python + Godot，逐行 diff 轨迹 |

### 界面层的分层约束

这是整个 POC 最重要的工程约定，也写进了测试（`tests/test_godot_ui.py`）：

- **`ui/main_ui.gd` 里不许出现** `compute_rating` / `apply` / `eff_limit` / `vital_cap` / `_round_div`
  这类规则实现——一旦界面开始自己算规则，双端就会重新分叉；
- 界面改状态只走 `Game` 的公开方法：`play_card` / `wait` / `reroll` / `choose_dilemma` /
  `start_shift` / `load_shift` / `advance` / `save_rating`；
- 每次操作后 `_refresh()` 整屏重画。POC 阶段不在乎这点开销，换来的是**状态永远只有一份**。

### 指标条：颜色只说「危险程度」

左侧六项身体指标**不按指标身份上色**，颜色只承载危险程度——与网页端 `render.js` 同一套规则：

| 健康度 | 色 | 说明 |
|---|---|---|
| > 0.62 | 绿 `#7BE0A8` | 进度条填充与数值 |
| > 0.38 | 黄 `#F5D26B` | 同上 |
| 其余 | 红 `#FF9A7E` | 同上 |
| 警戒（better<35 / worse>68） | 橙 `#FFB29B` + 描边 | 名字与数值变色 |

健康度：`better` 类取原值、`worse` 类取 `100 - 原值`；但进度条**长度**仍用原值
（睡眠债 35 → 只填 35%，颜色却是绿的，因为 35 的睡眠债不算糟）。

早先的实现是「六个指标各一种固定色 + `health < 30` 才变红」，
结果压力与炎症撞成同一个 `#D95E42`，且金色（代谢负荷）被误读成警告。
加一个新颜色只是在错误模型上打补丁，所以改成现在这样：**一种颜色只表达一件事**。
四条测试（`TestArtTokens`）解析 `render.js` 与 `03_components.css` 做逐字比对，
只改一端会直接失败。

### 中文字体（已随包内置）

Godot 默认字体不含中文（会满屏方块）。早期版本用 `SystemFont` 指定候选链 + `allow_system_fallback`
做到「零字体资源」，但那有个隐性代价：**字体会静默回退**，于是开发机与玩家机字形不同，
行宽、换行位置、标点挤压全变，长文案会溢出卡片和按钮，而且不报错。

现在**正文与标题都随包内置**，各一支：`fonts/NotoSansSC-subset.ttf`（正文）与
`fonts/NotoSerifSC-subset.ttf`（标题 / 章节名 / 结局）。两支都是 Noto，SIL OFL 1.1，可商用可嵌入。

- 加载走 `FontFile.load_dynamic_font()`，**不用** `load("res://…ttf")`——
  后者依赖编辑器导入出的 `.import` 与缓存，导出包 / CI / 「只拷源码」三种场景都会踩空；
- `SystemFont` 降为兜底，且回退时 `push_warning`，不再静默；
- `fonts/LICENSE-OFL.txt` 是 OFL 1.1 全文（第 2 条要求分发时随附），打包别漏；
- **全量 Serif 25 MB / Sans 17.7 MB，发行前必须子集化**：`tools/make_font_subset.py`
  从源码抽字（先剥注释行），两个字族用**同一份字符集**、取两者可用字的交集，
  裁完 sans 0.8 MB + serif 1.0 MB。全量版在 `exclude_filter` 里，不进包。

> 踩过的坑：`EMBEDDED_SERIF` 曾经指向 `fonts/NotoSerifSC-VF.ttf`，而这个文件
> **从来没进过仓库**。`serif()` 每次都静默回退 SystemFont，自检只打印不判定，
> 于是「主标题在每台机器上都不一样的字形」这件事一路绿灯到发行前。
> 现在两支字体都是硬判据（`font_embed` + `serif_embed` 都要 true）。

验证不靠看截图：`tools/font_probe.gd` 直接问**子集版**要字形（加载返回值、三个字号的宽度、
21 个正文采样字是否都有字形、SystemFont 兜底是否可用），输出 `FONT_PROBE OK embedded=both`。

### 图标：手写 SVG，运行时加载

指标条取消身份色之后，识别度全靠图标补回来。**24 个图标**，源文件在 `assets/icons/`，
规范见该目录 `README.md`：

| 组 | 数量 | 用在哪 | 意象 |
|---|---|---|---|
| 身体指标 | 6 | 指标条（13px） | 闪电 / 月牙 / 对压箭头 / 火焰 / 温度计 / 心形 |
| 卡牌类型 | 6 | 卡面 chip（12px）+ 缺图占位条（26px） | 日历 / 房屋 / 眼睛 / 圆环十字 / 气泡 / 烧瓶 |
| 工单类型 | 3 | 工单 chip（12px） | 锤子 / 波 / 燕尾旗 |
| 顶栏功能 | 4 | 顶栏按钮（13px） | 下箭头+托盘 / 上箭头+托盘 / 喇叭+声波 / 喇叭+叉 |
| 状态标签 | 5 + 复用 | 状态行（13px） | 单峰心电 / 拱形折返 / 床 / 水滴 / 问号 |

两种前缀是命名空间问题：工单用 `order_`（`common/emotion/redflag` 是数据字段值，
裸名会和卡牌类型 `life/home` 挤在一起），状态用 `st_`（`insomnia`/`dehydration`
与卡牌、指标的词义相近，不加前缀看不出是哪一套）。

**状态行不读数据里的 `icon` 字段**。`data.gd` 存的是字符（♥ ▲ ☾ ✳ ◈ ?），五套字形混排，
线宽和重心全不齐；UI 只认 `ui_kit.STATUS_ICONS`，字形只作兜底。

三个决定：

1. **手写 SVG，不用 AI 生图**。图标要求六个并排时线宽、圆角、视觉重心完全一致，
   生图模型每张都在重采样，做不到；
2. **运行时 `Image.load_svg_from_string()`，不用 `load("res://x.svg")`**。
   后者要求编辑器先导入、生成 `.import` 与 `.godot/` 缓存，导出包和 CI 都会踩空
   （字体那轮已经吃过一次）；
3. **小尺寸自动加粗**。`1.8` 的线画在 24 网格上，渲染到 13px 只有 0.98 像素——
   不足 1 像素的线会变成半透明灰雾。`icons.gd` 按尺寸给 2.4 / 2.0 / 1.8。

验证靠 `tools/icon_sheet.gd`：把全部图标按 32/16/12px 渲成一张图，小尺寸用**最近邻放大 4 倍**
（像素级看糊没糊），同时打印每个图标的**墨迹外接框**、**光学尺寸**与不透明像素数。

这个数比肉眼可靠：压力图标最初画成正弦波，外接框只有 8 单位宽、墨迹 128 像素，
并排时明显比其他图标瘦——肉眼看不太出来，量出来的数一眼就露馅。改成对压箭头后
到 12 宽 / 180 像素才齐。

**12px 是唯一验收档**。累计有 5 个候选被 12px 判死并重画：日出（弧线压扁成一条横杠）、
斜置扳手（只剩一根斜线）、正弦波（变成锯齿噪点）、**完整心电折线（压成一个「十」字）**、
**向上箭头穿横线（读作「上传」且与「读档」同形）**。活下来的共同点是**主体是一块而不是一组线**：
房屋、气泡、烧瓶、圆环十字、旗子、锤子、水滴。

有一条改不好、只能承认的：**声波在 12px 下不可表达**。`sound_on` 的两道弧会并成一团，
这是尺寸的物理极限。处理办法是靠按钮上的「音效 开/关」文字消歧，并在文档里写清
「16px 以上才清楚」——不写，下一个人会以为是自己画得不好。

图标接线之后，有两处只能量不能看：

| 探针 | 量的东西 | 必须等于 |
|---|---|---|
| `tools/chip_probe.gd` | chip 带/不带图标的宽度差 | 12 + 4 = **16**，且高度不变（23） |
| `tools/topbar_probe.gd` | 顶栏按钮带/不带图标的宽度差 | 13 + 5 = **18**，且高度不变 |

两条都在防同一件事：图标被排版丢掉或按 2x 原始像素占位时，界面看起来"一切正常"。
后者尤其隐蔽——`Icons.icon()` 生成的是 26px 贴图，绘制时才缩到 13，于是按钮变高 3px、
图标和文字之间空出一大块；截图看像是"设计师留白"，量出来才知道是 13px 的浪费。

### 卡牌插画

卡面顶部有一条 132×60 的插画条，来自 `assets/cards/<卡牌id>.png`（264×120 @2x）。
**43 张已全部出齐**（43 张原图在 `assets/art_src/`，105MB，不进包；产物 2.0MB 进包）。
四个决定：

1. **缺图给占位条，不留空**。现在 43 张都有图，这条退化成保险，但不能删：扩内容时
   新加的卡在出图之前会直接落到这条路径上。若只有有图的卡变高，同一排就会高低不齐，
   看起来像加载失败。占位条画**该类的大号类型图标水印**（26px、30% 不透明），
   读起来是"这一类牌的插画位"，不是"这里少一张图"。刻意不写类型名——名字在下面一行的 chip 里
   已经有一份，重复两遍只会显吵。
2. **`Image.load_from_file()`，不用 `load()`**。同字体、同图标，第三次踩同一个坑
   就不该再犯了：`load()` 依赖编辑器导入缓存，导出包和 CI 会踩空。
3. **一排牌必须等高**。`custom_minimum_size` 只是**下限**——`PanelContainer` 的实际高度是
   `max(最小值, 内容最小高度)`，四条效果的牌内容更高就会自己长高、向上溢出。
   所以效果表用流式紧凑组（`精力 +8  压力 -8`），最坏也只有两行，4 条和 2 条的牌都落在 216。
   `tools/hand_sheet.gd -- --layout-only` 会把每张牌的真实高度打出来，测试直接断言它们相等。
4. **卡宽 150 而不是省地方的 122**。手牌面板横跨整行，6 张 122 的牌排完按钮右边还空着
   约 300px；加宽后最长卡名（9 字）一行放下，卡高因此能从 242 降到 216——
   用横向空余换纵向空间，比去压榨工单列表合理（实测工单从 4 条可见变回 4 条）。

**插画怎么验收：`tools/art_sheet.gd`**。它把 43 张按**卡面真实尺寸 132×60** 排成对照表
（`--scale 2` 出 2 倍图查水印与文字残留）。这一步不能省，也不能用"单张大图"代替：
单看每张都好看，132 宽才是玩家实际看到的样子。第一批 4 张里 `c_talk`（空房间里两把椅子）
就是这么被否掉的——大图是张好照片，缩到卡面尺寸是一坨黑。

```bash
godot --path . --script tools/art_sheet.gd -- --scale 2 --page 0   # page 0/1/2
```

**必须分页**：43 张 4 列 2 倍图时一页 5 行。装不下的部分会被**静默裁掉**——
`save_png` 返回 OK，只是图变矮/变窄，不报错。第一版一页 6 列 7 行，右边两列和最后一行
全被切掉，是数格子数出来的。主窗口 1280×820 是硬的（`root.size = ...` 改不动它），
所以列数和每页张数都有上界，测试按这个上界钉着。

### 悬停检视：一张浮层，四种源

卡牌有 5 个字段，150×216 的卡面只放得下 4 个（插画/类型/标题/效果）。`d`（描述）和
`k`（知识点）此前挂在 `tooltip_text` 上——那是 **Godot 原生 tooltip**：系统黑框、0.5s 延迟、
跟着鼠标跑，和这套设计完全不搭。而知识正是这游戏的主要价值，等于埋了。

把卡牌救出来之后顺着同一条线查数据，发现被埋的不止卡牌：

| 源 | 之前能看到的 | 悬停补上的 | 为什么值得补 |
|---|---|---|---|
| 手牌 `card` | 插画 / 类型 / 标题 / 效果 | `d` 描述、`k` 知识点 | 知识是这游戏的主要价值 |
| 工单 `order` | 标题 / 器官 / 标签 / 两行正文 | `whisper` 心声、`danger` 不能等、`hint` 线索、完整正文 | 40 条心声和 6 条红旗警告在 Godot 端**一行都没显示过** |
| 状态 `status` | 名称 + 效果描述 | `hint`（为什么会有这个状态） | 6 条 hint 只活在数据里 |
| 指标 `vital` | 名称 + 数值 + 颜色 | 方向（越高/越低好）、警戒线、距警戒还差多少 | 玩家只能靠试才知道「睡眠债 40」是好是坏 |

四类源共用一张卡：`_hover(kind, id, on)` → `_show_inspect` → `_fill_inspect`，
只换「填哪个函数」和「锚在哪个节点」。锚点**每次现找**（`_anchor_for` 按 meta 键扫列表），
不缓存节点——重画一次，缓存下来的指针就是悬空的。

顺带说一句**这张表是怎么找出来的**：把 `content_full.py` 每个数据字典的键列出来，
逐个 `grep` `godot_poc/ui/`。没有任何引用的那一批，就是「写好了、也进 `data.gd` 了、
但玩家永远看不到」的字段。网页端其实有位置放它们（心声和线索在右栏「器官」位，
`render.js` 的 `organ-quote` / `organ-hint`），Godot 端没有那个栏位，于是整批沉默。

| 决定 | 理由 |
|---|---|
| 插画只到 264×120，**不再放大** | 原图 1536×1024 缩到 264×120 时已经丢过细节，再放大只是在 264 宽的图里插值。所以 `INSPECT_W - 28 == 264` 是硬约束，有测试钉着 |
| **宽度钉死 `INSPECT_W + 2`** | 跟着内容走的话，鼠标在工单之间移动时卡会一张一个宽度、位置横跳。实测标签行用 HBox 时把卡撑到了 356 |
| 工单的器官名 + 标签走 **HFlowContainer** | HBox 的最小宽会被子节点撑爆，流式容器到边就换行，宽度恒等于面板宽 |
| **绝对定位，不进容器** | 它要跨过手牌面板的边界浮到工单区上面，塞进任何容器都会被裁。加在模态层 `_overlay` 之前——全屏模态永远盖住它 |
| **0.16s 防抖 + 代数** | 扫过整排不该一路弹。每次进/出 `_inspect_gen += 1`，`await` 回来的那次对不上就放弃 |
| **每次整屏重画先收掉** | 重画会销毁被悬停的节点，而「节点没了」不会发 `mouse_exited`，卡会停在屏上讲一条已经不存在的工单 |
| 手牌/工单贴**上方**，指标/状态贴**右侧** | 左栏只有 236px 宽，往上放一钳就正好把这一栏自己盖住 |
| 上方放不下就**翻到下方** | 钳到 10px 会盖住自己悬停的那一条，玩家没法确认「我指的是这条吗」 |
| 效果行的名称列**固定 62px** | 名称是 2–3 个汉字（精力 / 睡眠债），自然宽会让每行数值起点都不一样，看着像三行随手写的 |

**验收只能量，不能看**：`tools/inspect_probe.gd` 把 **43 张牌 + 40 张工单 + 6 个状态 +
6 个指标**逐个摆一遍，量宽度、是否出屏、最深子节点是否溢出面板（横竖两个方向都量）。
抽查必然漏掉最长的那一条——它只在玩家悬停到那一条时才炸。
实测 `cards=42 orders=40 status=6 vital=6 max_h=377 limit=557 bad=0`。


### 角色立绘：一张「档案照」，不是站在暗处的立绘

5 位宿主 × 4 个状态 = 20 张，从 `assets/chars_src/`（1024×1536 原图，不进包）
烘成 `assets/chars/` 的 432×576（显示 216×288）。

**为什么是照片，不是立绘。** 简报/结算/结局这三个场合里，宿主**并不在场**——你坐在值班室，
看的是他的记录。所以该出现的是一张照片（贴着一张 1px 边的相框、下面一行状态标注），
不是一个人站在渐隐背景上。这个判断顺手解决了一个技术问题：不用处理"人物站在半透明背景上"
的合成感，也不用为每个状态准备一个姿势。

| 决定 | 理由 |
|---|---|
| 显示 **216×288**（不是 168×224） | 168 宽时脸只有约 50px，四个表情**肉眼完全分不出**（见下） |
| 四态 =**姿态差**，不是微表情差 | "疲惫"不是"眼睑低垂 2px"，是**低头、转开、闭眼、塌肩**。50px 的脸承载不了前者 |
| 每个宿主先出 1 张「平静」，再用它 image-to-image 出另外三张 | 四张必须是同一张脸。文生图各出一张，四张就是四个人 |
| 烘焙参数与卡牌**不同** | 亮部更亮（卡牌 `#B6CACC` → 立绘 `#CBD8D6`）、**不做**提亮暗部、颗粒更细、横向几乎不压暗。理由写在 `tools/char_art.gd` 每个常量上方 |
| 取景**自动**，不写死坐标 | 五张原图人物位置各不相同，固定窗口会分别切掉头顶、右肩、下巴 |

**表情的分工（谁在什么时候出现）**：

| 场合 | 表情 | 为什么 |
|---|---|---|
| 简报 | 平静 | 还没交手。这时候给一张疲惫的脸是倒因为果 |
| 结算 A/S | 释然 | 唯一真正带信息的一张：先看见这一班把那具身体弄成了什么样，再去看分数 |
| 结算 B | 平静 | |
| 结算 C | 疲惫 | 只有出问题的班次才给——经常出现就不稀奇了 |
| 事故 | 警觉 | 这张脸不是评价，是反应 |
| 结局 | 释然（真结局）/ 平静 | |

**验收只能按真实尺寸看。** `tools/char_sheet.gd` 把 20 张按**显示尺寸 216×288** 排，
**一行 = 一个宿主的四个表情**——这样"是不是同一个人"和"四张够不够分辨"两个问题
都能横向扫一眼答完。第一版按 168×224 排出来，四张里只有歪头的"释然"能认出来：
另外三张在大图上明明不一样，缩到真实尺寸就只剩几个像素的眼睑阴影。
这个结论直接改了显示尺寸，不是改图。

**接线靠探针验，不靠看**：`tools/char_probe.gd` 量照片的实际尺寸（`TextureRect` 用
`STRETCH_SCALE`，父容器多给几个像素脸就被纵向拉伸，3% 的拉伸静态图看不出来）、
整块模态是否出窗、正文列还剩多宽、评级→表情的映射、以及**逐章换人**（路径是
`host%d` 拼的，下标写错会让第五章显示第一章的人，而第一章永远是对的）。
实测 `CHAR_PROBE OK bad=0`，正文列 556–560px。

### 背景：它只从缝隙里露出 12%

打开游戏你看到的是**一整屏面板**：16px 外边距、12px 面板间隙、外加三栏之间两条竖缝。
把 `_shots/02_shift.png` 的像素按颜色归类，能归到 `Kit.BG0` 纯色底的只有约 **12%**，
而且是被切成一格一格的细条。

这个数字决定了背景该怎么做，也提前否掉了两种做法：

| 想做的 | 为什么不行 |
|---|---|
| 画一张"看得过去的护士站"，铺满全屏 | 图里任何小物件（纸片、杯子、笔筒）落在 12px 的缝里都会被切成碎片，读成"脏"。**要的是大块明暗，不是场景** |
| 干脆不做，反正看不见 | 12% 不是 0。现在这一版接上去以后，界面从"一堆色块浮在黑上"变成了"面板浮在暗房间里"，差别一眼可见 |

**第一稿把目标定反了，值得记一笔。** 当时的推理是"背景必须比面板暗，否则缝隙会亮成
发光网格"，于是 gamma 1.35 / gain 0.42 把中位数压到 0.012——烘出来是一片纯黑，
接上去和原来的 `ColorRect` **没有任何区别**，等于白做。原因是面板本身已经很暗了
（`BG1` 的 luma 只有 0.060），比它更暗只剩黑。正确的目标是**比底色亮、比最亮的面板暗**：

| 区域 | 目标值的来源 | 实际（`bg_probe`） | 界面上的角色 |
|---|---|---|---|
| 四边 | 接 `BG0`(#03080A, luma 0.028) | `edge` 0.036 | 16px 外边距，从边缘消失 |
| 中心 | 在 `BG1`(0.060) 与 `BG2`(0.100) 之间 | `center` 0.080 | 缝隙里透出"有光" |
| 最亮 | < 0.30，一个白像素都不要 | `max` 0.255，>0.30 占 **0%** | 原图灯管过曝到 0.959，不压住就是贴了张照片 |

**取景是第二个坑。** 这张图最亮的地方（白色台面 + 一张纸）正好落在画面 0.56 的高度，
而界面那条 18px 的横缝在第 470–488 行（0.573）。两者几乎重合，接上去以后横缝里就嵌进
一条切碎的台面边缘。`tools/bg_art.gd` 的 `ZOOM=1.15` + `ANCHOR_Y=0.44` 把取景窗放大
并上移，台面落到 0.65，被手牌面板整个盖住——露出来的是台面前方的地面，顶部留着荧光灯。
**这两件事必须同时改**：只改 zoom 台面还在缝里，只改 anchor 灯管就跑出去了。

**水印。** 出图端在右下角烤死「AI生成 WORKBUDDY」，prompt 里写 `no watermark` 没用。
卡牌那批是靠居中裁切顺手削掉的（运气），背景几乎不裁，一定留下来——而界面右下角
216×410 那一块正是**没有面板遮挡**的可见背景区。两道防线：`strip_mark()` 在原图上
克隆覆盖，`ZOOM` 的取景本身再裁一次。实测第二道就够了，第一道留着当保险。

**产物是 WebP，全项目唯一一张有损。** 大面积缓变暗部 + 全图颗粒，PNG 压不动：
1920×1230 实测 **2528 KB**，WebP q=0.92 是 **156 KB**，2 倍放大下看不出区别。
三张背景因此从 7.5 MB 降到 0.5 MB。图标/卡牌/立绘不能这么干——它们是 24–264px 的小图，
色带会直接糊在 1px 描边上。

**验收靠 `tools/bg_probe.gd`，不靠看。** 它打一行 `BG_PROBE STATS ...`，
`tests/test_godot_bg.py` 解析这行做断言（中心亮度区间、四边收敛、无白块、
水印区最大亮度 < 0.10、产物尺寸不陈旧、两张 ID 清单一致、cover 不是 stretch、
背景不吃鼠标、缺图回退纯色）。这件事必须自动化，因为**坏的方式全是"看着还行"**：
太亮只是缝隙有点花，太暗就是没做，接反了只是窗口拖成 4:3 时房间变扁。

**接上背景之后顺手调了模态遮罩**：`dim` 从 0.74 降到 0.66。在这之前底下是纯黑，
0.74 和 0.85 看起来一模一样；有了背景之后，遮罩浓度变成了"背景可见度"的旋钮——
0.74 时面板外那圈房间几乎看不见（背景 luma 0.08 × 0.26 只剩 0.02），模态屏还是
"一块板浮在黑上"。**一个只有在下游资产存在之后才有意义的参数，不可能提前调对。**

### 背景续：走廊、病房、章节过场

§四 做完护理站后，`bg_corridor_night`、`bg_ward` 曾是"暂缓"——没有画面可接。这版补上了落点：
**新建章节过场界面**，两张图分别挂在过场、结局的压暗底上。

**先看一个被忽略的事实：modal 屏只露顶部一条窄带。** 过场与结局都是居中模态弹窗，画面中心被遮住，
背景只在"顶栏上方窄带 + 左右薄边 + 底部薄带"里透出来。护理站能成是因为它的灯在**顶部**；
走廊的灭点灯、病房的窗本来在**中心**，直接烘出来在弹窗背后完全看不见，整张退化成均匀黑。
解法不是重出，是**逐图取景把亮部推到顶部窄带**：`bg_art.gd` 新增 `CROP` 覆盖（走廊 zoom 1.60 /
anchor 0.64、病房 zoom 1.60 / anchor 0.57，护理站沿用 1.15 / 0.44）。这反过来约束了出图——
**亮部必须安排在画面顶部 1/3**，否则再好的图在界面里也读不到。病房那张一开始把窗做成 ~16% 灰，
经暗角 + 0.66 遮罩掉到 ~8% 灰、看不见；重出把窗提到 ~55% 灰才透得出来。

**过场界面（`_ov_chapter_intro`）刻意不放宿主档案照**——照片是"看记录"的语义（属于简报），
过场是"走在走廊上"，该是空旷的；放照片会模糊两屏分工，也浪费走廊这张图。`engine.advance()`
跨章时把新章 dict 放进返回值，`main_ui._next_shift` 写入 `game.pending_chapter_intro`，
`_refresh_overlay` 据此弹过场，autoplay 在循环头部 dismiss 它（必须放在 `phase` 判断之前）。

**验收**：三张图 `bg_probe` 全 `OK`；`tools/intro_probe.gd` 确定性验证 advance 跨章 / 终章直接通关 /
三分支 `scene_for` 指向正确；`tests/test_godot_bg.py` 13 例（三张亮度曲线逐张断言 + 过场接线 +
autoplay 端到端 25 班 + 静态结构），`python tests/test_godot_bg.py` 全绿。

### 结局界面补全（让 25 班有回响）
原本 `_ov_ending` 只显示一行固定文案 + S/A/B/C 成绩单，而 `data.gd` 里写好的
**5 封宿主回信（`LETTERS`）/ 4 种结局变体（`ENDINGS`）/ 真结局「交班」（`TRUE_ENDING`）** 完全没接到界面。
玩家熬完 25 班看不到任何情绪回响，是「没玩下去的劲」的主因。

改法（`ui/main_ui.gd`）：
- `_ov_ending` 改为**宽面板 + 滚动容器**，依次展示：结局类型 chip（真结局·交班 / 结局·<变体名>）、
  结局正文（真结局用 `TRUE_ENDING`，否则用 `_ending_variant()` 选出的 `ENDINGS` 变体）、评级汇总、
  再逐章列出 5 封宿主回信（宿主 chip + `年纪·职业` + 信正文）。
- 新增 `_ending_variant()` 按整场表现从 `ENDINGS` 挑变体：**事故 ≥4 → 透支；误导 ≥3 → 被误导；
  平均信任 ≥62 → 和解；否则 → 开始**。真结局仍由 `engine.true_ending()`（事故≤2 / 误导≤2 / 每章信任≥60）决定。
- 取数全走 `E.D.*`（引擎单例下的 data 模块），避免误用未声明的 `D`。

**验收**：`tools/ending_probe.gd` 独立实例化 `main_ui`、把 `game` 推到通关，验证
① 普通通关与强制真结局门槛两条路径都不崩、且 `letter_blocks=5`（五封信全到）；
② `_ending_variant` 四种分支分别选中 和解/透支/被误导/开始。`autoplay` 与 13 例测试套件全绿。

### 内容扩容：每章 4 班 → 5 班（20 班 → 25 班）

第一轮扩容把每章从 3 班加到 4 班后，体量到 **20 班 / 55 单**，但暴露出两个「薄」的地方：
**第 4 班的抉择在复用第 1 班**（每章只有 2 个抉择，按班序取模），以及**每章缺一个真正的收尾班**
（第 4 班原本写的就是「收束/维持」，再往后就没有落点了）。

这一轮补的是这两处，仍然**零新增美术**：

- **每章加第 5 班**，主题是「这一章真的过去了」：
  `1.5 第一次准时下班` / `2.5 冰箱上的体检单` / `3.5 她想学游泳` / `4.5 待产包` / `5.5 多配了一把钥匙`。
  它们不是加量，而是把前四班的伏笔收到一个具体动作上（准点走一次、把单子贴出来、买合身的泳衣、
  收好待产包、把钥匙交出去）。
- **新增 10 个工单**（每章 2 个，65 单）：`o_offwork`（长时间空腹低血糖样）、`o_boss_ping`（报复性睡前拖延）、
  `o_bp_home`（家庭血压怎么量才算数）、`o_salt_hidden`（隐形盐）、`o_swim`（身体意象回避）、
  `o_teeth`（催吐的牙科线索）、`o_bag`（分娩恐惧）、`o_gdm_diet`（糖筛异常后断碳水）、
  `o_key`（拒绝帮助）、`o_night_bp`（夜间体位性低血压）。
- **抉择 10 条 → 25 条**，每章 5 条、与 5 班一一对应（`DILEMMAS[ch][shift]` 不再取模复用）。
  新抉择都放在「这一班已经发生的事」上：说出口后要不要保密、指标好看后想停药、把钥匙交出去还是装摄像头。
- `SHIFT_ENV` 每章补到 5 项（沿用现有 4 种环境，不新增环境类型）。

**验证**：Python 自走 30 种子全通关（`incidents=0`）· 双端 parity 8 种子逐行一致（评级串 25 字符）·
`pair_audit` 0 死局 0 矛盾 · Godot 集成测试全绿。单周目估算 **4–5 小时**。

## 五、为什么能做到"逐位一致"

三处关键决定，缺一不可：

1. **共用确定性 RNG**：Python 的 MT19937 与 Godot 的 PCG 无法对齐，所以两端都改用
   同一套 32 位 xorshift32（`engine.py` 的 `Rng` / `engine.gd` 的 `Rng`），
   `randrange` / `shuffle` 也按同样顺序消耗随机数。
2. **整数取整，不用浮点**：效果倍率从 `mult = 0.5 / -0.6 / 1.15` 改成整数有理数
   （`1`、`1/2`、`-3/5`、`23/20`），再用 `round_div`（`.5` 远离零）求值。
   Python 的 `round` 是银行家舍入、GDScript 的 `round` 是远离零，混用会稳定地差 1。
3. **轨迹只记录整数与 id**：`P|章|班|刻|牌|单|六指标`、`D|章|班|选项|六指标`、
   `S|章|班|分数|评级`、`R|章|班`，避开浮点与本地化格式差异。

```bat
cd 08_可玩原型
python tools/parity_check.py               REM 默认 8 个种子
python tools/parity_check.py --seeds 20    REM 前 20 个种子
```

实测（8 个种子，每个约 90 行轨迹）：全部 `OK`，无一行差异。这条验证也在单元测试里：
`tests/test_godot_parity.py`（找不到 Godot 时自动 skip）。

## 六、踩过的坑（已解决，留作备忘）

| 现象 | 原因 | 解法 |
|---|---|---|
| `Trying to assign to a read-only array` | `Array(const_arr)` 得到的是只读视图 | 用 `.duplicate()` 取可变副本 |
| `Parse Error: Identifier "c" not declared` | GDScript 的 for 循环变量只在循环内可见 | 循环外用中间变量承接 |
| 双端指标稳定差 1 | 浮点倍率 + 两种 `round` 语义 | 整数有理数 + 统一 `round_div` |
| `data.gd` 报 `Reference` 不存在 | Godot 4 已把 `Reference` 改名 | 纯数据脚本不要 `extends` |
| `Cannot infer the type of "act"` | `:=` 推断不出无类型变量的返回值 | 显式写 `var act: Array = …` |
| chip 在 VBox 里被拉满整行 | `size_flags_horizontal` 默认 FILL | 显式 `SIZE_SHRINK_BEGIN` |
| 满屏方块字 | 默认字体无 CJK | 内置 Noto Sans SC（`load_dynamic_font` 运行时读入） |
| 调用 `get_font_name()` 后 Godot 卡死无输出 | 4.7.2 在**可变字体**上取家族名会挂 | 别在 GDScript 里查身份；改由 Python 解析 TTF `name` 表 |
| 退出时报 `ObjectDB instances were leaked` | `AudioServer` 挂着播放实例；`ui_kit.gd` 的静态 `FontFile`/`Theme` 缓存也没释放 | `Sfx.dispose()` 停播断流清缓存 + `Kit.release()` 清静态缓存，都在 `_exit_tree()` 调 |
| 脚本报 `Parse Error` 但看不出问题 | 项目把「从 Variant 推断类型」当错误 | 显式写类型：`var x: String = dict.get(...)` |
| 窗口版启动后**挂住不退出**、无报错 | 主场景脚本解析失败 → 没有场景 → 空跑不退出 | 先看输出里的 `Failed to load script`，再用 `--headless --path . --script main.gd` 快速验语法 |
| 存档读回来刻数变浮点 | JSON 把 `int` 读成 `float` | 用 `var_to_str / str_to_var`，不用 JSON |
| 泄漏**偶发**（4 次里 1 次），只在有声音时会漏 | 音频线程是独立线程，`stop()` 后 playback 要等**下一轮混音**才被释放，立刻 `quit()` 就漏 | `_quit_clean()`：`dispose()` 停播断流 + 等两帧再退。两条退出路径（巡演 / 截图）共用 |
| 无头跑 `hand_sheet --layout-only` 稳定漏 1 个 `AudioStreamWAV` + 1 个 `AudioStreamPlaybackWAV` | dummy 驱动下混音轮次不保证在退出前跑完，等帧也不管用（只 stop 不断流） | 无头时根本不建播放实例：`sfx.enabled = … and DisplayServer.get_name() != "headless"`。反正无头没有声卡 |
| 一排卡牌里有的高有的矮 | `custom_minimum_size` 只是**下限**，内容更高时 `PanelContainer` 自己长高 | 让工具报出真实高度（`hand_sheet.gd -- --layout-only`），再改排布让最坏情况也放得下 |
| 检视浮层第一张牌高 **1610px**，之后每张牌都跟着这么高 | 内容刚重建时 `get_combined_minimum_size()` 还是**脏的**（一帧后才是 376）；而 `Control.size` 只会被 minimum **往上顶**、不会自己缩回去 | 等一帧让 minimum 重算，再 `reset_size()`。手动 `size = get_combined_minimum_size()` 一次就把脏值锁死了 |
| 探针脚本传了 `--shot`，结果跑出一整套 SHOT 截图 | `main_ui.gd` 的 `_ready` 也读 `--shot`，抢在脚本前把游戏跑了一遍并 quit | 探针用自己的参数名（`--save`）。和主程序共用的命令行参数要当成保留字对待 |
| 检视卡在工单之间**一张一个宽度**（300–356px） | 标签行用 `HBoxContainer`，它的最小宽被 4 个标签 + 器官名撑爆，`custom_minimum_size` 只是下限 | 宽度钉死 `INSPECT_W + 2`，标签行改 `HFlowContainer`（到边换行）。探针现在横竖两个方向都量溢出 |
| 探针量到的是「已通关」的界面 | 窗口模式下 `_ready` 会自动读档（存档里是上一次巡演打通的战役），量到的根本不是干净班次 | 探针开头先 `Save.erase()`，不依赖命令行参数；窗口复核时再加 `--fresh` |
| 插画对照表**少了整整一行、右边两列也没了**，而 `save_png` 返回 `OK` | 主窗口 1280×820 是硬的（`root.size = ...` 改不动它），超出部分直接不画 | 分页（4 列 × 5 行 = 20 张/页），并把"页宽高必须装进窗口"写成断言 |
| 立绘在**168 宽**下四张表情几乎一样 | 168 时脸只有 50px，表情差落在几个像素上 | 不是改图，是改尺寸：显示放大到 216×288（脸约 97px），同时把四态从"微表情"改成"姿态差" |
| 立绘固定裁切窗换来 "头顶被切 / 偏左 / 下巴出框" | 五张原图分别生成，人物在画框里的位置和大小都不同 | 按**脸部亮度重心**定窗口位置，再用"亮区最高行"兜住头发（`mass_top`）。手工调五个坐标下次重出就作废 |
| 加了立绘后结算屏正文只剩 **346px** | 面板最小宽度还是无立绘时的 640，而结算的正文短、撑不开面板 | 有立绘时 `MODAL_W = 850`（22+216+22+560+30），把"正文列要保住 560"写进常量名旁边的注释和测试 |
| 探针测结局，量到的却是上一屏的「警觉」 | `_refresh_overlay` 只在 `campaign.cleared` 时给 `"ending"`；只改 `phase` 它算出 `want=""`，而 `""` 又正好等于 `_overlay_sig` 的初值 → 提前 return，浮层根本没重建 | 探针要把战役真标成通关。**"空字符串"当哨兵值时，它和"未初始化"是同一件事**，这类提前返回只能靠交叉验证发现 |
| `art_src/README.md` 写着「打包脚本已排除 art_src」，但项目里没有 `export_presets.cfg` | 文档写了一句代码没做的事——比不写更危险 | 如实改成"设计意图，尚未实现"，并加 `test_export_would_not_ship_source_art`：将来加了导出配置却没排除就会失败 |
| 烘焙脚本跑 **4 分钟不出结果**，`time` 显示进程还活着 | 脚本有解析错误时 Godot **不退出**，只在 stderr 打几行 `Parse Error`；而我用 `\| tail` 接输出，`tail` 要等 EOF 才吐，于是"卡住"和"报错"看起来一模一样 | 排查这类"无声挂起"先 `\| head` 不要 `\| tail`。修好后同一张图 **2.7 秒**烘完——之前那 4 分钟一次都没真正跑起来 |
| 背景第一稿烘完是**一片纯黑**，接进界面和原来看不出区别 | 把"背景必须比面板暗"当成目标，gamma 1.35 把中位数压到 0.012；而面板本身 luma 已经只有 0.060，比它暗就只剩黑 | 目标改成"比底色亮、比 `BG2` 暗"。这类错误纯看图看不出来——**看图只会觉得"背景没生效"，量了才知道是量纲反了** |
| `Nonexistent function 'scene_for' in base 'GDScript'`，可那个函数明明写着 | 上一行 `var p := DIR + id + e` 里的 `e` 来自无类型 `Array`，是 Variant → 推断失败 → **整个文件编译失败** → `preload` 拿到一个空脚本 | 报"函数不存在"时先往上翻，真错在类型标注。而且这不致命：`--shot` 照样打印 `err=0`，只是界面静默降级 |
| 用子进程解析 Godot 探针输出做断言，比对永远失败 | Godot 打印布尔是**小写** `true`/`false`（与 Python `True`/`False` 不同）；直接 `== "True"` 永远不等 | 比对前 `.lower()`，或写死 `"true"` / 用 `== "true"` |
| 给过场 / 结局做的背景在弹窗背后"整张看不见" | 居中模态遮住画面**中心**，背景只在顶栏上方窄带 + 左右薄边 + 底部薄带透出；亮部落在中心就全被遮住 | 出图时**亮部必须安排在画面顶部 1/3**，再用逐图 `CROP` 取景把亮部推到顶部窄带（见 §四 背景续）。这条反过来约束了出图，不是事后救图 |
| 第 1 章第 2 班「心慌的夜」的红旗单（心慌+冷汗+左臂沉）**无法过关**：点任何手牌都直接判事故、本班即结束 | 红旗单只认 `refer`（转诊）牌，非转诊牌一律 `grade=incident` 并 `phase="over"`；而 `STARTER_DECK` 里**一张转诊牌都没有**，前两章奖励也不给 → 玩家永远凑不出正解（死锁）。autoplay 能通关是因为它"答不了红旗就跳过"，把红旗留成未处理 | `start_shift` 抽牌后调 `_ensure_redflag_refer`：本班若含 N 张红旗，保证手牌里至少 N 张 `refer` 牌，缺的用该红旗 `best[0]`（均为 `c_er`/`c_urgent`/`c_clinic`）补进手牌。**双引擎（`engine.gd` + `engine.py`）逐字同步**，`tools/parity_check.py` 8 种子逐行一致 |
| **第 3 班照样卡死**（修好第 2 班后复现）：红旗到场时手里仍没有转诊牌 | 红旗分两批进场：开局池那批已由 `start_shift` 兜底，但 `EMERGENCY = {1:o_heart,2:o_chest2,3:o_faint,4:o_headache,5:o_fall}` 是 `maybe_emergency()` 在**处理掉两张单之后中途插入**的，`start_shift` 那一刻它挂在 `self.emergency` 里、还不在 `orders` 中，保底看不到它 → 5 章的 3 班全都是死锁 | ① `maybe_emergency()` 插入突发单后立刻再调一次 `_ensure_redflag_refer`；② `restore()` 末尾也调一次（旧档读回来会自愈，不必重开）；③ `play_card` 拦住「既非红旗、又不是该单 best/good 的转诊牌」，防止把 `c_er` 浪费在感冒单上；④ 选牌器兜底跳过同类无效牌，否则引擎拒牌而模拟器继续选 → 空转（`plays` 从 66 涨到 5977 就是这个症状） |
| **坑：把 `s=="refer"` 一律当"只能对红旗用"** | `refer` 是 6 张牌（`c_er`/`c_urgent`/`c_clinic`/`c_special`/`c_accompany`/`c_followup`），其中 `c_clinic 预约门诊` 在 **19 个普通单**里是 `best`/`good`，`c_followup`/`c_special`/`c_accompany` 也各有正解 | 判断条件必须写成「非红旗 **且** 不在该单 `best`/`good` 里」才拒；一刀切会让合法牌被拒、自动对局空转。`tools/refer_probe.gd` 回归这三条（突发补牌 / 旧档自愈 / 补出的牌真能打） |
| **「图片一张都没有、顶栏没有音效栏、只有一处有声音」**——三个现象同时出现 | 不是 Godot 版坏了，而是**双击的入口指错了**：`启动游戏.bat` 跑的是 Python 残本 `game.py`（没接美术管线、uv 的 Python 没有 PIL），而美术/顶栏音效栏/全套音效都只在 Godot 版里 | 两个玩家入口都改成 `call launch_godot.bat`，**入口收敛成唯一真源**；启动器加 `--dry-run` 自检（打印解析出的 exe/工程/`project.godot`）。`tests/` 的 `TestEntryConsistency` 守住三条：入口必须全 ASCII、必须委托同一个启动器、可执行行里不许再出现 `game.py` |
| **「重打本班」能免费洗白事故**，真结局门槛（`total_incidents <= 2`）形同虚设 | 事故只在 `advance()` 结算时累加进 `campaign.total_incidents`，而 `_retry_shift()` 直接 `load_shift()` 会把 `self.incidents` 清零 → 重打一次就抹掉一次事故 | `_retry_shift()` 里先把 `game.incidents` 记进整场账本再重开本班。`--chaos` 巡演会故意制造事故来守这条（`CHAOS_OK ... incidents=3`） |
| 启动器明明跑成功，却打印 `Godot exited with code 1` | `set "RC=%ERRORLEVEL%"` 紧跟 `if (... ) else ( ... )` 括号块时取值不可靠；而且末尾无条件 `pause` 在非交互环境里会干扰判断 | 参数改成先拼进 `ARGS` 变量、单条命令执行后再取 `%ERRORLEVEL%`；只在**失败**时才 `pause` 并打印末 40 行日志 |
| 扩容到 25 班后，结局标题仍是「十五个班次之后」 | 标题是 `Kit.serif_lbl("十五个班次之后", …)` 直接写死的字符串，班次数从来没进过它 | 改成 `"%s个班次之后" % _cn_num(_total_shifts())`：班次总数从 `E.D.CHAPTERS` 求和，`_cn_num` 转中文数字（护住散文语感）。截图 `_shots/06_ending.png` 现在显示「二十五个班次之后」 |
| 混沌试玩挂死不退出 | `--chaos` 只是 `--autoplay` 的修饰符，单独传它不会进巡演分支 → 无头下开一局空转 | 必须 `-- --autoplay --chaos --seed=N`。`CHAOS_OK` 里 `shifts=25` 才算跑完 |
| **「有的工单和对应的签没关系」——出一张不对症的牌也显示「治愈」叙事** | 引擎把所有"不在 best/good/bad"的非偏方牌默认判 `good`（半效果 + 正向 `gt` 文案），于是"热敷后颈"治腿抽筋也被说成"肌肉松下来了"，玩家感觉乱出都对 | 新增 `off` 档：`play_card` 里"三档都没有"的牌判 `off`（效果为 0、不编造有效叙事、UI 显示"这张好像没对症"）。`engine.gd`/`engine.py`/`ui_kit.gd`/`main_ui.gd` 四端同步，`Kit.GRADES` 加 `["没对上", GREY]` |
| **最佳处置牌永远晚一班才能拿到** | 奖励牌在班末结算才并入 `deck`，第 1 班（颈肩/反酸/眼干/感冒）玩家手里只有开局通用牌，而 `c_diet`/`c_rice`/`c_cool` 等最佳牌到 1.2 才发 → 当班正解全不可得 | `load_shift` 接管当班 `shift_def.reward`（"接班前先领签"），当班开局即可用；并重排 25 班奖励，使每班 pool 的工单至少 1–2 张 best 在手。新增 `tools/pair_audit.py` 守"映射自相矛盾 / 正解不可得死局 / 正解只剩 1 张零容错"三条 |
| **`STARTER_DECK` 缺基础自我照护牌** | 失眠/关屏幕类牌只在奖励里，第一章睡眠单正解迟发 | 开局 7 张扩到 9 张（加 `c_screen 睡前一小时关屏幕`、`c_breathe 做四分钟呼吸练习`） |
| **第 3 章「瘦下去」缺一张"吃够"牌** | `o_skipmeal`/`o_amenorrhea`/`o_binge`/`o_anemia` 都是"要恢复规律进食"，但原有 `c_rice 清淡饮食，少量多餐` 恰恰是反向误导 | 新增 `c_eat 三餐都要吃，别算热量`（home，eff 提精力/代谢/信任），进 3.1 奖励；上述四单的 `best` 改挂 `c_eat` |


## 七、下一步

1. **美术**：见上层目录 `11_美术风格指南与资产清单.md`——色板/字体/网格/卡牌结构/动效时长/资产清单/外包边界都在里面，
   替换入口是 `ui/ui_kit.gd`（样式集中在这一个文件）。
   已完成 **色板统一**（指标条改为按危险程度上色，两端同阈值）、**字体内置**（Noto Sans SC + OFL）、
   **图标 24 个（全部做完）**、**卡牌插画 43/43（全部做完）**（判读记录与淘汰理由见 `12_资产生产手册.md` §六、§七）、
   **角色立绘 20/20（5 宿主 × 4 状态，全部做完）**（见 §八）。
   背景 **3/3 全部做完**：`bg_nurse_station`（护理站，接常规值班）、`bg_corridor_night`（走廊夜景，接章节过场）、
   `bg_ward`（病房，接结局）——均为全屏 1920×1230 WebP q=0.92（见 §四 背景 / 背景续）。
   全套美术至此**全部落地**（色板 / 字体 / 图标 24 / 卡牌插画 43 / 立绘 20 / 背景 3）。
   仅剩 `ui_paper_texture`、`ui_grain` 两张贴图已在 `11_美术风格指南与资产清单.md` §D 论证掉（深色面板上 5% 噪点逐像素只变 3 个色阶，
   且背景已带 GRAIN；做了是库存、会重犯立绘第一版的错），不再生产。
2. **动效**：现在仍是「整屏重画」。要加 Tween 需要把 `_refresh_*` 改成差量更新，
   引擎不用改（一次性事件字段已就绪，音效已经按这套接完了）。
3. **存档扩展**：多槽位 + 云存档（GodotSteam RemoteStorage）；改字段时记得升 `SAVE_VERSION`。
4. **接 `GodotSteam`**：成就（25 班评级 / 真结局）、云存档、统计。
5. **正式内容**：`data.gd` 已由 `content_full.py` 单源生成，扩内容不用碰代码。
   当前规模 **5 章 × 5 班 = 25 班 / 65 个工单 / 43 张牌**，单周目约 **4–5 小时**。
   扩容只需在 `content_full.py` 里加 `shift` / `order`，再 `python gen_data_gd.py`：
   - 引擎已按 `len(shifts)` 自适应，**不再假设每章 3 班**（`EMERGENCY` 落在章内最后一班）；
   - `SHIFT_ENV` 每章必须给够班次数的环境；`DILEMMAS` 按班序取模，班次多于抉择数会复用；
   - 加完必须跑 `python tools/pair_audit.py`（配对 / 可获性 / 死局）与
     `python tools/parity_check.py`（双端逐行一致）。

| 导出的 exe 里**立绘/图标/字体全没了**，而 `--autoplay` 一路绿灯 | `.png/.webp/.svg/.ttf` 都是可导入扩展名，包里只剩 `.ctex/.fontdata`；美术模块缺图就静默降级，正好把这件事盖住 | 加 `--selfcheck` 闸门（立绘 20 / 背景 3 / 图标全量 / 字体必须是内置 ttf / `user://` 可写），`build_win.bat` 里跑不过就判失败 |
| 在 exe 里 `FileAccess.file_exists("res://x.svg")` 一律 false，可文件确实在工程里 | 资源被导入后会 remap，包内只有导入产物，**原始路径不存在**；而 `ResourceLoader.exists()` 认 remap | 统一入口 `Kit.asset_exists / Kit.texture_at`：先 `load()`，不行再现读。图标必须拿源码（要按尺寸重画线宽），改由 `prepare_export_assets.py` 生成 `.raw` 副本，靠 `include_filter="*.raw"` 带走 |
| 用 `d.count("res://assets/chars/host3_calm.png")` 判断资源在不在包里 | 数到 1 就以为在——其实那 1 次是 `.import` 文件里的 `source_file=` 字段。包内条目名是**相对路径**，也不带 `res://` | 别在二进制里数名字。要清单就 `--packlist`（引擎自己遍历 `res://`），要结论就 `--selfcheck` |
| 手写的 PCK 解析器读出 `count=0` / 0 个文件 | 4.7 把文件名压进 GST2 表，包头 112 字节后面就是压缩段，按老格式硬解只会得到"空包"的假象 | 删掉解析器，改成运行时 `--packlist`。**外部工具读不懂的格式，就别拿它当发布闸门** |
| 给 `assets/` 放 `.gdignore` 想"绕开导入管线"，结果包体 156 KB | `.gdignore` 的语义是"这个目录对编辑器不存在"，导出走的是编辑器的文件系统索引，于是连 `include_filter` 都救不回来 | 要"不导入但仍打包"，只能是**扩展名不是资源** + `include_filter`。`.gdignore` 是"藏起来"，不是"跳过导入" |
| 桌面目录下的 exe 百分百 `save=false`，拷到 `%TEMP%` 就正常 | 本机策略禁止**从桌面树启动的**二进制写盘（同一 exe、同一路径、不同位置，结果相反） | 闸门先 `copy` 到 `%TEMP%\rtbzs_verify\` 再自检；否则会把环境限制当成代码 bug 查一晚上 |
| `build_win.bat` 加了几行中文 `rem` 注释后直接崩 | cmd 用系统 ANSI 代码页解析 `.bat`，UTF-8 中文被拆错，行首的 `rem` 被吃掉，注释当成命令执行 | `.bat` 里**只能写 ASCII**。注释也写英文——这条已经写在文件头，还是又犯了一次 |
| `SELFCHECK OK` 打了整整一轮，可 **标题字体每台机器都不一样** | `EMBEDDED_SERIF` 指向 `fonts/NotoSerifSC-VF.ttf`，而这个文件**从来没进过仓库**——`serif()` 每次都静默回退 SystemFont；自检只打印 `serif_system=true`，不参与判定，于是这件事一路绿灯到发行 | 补 `NotoSerifSC-subset.ttf`（1.0 MB），`make_font_subset.py` 改成**两个字族都裁**、且取两者可用字的交集；`serif_ok` 进最终判定。**闸门里"只打印不判定"的项，等于没有** |
| 25 个班次，巡演只弹了 19 个抉择，而 `AUTOPLAY_OK` 依然全绿 | `_autoplay` 里 `phase == "settle"` 判在 `pending_dilemma` **之前**：玩家解决最后一个工单时，`maybe_dilemma()` 同时挂上抉择并把 phase 置成 settle，于是 `_next_shift()` 直接把抉择冲掉。引擎侧（`--check`）是规规矩矩的 25 个，所以双端比对反而是绿的 | 循环顺序改成 `over → dilemma → settle`，与 `_refresh_overlay()` 对齐；并把 `dilemmas < _total_shifts()` 纳入 ok 判定。**指标不进判定，就等于没测** |
| 自检里图标全丢、卡面 0/43 也照样 `OK` | 两处都是"逐个检查、缺了就 append"，清单为空时循环一次都不转，`miss` 零条 | 加两条**数量判据**：图标清单为空直接判失败、`cards < CARD_MAP.size()` 直接失败。立绘宿主清单也收进 `CharArt.HOSTS`，不再在自检里另写 `range(1,6)` |
| 跑一次 `--autoplay` 就把玩家存档冲了 | 巡演每班自动存档，写的是 `slot1.sav` 同一个槽 | `Save` 增加 `_probe.sav` 假槽位，`--autoplay/--shot` 启动时切过去；想验证"读回真实存档"时才不会被自己上一次的巡演盖掉 |
| 1366×768 的笔记本选 1920×1080，窗口跑到屏幕外，「完成」按钮点不到 | `apply_display` 直接把 `RESOLUTIONS[idx]` 塞给窗口，没跟屏幕比过大小；居中用的还是整屏而不是可用区域，窗口会压到任务栏底下 | 用 `screen_get_usable_rect()`，`mini()` 夹到可用区域内再居中 |
| 巡演打出 `AUTOPLAY_OK cleared=false`，可实际上**已经通关了** | 那行打印的第一个占位符是 `str(ok)`，标签却写着 `cleared=`。闸门因为别的原因判失败时，会被读成「没通关」，排查方向直接跑偏 | 前缀用 `AUTOPLAY_OK/FAIL` 表示判定结果，`cleared=` 打真实值，两个维度分开 |
| 想把「抉择数」写成闸门，改成 `dilemmas == 班次数` 却开始误报 | 1 个工单的短班次常常在 clock 走到过半之前就打完了，本来就不该弹抉择——100 局实测有 17 个班次如此 | 判据换成「引擎已触发（`dilemma_fired`）但这一班一次都没走到 `_choose_option`」。**反向验证过**：把顺序改回 settle 优先，它准确报出 6 个班次 |
| 5 张偏方牌（`c_pill`/`c_detox`/`c_alkaline`/`c_herb`/`c_patch`）被 55 个工单列为 bad，却**永远抽不到** | 它们既不在 `STARTER_DECK`，也不在任何一班的 `reward` 里——「选错会被惩罚」的设计从第一版起就是空的，还没人发现 | 新增 `shift.gift` 字段：宿主在特定班次**强行带回**一张偏方，当班可用、赢了也甩不掉（`_shift_cards()` = reward + gift，双端都走这一个入口）。简报新增「带回」两行说明来源，`gen_data_gd.py` 增加**可达性自检**（任何不在 starter/reward/gift 里的牌直接判失败），`TestQuackReachability` 7 例钉死。60 局实测：通关率 60/60 不变，终局信任 82.5 → 75.4，C 评级 7% → 20% |
