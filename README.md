# PlanetForge — 任意星球 · 任意敌人变种（Helldivers 2 客户端 mod）

**English TL;DR** — A client-side Lua addon (Bingus Shared Loader) that makes **any planet attackable**
— including planets that are **not on the star map at all** — and puts **any campaign enemy-variant
modifier** on any planet you like, driven by a plain-text config that hot-reloads in ~2 seconds.
Verified in game on build 1.8.46015. This is an unofficial fan tool; see NOTICE.md.

---

## 它是什么

- **解锁任意星球**：把一个"在图上但进不去"的星球（例如图灵 / TURING）变成可进入、有任务；
  也能把**根本不在星图上的隐藏星球**（例如天使投资 / ANGEL'S VENTURE）调出来。
- **任意敌人变种**：把战役词条（掠食 / 孢裂 / 爆裂 / 喷气旅 / 生化人 / 占领者 / 入侵部队…）写到任意星球上，
  每颗最多 5 个条目，按阵营生效。
- **外部配置 + 热重载**：所有设置写在 `planetforge.cfg`，插件每轮读一次（约 2 秒生效），
  改配置、换星球都不用重启游戏。
- **可还原**：删掉配置里那一行，插件会把星球记录、写过的任务行都恢复原样。

> **两层要分清**：`unlock` 那一层决定"这颗星球**有没有任务**"；`planet … tag …` 那一层决定"这颗星球**刷什么变种**"。
> 两者独立 —— 新解锁的星球要单独给它写词条行。

## 安装

1. 用 Arsenal（或你的 mod 管理器）导入 `dist/PlanetForge.zip` → 启用 → **Purge** → **Deploy**；
2. 进游戏一次，插件会**自己生成**一份配置并打印日志：`%APPDATA%\Arrowhead\Helldivers2\planetforge.cfg`
   （没自己改过的话，插件更新时会自动刷新它；你改过的文件**永不覆盖**）。

## 配置

| 方式 | 怎么做 |
|---|---|
| **图形生成器** | 双击 `星球工坊/配置生成器.html`：选模板星球 + 目标星球（标"无人/隐藏"）、按名字/id 搜索 272 颗星球、底部有星图对照；可**导入现有 cfg** 继续改；可一键**替换目标 cfg**（浏览器支持时） |
| **一键安装** | 双击 `星球工坊/生成配置.bat`：自动用 Downloads 里刚下载的 `planetforge.cfg`（没有就装默认配方），**先备份**原文件 |
| **手写** | `planet <id> tag <索引>[,<索引>…] [filter 1-4]` / `unlock <id> [faction] [plan 125\|127] [rows on\|off] …` |
| **命令行** | `python 星球工坊/tools/cfg_gen.py --install`（还有 `--spec` / `--import` / `--live` / `--list-planets` / `--list-tags`） |

`filter`：1 超级地球 / 2 终结族 / 3 机器人 / 4 光能者。`plan 125` = 在图上但进不去的星球；`plan 127` = 隐藏星球。

## 看日志确认（`%LOCALAPPDATA%\PlanetForge.log`）

```
planet forge installed -- this line means the addon loaded, before any match
CFG loaded: 13 line(s) accepted, 0 ignored
WRITE ok #1 row=0 planet=215 tags=9,10,11 filter=2 count=3
UNLOCK ok planet=127 plan=127 faction=1->2 available=0->1 state@28=0->5 timer@44=…->0
UNLOCK template in use: faction 2, source planet=215, 30 row(s) (target=127)
UNLOCK task rows planet=127 wrote=30, now 30 of 30 row(s) (viewed=true, …)
PLANETFORGE ready: cfg=… lines=13 ignored=0 writes_total=9
```

- **有变种没任务** ⇒ `unlock` 没生效（看 `skipped …`）；
- **有任务没变种** ⇒ 缺该星球的 `planet <id> tag …` 行；
- `plan 127` 的隐藏星球会写 `state@28`/`timer@44`，`plan 125` 只写 `available`/`faction`。

## 仓库结构

```
src/planet_forge.lua              插件本体（Lua，~1400 行，注释里写了机制与偏移）
tools/build_planet_forge.py       打包（依赖 build_frv_addon.py / build_module.py / hd2.py）
tools/verify_frv_addon.py         校验（首行声明、名字哈希、只读断言、能被加载器发现）
星球工坊/                          给用户的一整套：图形生成器、一键安装 bat、索引、使用说明、
                                  机制与 RVA 实测文档、示例配置、口径对齐检查、离线仿真
build/planet_forge/planets_live.json  272 颗星球的名字/阵营/可用性（由实测数据派生的小表）
dist/PlanetForge.zip              可直接导入游戏的成品包
dist/星球工坊_配置工具包.zip        配置工具全套（生成器 + 一键安装 + 文档 + 仿真）
```

`星球工坊/tools/对齐检查.py` 会把插件源码与生成器逐条对齐（模板版本、cfg 路径、首行识别前缀、
5 条目上限、禁名单、它能写出的每一种行形状），`星球工坊/sim/仿真.lua` 是离线仿真（假 ffi + 假内存），
两者都能独立跑：`python 星球工坊/tools/对齐检查.py`、`luajit 星球工坊/sim/仿真.lua`。

## 它是怎么做到的（要点）

- 战役修饰表：32 行 × 356 字节，行内最多 5 个 16 字节条目（`type=17` 在 +0、tag 索引在 +4），
  行 +80 是条目数、+84 是作用域、+88 是值、+92 是阵营过滤 —— 我们只写"条目数为 0"的空行，每条写一次并回读。
- 星球动态记录、任务行表的位置与字段见 `星球工坊/参考_机制与RVA实测.md`（含两次实机复现）。
- 让它真正生效的三把钥匙：①**整份复制**任务行（不是截断）；②只在**目标星球正被查看**时写；③**来源阵营 = 目标阵营**。

## 致谢与来源

- 词条思路来自社区 mod **Gosporebrust / GoPredator**（作者 NatsunXD）：本仓库**不含它们的代码**，
  只参考了公开的行为与清单，并用实机取证重写了实现。
- 星图对照图：由 `星球工坊` 附带脚本从 [helldivers.wiki.gg](https://helldivers.wiki.gg/wiki/Galactic_War)
  抓取（**仓库不打包该图片**；缺失时生成器会自动隐藏那块面板）。
- Helldivers 2 是 Arrowhead Game Studios 的商标与作品；本工具与之无关，见 NOTICE.md。

## 许可

本仓库**自研代码**按 MIT 许可（见 LICENSE）；游戏资源与商标不属于本项目。
