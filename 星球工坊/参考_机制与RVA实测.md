# 参考 · 星球词条（PlanetForge）机制与本机实测

> 面向：这条线后续所有工作（写词条、解锁星球、做 cfg）。
> 数据来源：①参考实现 `NatsunXD/Gosporebrust`（main，v5-preview）与其 `GoPredator` 分支；
> ②两个发布包内的机器可读 `*-manifest.json`（在 `资料整理\其他种类mod\Gosporebrust V4\`）；
> ③**2026-10-01 本机实机只读取证**（`log信息\PlanetForge.probe.log/.bin/.idx`，build 1.8.46015.0）。

## 1. 三层机制（要做什么就改哪一层）

| 层 | 写什么 | 效果 | 风险 |
|---|---|---|---|
| **词条** | 全局战役修饰表：某星球行（`scope=0`）追加 **type=17 的 16 字节敌人标签**；每行最多 **5** 个 | 该星球的敌人模板（孢裂 / 掠食 / 喷气旅…），**可叠加** | 低：只影响任务词条 |
| **任务行** | campaign board 的 110×92 本地任务行：把别的星球的行拷过来、改星球 id | 让目标星球有任务列表 | 中：改的是共享表，参考作者在 v2.4 里停用了它 |
| **星球状态** | 星球动态记录：阵营 `+36`（1→2 终结族）、access state `+28`、available `+48`（0→1） | **"把隐藏/进不去的星球调出来"** | 高：参考作者自己标 `runtime_verified=false`，且明说"不解除战役可攻打状态" |

参考作者在 TECHNICAL.md 里承认：证据只覆盖**修饰表与任务预览读取路径**，"不证明游戏最终一定选择孢裂敌人池"。
⇒ **"写入 tag 之后游戏真的换敌人池"这一条，两边都还没被证明过，必须我们自己实机验。**

## 2. 参考实现的常量 vs 本机实测

| 结构 | 参考常量（RVA） | 本机 2026-10-01 实测 | 结论 |
|---|---|---|---|
| tag 哈希表（32×u32） | `0x21E18E0` | 该地址起 **前 64 字节是 8 个模块内指针**（每 8 字节一个，`0x00007FFC…`），**真正的 32 条哈希从 `+0x40` = `0x21E1920` 开始** | **参考常量已漂移**，我方按"在 RVA 附近 1 KiB 内挑最像哈希表的 128 字节窗口"动态定位 |
| 孢裂变种（定义 1244）的 tag 索引 | 旧文档说 **9** | 本机 hash `0xA3A3DB9F` 落在**真索引 10**（= v4 清单的 `resolved_tag_id=10`） | **必须运行时按哈希查表，绝不写死索引** |
| 修饰定义表（52B/记录，计数 `+53248`） | 指针 `0x347CD98` | 该 RVA 处是**一组指针**（实测两个：`0x2264F373C60`、`0x22654AD6380`）；第一个当时 `+53248` 读出来是 **0**（表尚未填充） | 指针位要"逐候选试 + 结构化判据（kind=40 且 category=13 的匹配数）"，不能只认第一个 |
| 全局修饰表（32×356） | 指针 `0x346D518` | 指针**正确**，表已分配但当时**整块全零** | RVA 有效；但**必须等战役数据下载完**再读 |
| campaign board（任务行/动态记录） | 指针 `0x347CEE8` | 指针**正确**，1.6 MB 读到但**整块全零** | 同上：探针在"刚进游戏"跑等于白跑 |
| 旧的全局表指针（45317 那版） | `0x2770628` | 该地址所在区域 `state=0x0`（未提交） | 只作历史参考 |

### 2.1 两次实机取证的结论（2026-10-01，v1 与 v2）

| 结构 | 实机结果 | 判定 |
|---|---|---|
| tag 哈希表 | 两次都是 **RVA+0x40**（`0x21E1920`），32 条全读到；孢裂 `0xA3A3DB9F` 在**真索引 10** | 参考常量已漂移；包内"自动找窗口"稳定复现 |
| campaign board | 指针正确：**286 个星球记录**、**40 条本地任务行**（当时选中星球 184）、active=184 | **可直接用** |
| 全局修饰表 | 指针解析到一块**正好 11,392 字节、全零**的堆内存 | **无法用内容验证**：要么此刻没有任何星球挂着词条，要么该 RVA 也漂移了 |
| 修饰定义表 | RVA 处是**一组指针**（实测 8 个）；逐个试全不匹配；再把模块镜像 ±2 MB 三个窗口扫了 **16 MB / 62,963 个候选指针**，也没找到 | **按指针找已经失败**，必须改成**按内容找**（v3 的堆内搜索） |

**星球表（286 条，faction = 阵营）**：faction 1 = 212 个、2 = 21 个、3 = 16 个、4 = 25 个；
`available == 1`（当前可攻打）共 **38 个**：7(f4) 70(f3) 79(f2) 90/92/93/95/99(f4) 100(f2) 114(f3) 140/143(f4)
157/158/159(f3) 178/180/181/182/184/186/187(f4) 199/200/201/205(f3) 215(f2) 224/225/228/231(f4)
253(f3) 259(f2) 261/262(f3) 268/269/270(f2)。
参考文档证实 **faction 2 = 终结族**（`terminid_faction = 2`，且 268 富源/269/270 都是 f2 且可攻打）；
`1` 应为超级地球（占 212 个），`3`/`4` 从规模看应是机器人 / 光能者，**待与星球名对齐后确认**。

**关键星球现状（faction / available）**：3 寡妇港 = f1 / **0**（进不去）、125 芬里尔III = f1 / **0**、
127 天使投资 = f1 / **0**、173 盖尔崔亚 = f1 / **0**；**268 富源 = f2 / 1**（可攻打）。
这与用户说的"3 是被调出来的隐藏星球、125 目前进不去"完全对上。

**星球名可以离线还原**（本轮新发现）：board 里存在带本地化键的星球描述记录，实测命中
**FENRIR III = `0xCF6E41C8`**、**GATRIA = `0xA54F836E`**，紧邻还有三组 32 位哈希与
`planet_type_sandy` / `planet_type_moor` 之类的生物群系字符串；而这些键就在本机的
`hd2data\current\English_translations.json` 里（`"3480109512": "FENRIR III"`、`"2773451630": "GATRIA"`）。
⇒ 取到"哪条记录里同时有星球 id 与这个键"之后，**不需要社区 API 就能生成完整 id↔名字表**。

**本机 game.dll 是打包过的**（16 段；第 1 段 `vsize=0x210FA93` 而 `rawsize=0x850800`；`SizeOfImage=0x4744000`），
所以这些常量**无法在磁盘上核对**，只能进程内验证——这就是取证包存在的理由。

## 3. 本机实测拿到的 tag 哈希（32 条，全部）

```
[ 0] 0x7CC6EE5A   [ 1] 0x41A4DF74   [ 2] 0xDF4CB4E5   [ 3] 0x5EF255B7
[ 4] 0xC323A525   [ 5] 0x23ECEBE0   [ 6] 0xA7ACB9EA   [ 7] 0x44FE54CD
[ 8] 0x39E2D413   [ 9] 0x89E4FC2A   [10] 0xA3A3DB9F   [11] 0x907204FE
[12] 0x9FD5943A   [13] 0xFBE995C2   [14] 0x87EE5692   [15] 0x0E7439B9
[16] 0x527691DD   [17] 0xC8044964   [18] 0x044BAAEA   [19] 0x46B522B8
[20] 0xAE2ED4E9   [21] 0x08766602   [22] 0xC02D8176   [23] 0x658544D8
[24] 0x194C725F   [25] 0xD4DB21D9   [26] 0xFECB6B78   [27] 0xE2136DAA
[28] 0x33FA1AB8   [29] 0x021B60B3   [30] 0xFD8B9706   [31] 0xBA586F51
```
索引 10 = **孢裂变种 Spore Burst**（参考 v4 清单 `resolved_tag_id=10` 与实机一致）。
这些哈希**不是**英文名的 djb2/FNV1a（19,240 组组合全不中，见 `build\_planetforge_hash_probe.py`），
**也不是**本地化键（拿 32 个值去查 `English_translations.json` 全不中）⇒ 谁是谁只能靠
"定义表里的 id↔tag_hash 对照 + 游戏内观察"来命名。

## 4. 探针 v1 的两个自身缺陷（已修）

1. **PE 可选头偏移写错**：`SizeOfImage`/`CheckSum` 应在 `e_lfanew+24+56` / `+64`，v1 写成了 `+56`/`+64`
   ⇒ 读出来是 `0x1000` ⇒ 兜底扫描的窗口被裁成 0 个（日志里 `PROBE_sweep_begin windows=0`）。
2. **探测时机太早**：v1 在加载后的**第一帧**就把数据导完，那时战役表还没填充（1.6 MB 全零）。
   v2 改成**等到数据就绪**（全局表有行 / active 星球非 0 / 任务行有效 > 0）再导，最长等约 4 分钟，
   期间每约 1 秒打一行 `PROBE_wait attempt=N …` 进度。

另外两个判据也修正了：tag 窗口的"指针高半字"识别（原先对 u32 又除了一次 65536，永远判不出来）、
定义表的判据从"连续 8 条"改成"**匹配计数 ≥3**"（定义表里不同 kind/category 的记录是混在一起的，
连续判据会把好表判死）。

### 4.1 v2 实机之后的新问题与 v3 的对策

v2 把"数据没就绪"解决掉了（星球表、任务行全拿到），但**定义表仍然没有**，而且暴露出更根本的一点：
**参考给出的指针 RVA 在 46015 上已经不能信**（tag 表位移 0x40、定义表槽位变成指针数组、全局表指针指向一块全零内存）。
全零的表**没法用内容验证**，所以"按地址找"这条路到此为止。v3 改成**按内容找**：

| v3 新增 | 做法 | 期望 |
|---|---|---|
| `DATABLOCK` 落盘 | 把 `0x3460000` 起 128 KiB 的模块数据整块导出（三个指针 RVA 都在里面） | 离线找出**真正的**指针变量位置，而不是靠猜 |
| **堆内内容搜索（hash hunt）** | 用**已确认的 32 条 tag 哈希**当指纹，在战役堆附近 ±512 MiB 的私有可写内存里找；命中就记地址 + 前后文；首个命中簇的 64 KiB 落盘为 `HITWIN` | 定义表（id→tag_hash）只要在内存里就一定会被抓到——**这条路不依赖任何 RVA** |
| **修饰条目搜索（entry hunt）** | 找 16 字节条目：首字节 = 17（敌人标签）、+4 的 tag 在 1..31 | 直接发现装词条的行/表，证明"表此刻是不是空的" |

## 5. 下一步

1. 用户再跑一次 **v3**（会自动等数据就绪，然后巡一遍堆，约 1–2 分钟；日志里 `PROBE_hunt_*` 有进度）。
2. 我离线解析：①`HITWIN`/`PROBE_hunt_hit` 定位定义表 → 产出**敌人模板菜单**（定义 id ↔ tag 哈希 ↔ 索引）；
   ②`HITWIN`/board 里的星球描述记录 → 对齐**星球 id ↔ 名字**（用本机 `English_translations.json`，不需要社区 API）；
   ③`DATABLOCK` → 修正三个指针 RVA。
3. 再做正式写作包：单包 + `%APPDATA%\Arrowhead\Helldivers2\` 外部设置文件（约 2 秒热重载）+ 词条叠加（≤5/行）。
4. "解锁隐藏星球"做成**独立开关的第二组件**，且实机验证顺序在词条之后。

> 相关：使用说明 `使用说明_星球工坊取证包.md`；离线仿真 `tools/sim/run_planet_forge_probe_sim.lua`；
> 运行分析脚本 `tools/parse_planet_forge_probe.py`、`build\_pf_analyze_run.py`。

## 6. 第二条路（用户建议，2026-10-01 当天奏效）：开源数据库 + 我们自己的转储

用户提议："**要不试试从我们常用的另一条路——开源数据库 filediver 等里面找**"。结果**当场突破**，
而且**不需要再进游戏**。关键事实：

1. **filediver 的 Go 结构定义是"字段级"的**：
   `build/filediver_fresh/datalibrary/planet_data.go` 给出 `rawPlanetData`（= `LevelGenerationPlanetData`）
   的全部字段与顺序；`datalib_instance.go` 给出两种头：
   * `DLInstanceHeader`（顶层块头，28 B）= `[u32][LDLD][version][type][size][is64][7B pad]`
   * `DLSubdataHeader`（子数据头，24 B）= `[LDLD][version][type][size][is64][7B pad]`
   紧接其后才是记录本体（`InheritsOffset i64`、`PlanetNameLoc u32`、`PlanetDescriptionLoc u32`…）。
2. **我们自己的 3.57 GB 全库转储里就有这些子数据**：搜 12 字节 pattern
   `4c 44 4c 44 01 00 00 00 82 b9 c2 08`（`LDLD`+version+`djb2("LevelGenerationPlanetData")`），
   记录在 +24，`PlanetNameLoc` 在记录 +8 ⇒ **393 个星球记录**，用本机 `English_translations.json`
   直接解出**名字与描述**（含 **ANGEL'S VENTURE**、FENNIR III、GATRIA…）。
   ⇒ **星球名不需要社区 API、不需要 board、不需要再跑一次游戏。**
3. **修饰定义表也在转储里**：定义记录（`id@+0 / kind@+4=40 / category@+24=13 / tag_hash@+28`，52 B  stride）
   直接扫出来，已经得到一张 **13 条 `定义 id ↔ tag 哈希 ↔ tag 表索引`** 菜单：

   | id | tag 哈希 | 表索引 | | id | tag 哈希 | 表索引 |
   |---|---|---|---|---|---|---|
   | 1202 | 0xAE2ED4E9 | 20 | | 1360 | 0x08766602 | 21 |
   | 1243 | 0x89E4FC2A | 9 | | 1377 | 0x021B60B3 | 29 |
   | **1244** | **0xA3A3DB9F** | **10**（孢裂 ✓） | | 1380 | 0xE2136DAA | 27 |
   | 1248 | 0x658544D8 | 23 | | 1401 | 0xBA586F51 | 31 |
   | 1303 | 0x907204FE | 11 | | 1402 | 0xFD8B9706 | 30 |
   | 1306 | 0x9FD5943A | 12 | | 1413 | 0x33FA1AB8 | 28 |
   | 1307 | 0x194C725F | 24 | | | | |

   （1244→索引 10 与参考 v4 清单的 `resolved_tag_id=10` **完全吻合**；1243 = 掠食变种→索引 9。）
4. **还找到一张规整的"装配条目"表**：转储里存在成片的 16 字节条目
   `11 00 00 00 | <tag 索引 0..31> | <子槽 0/1/2> | 0`，按 tag 分组、每组 3 个子槽、步长 48 B
   （例：bin 50,935,776 起）。这正是参考实现往"全局修饰表"行里写的那种条目的骨架
   ⇒ **这条线有可能整条走"DL 模板改写"（本项目的老本行），而不是运行时写内存**。下一步解析它的类型与布局。

**新增离线工具**（都不需要进游戏、不碰内存）：

| 脚本 | 作用 |
|---|---|
| `build/_pf_scan_dump.py` | 在 3.57 GB 转储里按 tag 哈希搜索；命中点往回找 `LDLD` 归块；并挑出"定义记录形状"的行 |
| `build/_pf_parse_planets.py` | 抽出全部 `LevelGenerationPlanetData` 记录 + 本地化解名（写 `build/planet_forge/planets.json`） |
| `build/_pf_scan_entries.py` | 搜 `type=17` 的 16 字节条目（64 种写法）并统计 |
| `build/_pf_extract_block.py` | 按类型哈希抽顶层块（用于确认哪些类型不是独立块、而是子数据） |
| `build/_pf_peek.py` | 按对齐打印任意偏移的十六进制 + u32 列，直接读结构 |
| `build/_pf_crack_loc_hash.py` | 验证"本地化键 = 某个常见 32 位哈希(英文文本)"**不成立**（murmur3/murmur2/FNV1/FNV1a/djb2/×3变体/sdbm/java/Jenkins/CRC32 全部 0/400） |
| `build/_pf_planet_modifiers.py` | 验证"32 位 tag 哈希是星球记录里 64 位 `GameplayModifiers` 的一半"**不成立**（395 条记录里零命中） |
| `build/_pf_string_hunt.py` | 在 3.57 GB 转储里搜词条名字符串：**英文名一个都没有**；连 `FENRIR III`/`GATRIA` 也没有（对照证明**转储里根本没有本地化文本**，只有 `planet_type_*` 134,508 处、以及少量法文任务文本里出现过 `SPORE`） |

## 7. 词条名称（词条名 ↔ 定义 id ↔ tag 索引）现状

**能给的**：13 条 `定义 id ↔ tag 哈希 ↔ tag 索引` 已经**离线抽出**（§6 表格）。其中两条的名字由参考实现锚定：
**1244 = 孢裂变种 / Spore Burst → tag 索引 10**（与 v4 清单 `resolved_tag_id=10` 一致）、
**1243 = 掠食变种 / Predator Strain → tag 索引 9**（GoPredator 的 `modifier_definition_ids=[1243,1245]`）。

**暂时给不了（11 条）**：人类可读名字。已排除的可能路径：
1. **DL 转储里没有本地化文本**（连星球名都没有，planet 记录只存本地化键）⇒ 不能从转储里直接读出名字；
2. 记录里 `+8/+12/+16` 三个哈希**不是**我们手上那份 `English_translations.json` 的键，也不是常见 32 位哈希(英文名)；
3. 32 位 tag 哈希**不是**本地化键，也**不是**星球记录里 64 位 `GameplayModifiers` 的一半；
4. 键不是 djb2/murmur/FNV/CRC 之类（15,249 组配对全部 0 命中）⇒ 键哈希的是**内部键名**，不是英文原文。

**剩下两条路**：
- **A（推荐）拿到更完整的本地化导出**：游戏自身的本地化在加密的 `.stream` 包里（磁盘上只有 `generated_language_settings.dl_bin` 3,996 字节），我们手上那份只有 15,249 条、显然不全。若能取到**完整**的本地化表，记录里那三个哈希里的名字键应该就能解出名字。
- **B 实机观察**：给可攻打星球挂一个词条，看星球面板显示的名字——**这条本来就要做**，因为"写入 tag 之后游戏真的换敌人池"至今**没有任何人证明过**（参考实现自己标 `runtime_verified=false`）。

**给名字之前最优的下一步**：先把那张 `type=17` 的装配表（32 个 tag × 3 子槽、步长 48、bin ~50,935,776）的 **DL 类型与字段布局**解出来，并打通"战争地图星球 id ↔ DL 星球记录"；这两件事都不需要进游戏。

## 8. 战争地图星球 id ↔ 名字（**已解决**，2026-10-01，全离线）

**怎么解出来的**：在 v2 实机那份 **board 转储**里，某类记录的**名字键前 24 字节正好是战争地图星球 id**。
首个撞见的是 FENNIR III 的名字键 `0xCF6E41C8`，它前面 24 字节是 `0x7d` = **125**——正好是 GoPredator 清单里
Fenrir III 的 id。按这个规律把 393 个名字键全扫一遍，得到 **272 条 `id → 名字`**，
**零冲突**（每个 id 只对应一个名字），单独脚本：`build/_pf_board_planet_map.py`
→ 产物 `build/planet_forge/war_id_to_name.json`。

**交叉验证（独立来源）**：

| id | 本表 | 来源/佐证 |
|---|---|---|
| 3 | WIDOW'S HARBOR | GoPredator v5-preview 的目标星球正是 3 寡妇港 ✓ |
| 125 | FENRIR III | GoPredator v3 清单 `"planet_names": {"125": "Fenrir III"}` ✓ |
| 127 | ANGEL'S VENTURE | Gosporebrust README 的"天使投资" ✓ |
| 173 | GATRIA | Gosporebrust INSTALL 的"173 盖尔崔亚" ✓ |
| 64 / 126 / 196 | MERIDIA / TURING / MALEVELON CREEK | 都是游戏里真实存在的星球名 ✓ |

**⚠️ 268 是"被战况顶替过的槽位"（用户解释 + 技术核实，2026-10-01）**：
Gosporebrust INSTALL 写"268 富源 / LUXURIANT"，而我们的 board/DL 表给的是 **268 = KEPLER-281b**。
用户说明原因是：**那个星球在一次大事件里"碎掉了"，之后原位置被富源 / LUXURIANT 顶替**。技术侧全部吻合：

| 证据 | 结果 |
|---|---|
| 星球数据记录（DL `LevelGenerationPlanetData`）与 board 里那份副本 | **至今仍写 KEPLER-281b**（键 `2834895362`） |
| 本机本地化导出 | `KEPLER-281b` 在；**`LUXURIANT` 0 命中** |
| 实机 board 内存里搜明文 | `LUXURIANT` / `KEPLER-281` **都 0 命中**（名字只以本地化键存在） |

⇒ 结论修正（此前我说"参考文档错了"，**这个判断不准确**）：**两边的观察都对**——
游戏内显示的是**战况重绑后**的富源，我们表里是**静态数据**里那个还没更新的旧星球；
冲突来自"**地图槽位 ↔ 星球**"可以被战况重绑。**对我们的直接影响**：
`war_id_to_name.json` 是**某一时刻的快照**，对**被顶替过的槽位会过时**；cfg 里名字只作便利、**id 才是权威**，
并且**268 这类特殊槽位不适合做第一次机制验证**（写入测试因此改用 215 = PARTION）。

**这一步的意义**：cfg 里可以直接写**星球名**（272 个），不必让用户查 id；剩下没有名字的 14 个非零动态记录
（286−272）是没有名字键的槽位。

## 9. `type=17` 条目表的假设**未获证据支持**（2026-10-01 反证）
先前推测"转储里那批 16 字节 `11 00 00 00 | v | k | 0` 条目 = 词条装配表"，两条反证：
1. `build/_pf_where.py` 显示它落在 **`HitEffectSettings` 子数据**里（+55,441），而不是任何一个"词条/星球"类型；
2. **实机 board 里没有任何"像词条"的 type-17 条目**：`build/_pf_live_entries.py` 扫 v2 的 1.6 MB board，
   出现的 `11 00 00 00` 后面跟的是 0/79/162/471 这类值（普通数据），而**全局修饰表那 11,392 字节里一个都没有**
   ⇒ 与"该表此刻是空的"一致。

⇒ 结论：**"哪些星球挂了哪些词条"此刻在内存里就是空的**，因此单靠读内存无法确定全局表地址；
要证它，只能**写一次看游戏反应**（这本就是下一步实机验证要做的），或**等游戏里真的有词条事件**时再抓一次。

## 10. 写入测试实机结果 + **词条真身在 board 里**（2026-10-01 晚，决定性）

### 10.1 v1 写入：写成功了，但那不是词条真身

实机日志（`%LOCALAPPDATA%\PlanetForgeWrite.log`，2026-10-01 19:57:58）：

```
candidate table from rva 0x346D518 = 0x26C4FA2A610
region base=0x26C4FA2A000 size=98951168 state=0x1000 prot=0x4 type=0x20000
table check: 0/11392 bytes non-zero
WRITE ok #1 row=0 addr=0x26C4FA2A610 planet=215 tag=10 filter=2 count=1
```

⇒ 指针解析、区域属性、空表判据、写入与回读**全部通过**；此后**游戏一次都没碰过那张表**（无 `WRITE changed`）。
而这张 11,392 字节的表在**战况正热**（679 人在打 PARTION）时**仍然是全零**。
⇒ **文档里的"全局战役修饰表"在本 build 里是"空且不被使用"的**。

**⚠️ 一条必须记住的观察纪律**：用户当时"没看到孢裂旗帜"是在第三方网站 **helldiverscompanion.com** 上看的
（那三个圆形图标只是该网站的环境标识）。**那是服务端战况，永远不可能反映我们本地内存的改动** ⇒
"v1 没生效"的结论**不成立**；**实机验收必须看游戏内**的星球面板 / 任务列表。

### 10.2 真身：board 里 87+ 条"修饰定义 id 列表"

`build/_pf_search_board.py` 用 32 个 tag 哈希 + 13 个定义 id 搜实机 board，**BOARD 段命中 48 处**；
再用 `build/_pf_modifier_lists.py` 按"以 0 结尾的 1100–1500 连续 u32"扫描，得到
**87+ 条列表**（`build/_pf_operation_records.py` 在 `0x40000–0x60000` 内列出 122 条记录）：

```
board+0x55ca8:  35 05 00 00 | 1e 05 00 00 | 1d 05 00 00 | 1c 05 00 00 | 17 05 00 00 | 1a 05 00 00 | 1b 05 00 00 | 00 00 00 00
                1333          1310          1309          1308          1303          1306          1307          结束
```

列表位于 **304 字节步长的记录**内，字段实测：

| 记录偏移 | 内容 |
|---|---|
| `+0` | 小整数（多为 0，偶见 2/3/4/5） |
| `+4` | 1–4 |
| `+8` | 奖励值（1000000 / 1500000 / 1600000 / 1900000 / 2100000） |
| **`+12`** | **星球/星区 timer**（`1085392668`=TRANDOR+HEETH、`1082479957`=PARTION+TIBIT、`1077004060`=173、`1088305380`=127/268/269/270、`1068615452`=125） |
| `+16` | 0/1 标志 |
| `+20`/`+24` | 浮点（0.3–0.6 量级） |
| `+32`/`+36` | 索引类数值（3…50 / 0…217） |
| **`+164`** | 1（"有位标志"） |
| **`+168`** | **以 `0` 结尾的词条定义 id 列表** |

**已知**：动态星球记录 `+64/+68/+72` 里有 54 / 171 / 217 这类小值，疑似指向本数组的索引，但**已验证不成立**
（按 `idx×304` 反推的地址 `292,256` 处，记录的 `+12` 仍是 PARTION 的 timer，而不是 TRANDOR 的）。
⇒ 记录↔星球的绑定**仍未解**。

### 10.3 取绑定的办法：只读快照 + 离线 diff

`dist/PlanetForgeBoardsnap.zip`（addon `mods/codex/planet_forge_boardsnap`，**零写入**）：
每 ~5 秒把 1.6 MB board 追加一份（最多 48 张、约 77 MB）到 `%LOCALAPPDATA%\PlanetForgeBoardsnap.{log,bin,idx}`，
每张附带 `active`（board+1548952）星球 id。用法：让用户在星图上**依次选中 TURING(126) / PARTION(215) / TIBIT(238)**
（每颗停几秒），然后我用 `build/_pf_diff_boardsnaps.py` 逐对比较，找出"换星球时变化的字节区间"，
并标注哪些区间紧邻"修饰 id 列表" ⇒ 直接得到绑定，再改写入目标为**该列表的 `+168`**。

### 10.4 ✅ v1 实机验证**成功**（2026-10-01 深夜，用户进游戏确认）

**结论翻转**：§10.1 里"那张表空且不被使用"的读法**不成立**——用户进入 **PARTION（帕尔晨，终结族）** 的任务后确认
**确实生效**：任务面板显示"**敌人势力增强·多重行动限制条件·重甲敌人**"，左侧"**敌情预测 // 情报与侦察**"列出
"**[超级掠食者] 强化追猎虫变种**""[吐酸虫群] 吐酸喷涌虫、吐沫虫与吐酸武斗虫""[重型敌人] 吐酸泰坦"
——正是我们写进去的 **tag 9 = 掠食变种** 的表现。

⇒ **三条定论**：
1. **全局战役修饰表 `game.dll+0x346D518` 是正确的写入点**（32 行 × 356 B、entry type 17、scope 0、filter 2 全部照文档即生效）；
   参考实现文档没指错，它只是自己从没验证过（`runtime_verified: false`）。
2. **"星系地图上没有词条图标" ≠ "任务里没有变种"**：地图那一屏**不显示**这一类修饰，效果体现在
   **任务详情 / 敌情预测 / 局内敌情**。→ 今后验收一律按这个口径，并**在游戏内看**。
3. **表当时全零只说明没有事件在用**，不能反过来否定地址；判据只能是"**写一次看游戏反应**"。
   （我们这次做到了参考作者没做到的一步。）

**仍未解决**：**TURING(126) 与 TIBIT(238) 无法进入**（faction 1 / available 0）⇒ 对"不可攻打/非本族"的星球，
必须补参考实现的另外两层（改星球动态记录 faction/state/timer/available + 从"中立星球"复制任务行，模板排除 268），
这正是"**把被隐藏/不可进入的星球调出来**"那条独立能力的实现路径。

**board 里那 87+ 条修饰 id 列表的定位修正**：它**不是**本次生效的路径（生效的是全局表），
但仍是真实存在的活数据（304 字节记录 `+168`、记录 `+12` = 星球/星区 timer），**留作后续研究**
（很可能是"任务/作战层面的词条展示"）。⇒ 教训：**别因为发现一个更像"真身"的结构，就把已按文档写成的路径判死**。

## 11. 参考实现的"解锁"三层（字节码反汇编实证）+ 我们的实测对照（2026-10-02）

它的 addon 是 **LuaJIT 字节码**，本机 luajit 缺 `jit/bc.lua` 与构建期生成的 `jit/vmdef.lua`，
且**没有 `jit.bcsave`**（`-b`/`-bl` 都报 `unknown luaJIT command`）。补法：`build/luajit_jit/jit/{bc.lua,vmdef.lua}`
+ 两个脚本 `build/_bc_compile.lua`（`loadfile`+`string.dump`）/`build/_bc_list.lua`（`bc.dump`），
清单落在 `build/_gpv4/gospore.list.txt`、`gopred.list.txt`；字符串/常量另见 `build/_gpv4_scan_bc.py`
（**KNUM 常量在清单里以 `; 4096`、`; 131072` 形式出现**）。

**它做的三层**（变量名与失败分支原样来自字节码）：

| 层 | 证据 | 说明 |
|---|---|---|
| ① `access_available` 字段 | `access_available_before/after/offset`、`planet 127 availability field changed` | = 我们的 `available@+48` |
| ② `dynamic_faction` 字段 | `dynamic_faction_before/after/offset`、`planet 127 dynamic faction is not the expected original or applied value` | = `faction@+36`，前后值都校验 |
| ③ 本地任务行 | `local_row_planet_offset` / `local_row_valid_offset` / `local_rows_offset` / `local_row_stride` / `local_rows_capacity`、`assert(slot,"no free local task row slot for planet 127")`、`task_rows=copy_%s_to_127:%d`、失败分支 `task_rows=no_neutral_template` | **只接受"中立星球"模板**（源码拼 `"neutral_"..source_planet`）；**先找空闲槽位**再按 `local_rows_offset + index*local_row_stride` 写入；补丁 helper 是 `sub(row,1,planet_offset)..新星球..sub(row,planet_offset+1)` ⇒ **只改星球字段**；`valid` **只读不写**且只有 **1 字节**（`byte(row, local_row_valid_offset+1) ~= 0`）；逐行读回校验/回滚（`local task row bytes changed`） |

**⚠️ 它自己标着 `runtime_verified: false`** ⇒ 这套解锁**从未被验证过**。我们的实测：
**图灵（126）能被改成"终结族控制 + 可进入"**（动态记录层成功，虽然游戏每轮改回、我们每轮重写），
但**任务列表始终为空**；且实测 `UNLOCK cache: 24 row(s), 0 neutral, source planets=269` ⇒
**悬停中立星球拿不到任务行（只有可攻打星球会填表）**，它那条"中立模板"路径在我们的环境里走不通；
抄进去的 12 行**每轮被游戏清回空** ⇒ **任务列表不是只由这 110 行生成的**，我们引用的"作战（operation）"
在目标星球名下不存在。⇒ 下一步：`unlock ... template <工作星球>`（**整条 304 字节动态记录照抄**），
若仍无任务，则复制那批 **304 字节的"作战记录"**（`+12` = 星球/星区 timer、`+168` 起是词条 id 列表）。

## 12. 明文源码（GitHub 仓库）——"中立星球"的正确含义（2026-10-02 关键纠正）

仓库 `NatsunXD/Gosporebrust` 有分支 `main` 与 `GoPredator`，**含明文 Lua**：
`build/refsrc/gopred_gosporebrust.lua`（24,957 B）、`main_gosporebrust.lua`、`windows_api.lua`、
`docs/TECHNICAL.md` 等 9 个文件（用 `node build/_fetch_ref.mjs` 经 jsdelivr 抓取——
本机 PowerShell 联网必失败，`web_fetch` 可行但会占上下文，node 直落盘最省）。

**决定性片段（`gopred_gosporebrust.lua:227` `candidate_source_planets`）**：

```lua
for planet in pairs(groups) do
  if planet ~= patch.task_target_planet
     and not (patch.task_source_excluded_planets or {})[planet] then
    local bytes = api.read(record + patch.dynamic_faction_offset, 4)
    local faction = bytes and u32(bytes, 0)
    if faction == patch.terminid_faction then        -- terminid_faction = 2
      candidates[#candidates + 1] = planet
    end
  end
end
table.sort(candidates)
local source = candidates[1]                          -- 取 id 最小的一颗
```

⇒ **它说的"中立星球"＝终结族(faction 2) 的普通星球**（`TECHNICAL.md` 的原话是"选择一个**没有星球
特殊标签**的中立星球"），**不是**超级地球、**也不需要防守战**——我此前按"faction 1 = 中立"实现是错的，
用户按我的错误描述去猜"必须是超级地球防守星球、当前无法实现"也是被误导。

**其余与源码对齐的点**（`capture_task_cache` / `ensure_task_rows` / `apply_task_fields`）：
① 缓存时按**行自报星球**分组，且只收 `task_row_valid(row)` 为真的行，目标星球自己的行不计入；
② 候选＝**阵营==2 且非目标且不在排除名单**，取 **id 最小**者（不是"行数最多"）；
③ 写槽位策略：**先把模板映射到目标星球自己已有的有效行**（覆盖），**再用未生效的行**；
④ 补丁只改星球字段（`retarget_task_row`），**写入前后都断言字节未被他人改动**，逐条 `pcall` + 读回 + 回滚；
⑤ 日志标签 `task_rows=copy_terminid_<源>_to_<目标>:<n> :transient`，无模板时 `task_rows=no_terminid_template`；
⑥ 触发条件：**只有当前活动/悬停星球是目标星球时**才写（与我们的视图门禁一致）；
⑦ 它**不写** active planet / selection ID / 网络包。

**结论**：来源分类从来不是我们的障碍（希斯 79 是 f2，本来就是合法来源）⇒ 剩余怀疑指向
**"写任务行到底能不能让客户端长出任务"**这件事本身（它的发布包在本机 46015 甚至跑不起来，
仓库文档标注的支持构建是更旧的 24826606 / 1.8.45317）。下一步应做**只读 A/B 转储**：
同一会话里分别转储"有任务的 f2 星球"与"已解锁的图灵"的动态记录 + 任务表，离线 diff 找真正的差异。


## 12.1 两个参考 addon 的**函数级**逻辑还原（2026-10-02，逐行读反汇编）

索引工具：`python build/_bc_prototypes.py build/_gpv4/gopred.list.txt [--grep 关键词]`
——它按 `-- BYTECODE --` 把头把清单切成**函数**，列出每个函数的字符串/全局/字段，先定位再精读
（gopred 共 **53 个函数**）。关键函数（gopred 清单行号）：

| 函数 | 行 | 作用 |
|---|---|---|
| [26] | 918 | `row_planet(row)`：读该行**自己声明的**星球字段 |
| [27] | 925 | `row_valid(row)`：读 `byte(row, valid_offset+1)`，`~= 0` 才算有效 |
| [28] | 939 | `patch_planet(row, target)`：`sub(row,1,planet_off)..target..sub(row,planet_off+1)` |
| [29] | 959 | 单行提交：`before/after` 快照 + 写 + **读回比对**，"local task row bytes changed" / "write failed" |
| **[31]** | **1051** | **扫描与选源**（下面详解） |
| [32] | 1206 | `index ↔ address` 换算（`offset + index*stride`） |
| **[33]** | **1242** | **拷贝计划与提交**（下面详解） |

**[31] 扫描与选源（154 条指令的还原）**：
1. 校验 `owner`（board 身份令牌，来自 [25] 的 `campaign board owner changed`）；不符就**清空自己的缓存**（`self.owner/self.slots = nil`）；
2. `rows = assert(read(board + local_rows_offset, capacity*stride), "local campaign task rows unavailable")` —— **整张表一次性读成字符串**；
3. `for index = 0, capacity-1` 逐行 `sub` 切片，对每行调用 `row_planet` 与 `row_valid`：**只有"行自己声明的星球非空"且"valid 字节 ≠ 0"的行才进入统计**；
4. 按**行声明的星球**分组：`slots[planet][#+1] = index`；同时先给 `task_target_planet` 与 `task_source_excluded_planets`（其计划里是 268）**占位**；
5. 选源：配置的 `task_source_planet` 优先，否则取**第一个有行且不是目标**的星球；
6. 记下 `self.rows / self.source_planet / self.owner`（`owner` 用来判定"手里的数据是不是本轮 board 的"）。

**[33] 拷贝计划与提交（213 条指令的还原）**：
1. 重新 `assert(writable_data(rows_addr, size), "local campaign task rows are not private")` + 读整表；
2. 再扫一遍，收 `{index, row}` 候选：条件同 [31]（行自报星球非空、valid 非 0），并**排除已属于目标星球的行**；
3. 取 `self.source_planet`；**`#rows == 0` ⇒ 直接返回 `task_rows=no_neutral_template`（放弃）**；
4. 为每一条源行**找一个空槽位**（目标星球尚未占用的 index），`assert(slot, "no free local task row slot for planet 125")`；
5. 生成补丁行（[28]）后**先校验"补丁行的星球字段 == 目标"**，再存入计划 `{address, before, after}`；
6. 提交：逐条 `pcall(write)`，**读回比对 `read(address,#after) == after`**，任一不符 ⇒ 回滚 `before`；
7. 日志 `task_rows=copy_<source>_to_<target>:<n>`（外加 `:transient` 标记）。

**⇒ 项目落地（v16）**：我们的扫描器按同一标准重写——**不再"扫到就收"**：
- 只接受**行自报星球 ≠ 0、≠ 目标、valid 字节 ≠ 0、且不在排除名单**的行（`valid` 改为**读 1 字节**，与它一致；之前读 u32 会被高位垃圾骗过）；
- 按**行声明的星球分组**（`UNLOCK scan: planet=<id> has rows (faction=…)`），选源显式化并记日志
  （`UNLOCK source planet=<id> (<为何选它>), N validated row(s), faction=…`）；
- 新增配置 `source <星球>`（强制来源）与 `exclude <id>[,<id>]`（默认恒排除 268）；
- 补丁后**先校验星球字段 == 目标**再落盘，写后逐行读回，异常回滚；日志
  `UNLOCK task rows planet=<目标> copied=N of M row(s) from planet=<来源>`。
