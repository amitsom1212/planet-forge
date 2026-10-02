"""PlanetForge config generator -- build planetforge.cfg without hand-writing it.

    python tools/planet_forge_cfg.py --default --out 星球工坊_示例配置.cfg   # the shipped template
    python tools/planet_forge_cfg.py --spec my.json --out planetforge.cfg  # a custom recipe
    python tools/planet_forge_cfg.py --spec my.json --install              # find the live cfg and
                                                                          # replace it (with backup)
    python tools/planet_forge_cfg.py --install                             # same, default recipe
    python tools/planet_forge_cfg.py --spec my.json --report               # validate only
    python tools/planet_forge_cfg.py --install-file my.cfg                 # just place a cfg
    python tools/planet_forge_cfg.py --emit-html 星球工坊_配置生成器.html   # the GUI version
    python tools/planet_forge_cfg.py --self-test                           # used by tools/gate.py
    python tools/planet_forge_cfg.py --list-planets [--all]                # what can be picked
    python tools/planet_forge_cfg.py --list-tags

The recipe is C/S shaped, as requested: one TEMPLATE planet (the row source, per faction) serves any
number of TARGET planets. Each target must be marked as an unoccupied planet (on the map, not
attackable -- the mod writes `plan 125`: availability + faction) or a hidden planet (not on the map --
the mod also zeroes the timer and sets state@28, i.e. `plan 127 rows on`). Tags come from the
dictionary below and a target may carry at most five (the row holds five entries; the addon would
spill a longer list into a second row, but the rule here is five).

Data sources: build/planet_forge/war_id_to_name.json (272 planet names) and the board probe dump in
log信息/ (faction / availability / state per planet, from an earlier session -- it is a snapshot, so
the generated file states which planets the numbers came from).
"""
from __future__ import annotations

import datetime
import json
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NEXT_TEMPLATE_VERSION = 19           # keep in sync with src/planet_forge.lua
CAMPAIGN_OFFSET = 1053752
PLANET_DYNAMIC_OFFSET = 286752
PLANET_DYNAMIC_STRIDE = 304
NEVER = {268, 99}                    # shattered slot / special planet: never used
MAX_TAGS = 5

FACTION_NAMES = {1: '超级地球', 2: '终结族', 3: '机器人', 4: '光能者'}
FACTION_KEYS = {'superearth': 1, 'terminid': 2, 'automaton': 3, 'illuminate': 4}

# tag dictionary (32/32, all confirmed in game; see 参考_星球词条机制与RVA实测.md)
TAGS = [
    (0, '（空 tag）'), (1, '敌潮部队（防守战专用）'), (2, '吐酸虫群'), (3, '重甲虫群'),
    (4, '追猎虫群'), (5, '飞行虫群'), (6, '轻型虫群'), (7, '虫族育巢'), (8, '混编虫群'),
    (9, '掠食变种'), (10, '孢裂变种（阴霾变种）'), (11, '爆裂变种（掘地虫群）'), (12, '蟑龙启用'),
    (13, '尖啸虫修正'), (14, '突击部队'), (15, '方阵部队'), (16, '炮兵部队'), (17, '空中编组'),
    (18, '装甲纵队'), (19, '机器人混编部队'), (20, '喷气旅'), (21, '生化人部队'), (22, '炮艇修正'),
    (23, '象牙军团（喷火旅）'), (24, '霸王虫标识'), (25, '光能者残部'), (26, '战争机器修正'),
    (27, '占领者'), (28, '入侵部队'), (29, '无脑群氓'), (30, '窃票者'), (31, '超级地球支援'),
]
TAG_NAMES = dict(TAGS)

# The 32 tag hashes this build shipped (measured on this machine; see the reference doc §3). The
# addon's live export carries the same table read at runtime, so a game update that adds or reorders
# tags shows up as a mismatch instead of silently mislabelling a tag.
KNOWN_TAG_HASHES = {
    0: 0x7CC6EE5A, 1: 0x41A4DF74, 2: 0xDF4CB4E5, 3: 0x5EF255B7, 4: 0xC323A525, 5: 0x23ECEBE0,
    6: 0xA7ACB9EA, 7: 0x44FE54CD, 8: 0x39E2D413, 9: 0x89E4FC2A, 10: 0xA3A3DB9F, 11: 0x907204FE,
    12: 0x9FD5943A, 13: 0xFBE995C2, 14: 0x87EE5692, 15: 0x0E7439B9, 16: 0x527691DD, 17: 0xC8044964,
    18: 0x044BAAEA, 19: 0x46B522B8, 20: 0xAE2ED4E9, 21: 0x08766602, 22: 0xC02D8176, 23: 0x658544D8,
    24: 0x194C725F, 25: 0xD4DB21D9, 26: 0xFECB6B78, 27: 0xE2136DAA, 28: 0x33FA1AB8, 29: 0x021B60B3,
    30: 0xFD8B9706, 31: 0xBA586F51,
}


def live_path(explicit: str | None = None) -> Path | None:
    """Where the addon's read-only live export sits (it writes it beside its log)."""
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    local = os.environ.get('LOCALAPPDATA')
    if local:
        candidates.append(Path(local) / 'PlanetForge.live.json')
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def apply_live(planets: dict, live: dict) -> tuple[list[str], dict]:
    """Fold a live export in: unknown planets become selectable, known ones get refreshed, and a tag
    table that no longer matches our 32 recorded hashes is reported loudly."""
    notes: list[str] = []
    live_by_id = {}
    for entry in live.get('planets') or []:
        try:
            live_by_id[int(entry['id'])] = entry
        except (KeyError, TypeError, ValueError):
            continue
    fresh = []
    for planet, entry in live_by_id.items():
        if planet not in planets:
            planets[planet] = {'name': f'（新星球 {planet}）', 'faction': 0, 'available': None,
                               'state': None, 'timer': None}
            fresh.append(planet)
        for key in ('faction', 'available', 'state', 'timer'):
            if entry.get(key) is not None:
                planets[planet][key] = entry[key]
    if fresh:
        notes.append(f'live: 名字表里没有的星球 id={sorted(fresh)}（已加入可选列表，名字未知）')

    hashes = {}
    for entry in live.get('tag_hashes') or []:
        try:
            hashes[int(entry['index'])] = int(entry['hash'])
        except (KeyError, TypeError, ValueError):
            continue
    changed = sorted(index for index, value in hashes.items()
                     if index in KNOWN_TAG_HASHES and KNOWN_TAG_HASHES[index] != value)
    extra = sorted(index for index in hashes if index not in KNOWN_TAG_HASHES)
    if changed:
        notes.append(f'live: tag 索引 {changed} 的哈希与我们记录的 32 条不一致'
                     '（这个版本可能改动了词条，别按旧名字用）')
    if extra:
        notes.append(f'live: 出现了我们没记录的 tag 索引 {extra}（可能是新词条）')
    count = live.get('tag_count')
    if count is not None and int(count) != len(KNOWN_TAG_HASHES):
        notes.append(f'live: 这个版本有 {count} 条 tag（我们记录 {len(KNOWN_TAG_HASHES)} 条）')
    summary = {'taken': live.get('taken'), 'planets': len(live_by_id), 'tags': len(hashes),
               'new_planets': sorted(fresh), 'changed_tags': changed, 'extra_tags': extra}
    return notes, summary


def load_planets() -> dict:
    """id -> {name, faction, available, state, timer}.

    Prefers build/planet_forge/planets_live.json (a small derived table, so a checkout of this folder
    works without the raw sources), then falls back to the name table plus the board probe dump."""
    compact = ROOT / 'build/planet_forge/planets_live.json'
    if compact.is_file():
        raw = json.loads(compact.read_text(encoding='utf-8'))
        return {int(key): dict(value) for key, value in raw.items()}
    names_path = ROOT / 'build/planet_forge/war_id_to_name.json'
    raw = json.loads(names_path.read_text(encoding='utf-8')) if names_path.is_file() else {}
    names = {}
    for key, value in raw.items():
        name = value[0] if isinstance(value, list) and value else value
        names[int(key)] = str(name)
    planets = {planet: {'name': name, 'faction': 0, 'available': None, 'state': None, 'timer': None}
               for planet, name in names.items()}
    dump = ROOT / 'log信息/PlanetForge.probe.bin'
    index = ROOT / 'log信息/PlanetForge.probe.idx'
    if dump.is_file() and index.is_file():
        body = dump.read_bytes()
        at = None
        for line in index.read_text(encoding='utf-8', errors='replace').splitlines():
            parts = line.split('|')
            if len(parts) == 4 and parts[0] == 'BOARD':
                at = int(parts[1])
        if at is not None:
            base = at + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
            for planet in range(1, 400):
                record = body[base + planet * PLANET_DYNAMIC_STRIDE:
                              base + (planet + 1) * PLANET_DYNAMIC_STRIDE]
                if len(record) < PLANET_DYNAMIC_STRIDE or not any(record):
                    continue
                entry = planets.setdefault(planet, {'name': '?', 'faction': 0})
                entry['faction'] = struct.unpack_from('<I', record, 36)[0]
                entry['available'] = struct.unpack_from('<I', record, 48)[0]
                entry['state'] = struct.unpack_from('<I', record, 28)[0]
                entry['timer'] = struct.unpack_from('<I', record, 44)[0]
    return planets


def classify(planet: int, planets: dict) -> tuple[str, str]:
    """(class, explanation) -- what kind of planet this is, and what that means for the config."""
    entry = planets.get(planet)
    if planet in NEVER:
        return 'forbidden', '特殊槽位（268 碎掉的槽 / 99 KEPLER-361b），不要用'
    if entry is None:
        return 'unknown', '名字表里没有这个 id（可能不是有效星球）'
    name = entry['name']
    if entry.get('available') == 1:
        return 'active', f'{name}：当前就能打（available=1），不需要 unlock，只写 planet 词条行即可'
    return 'locked', (f'{name}：当前未开启（available=0, state={entry.get("state")}, '
                      f'faction={entry.get("faction")}）')


def cfg_candidates() -> list[Path]:
    """The same search order the addon uses, so an install lands where the mod will read it."""
    appdata = os.environ.get('APPDATA')
    local = os.environ.get('LOCALAPPDATA')
    candidates = []
    if appdata:
        candidates.append(Path(appdata) / 'Arrowhead/Helldivers2/planetforge.cfg')
        candidates.append(Path(appdata) / 'planetforge.cfg')
    if local:
        candidates.append(Path(local) / 'planetforge.cfg')
    return candidates


def install(text: str) -> tuple[Path, Path | None]:
    """Find the config the mod reads, back up what is there, and replace it. Returns (path, backup)."""
    candidates = cfg_candidates()
    target = next((path for path in candidates if path.is_file()), None)
    if target is None:
        target = candidates[0] if candidates else Path('planetforge.cfg')
        target.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    if target.is_file():
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        backup = target.with_name(target.name + f'.bak-{stamp}')
        extra = 1
        while backup.exists():   # two installs in the same second must not clobber each other
            backup = target.with_name(target.name + f'.bak-{stamp}-{extra}')
            extra += 1
        backup.write_bytes(target.read_bytes())
    target.write_text(text, encoding='utf-8')
    return target, backup


def render(spec: dict, planets: dict, version: int = NEXT_TEMPLATE_VERSION) -> str:
    """Render a cfg. Raises ValueError with a readable message when the recipe is invalid."""
    lines: list[str] = []
    problems: list[str] = []
    # NOTE: the first line must NOT start with "# PlanetForge" -- the addon treats a file whose first
    # line starts that way (and that has no state file) as one of its OWN generated templates and
    # would refresh it, wiping whatever the user generated here.
    lines.append(f'# 星球工坊配置（由 tools/planet_forge_cfg.py 生成，对应插件模板 v{version}）')
    lines.append('# 这个文件被插件视为"用户自己编辑过"，永远不会被插件覆盖。')
    lines.append('# planet <id> tag <索引>[,<索引>…] [filter 1-4]   unlock <id> [faction 1-4] '
                 '[plan 125|127] [rows on|off] [source <模板星球>]')
    lines.append('# 注意：任务（unlock）与词条（planet）是两层，解锁后要单独给该星球写 planet 行。')
    templates = spec.get('templates') or []
    if not templates:
        problems.append('配方里没有任何模板星球（templates 为空）')
    for template in templates:
        # a template may have no named source (an imported cfg can lack `source`): then the unlock
        # lines simply omit it, exactly like a hand-written file would
        source = int(template['planet']) if template.get('planet') is not None else None
        faction = int(template.get('faction') or 2)
        if faction not in FACTION_NAMES:
            problems.append(f'模板星球 {source} 的 faction={faction} 不合法（1-4）')
        source_class, source_note = classify(source, planets) if source is not None else \
            ('unknown', '未指定来源星球（用哪颗星球的模板由插件按阵营自动挑）')
        if source_class == 'forbidden':
            problems.append(f'模板星球 {source}：{source_note}')
        lines.append('')
        source_name = planets.get(source, {}).get('name', '?') if source is not None else '（未指定）'
        lines.append(f'# ===== 模板星球（来源）{source} — {source_name}'
                     f'（{FACTION_NAMES.get(faction, "?")}）：{source_note}')
        source_tags = template.get('tags') or []
        if source_tags and source is not None:
            _check_tags(source, source_tags, problems)
            lines.append(f'planet {source} tag {_tag_list(source_tags)} filter {faction}'
                         '    # 模板星球自己的词条（可选）')
        targets = template.get('targets') or []
        if not targets:
            lines.append('# （这个模板下还没有目标星球）')
        for target in targets:
            planet = int(target['planet'])
            kind = str(target.get('class') or 'unoccupied')
            tags = target.get('tags')
            if tags is None:
                tags = source_tags
            _check_tags(planet, tags, problems)
            target_class, note = classify(planet, planets)
            name = planets.get(planet, {}).get('name', '?')
            if target_class == 'forbidden':
                problems.append(f'目标星球 {planet}：{note}')
            if target_class == 'active':
                lines.append(f'# ⚠ {note}')
            origin = f' source {source}' if source is not None else ''
            if kind == 'hidden':
                unlock = (f'unlock {planet} faction {faction}{origin} plan 127 rows on'
                          f'    # 隐藏星球：写 timer/state 把它调出来 + 给它任务行')
            else:
                unlock = (f'unlock {planet} faction {faction}{origin}'
                          f'    # 无人星球：只写 available + 阵营 + 任务行')
            lines.append(f'# 目标星球 {planet} — {name}（{note}）')
            lines.append(unlock)
            if tags:
                lines.append(f'planet {planet} tag {_tag_list(tags)} filter {faction}'
                             f'    # {name} 的词条')
            else:
                lines.append(f'# planet {planet} tag <索引> filter {faction}   '
                             '（没选词条：这颗星球只有任务、没有特殊变种）')
    # statements this model cannot express are written back verbatim, so importing a hand-written
    # config and generating again never loses a line
    extras = [str(line).strip() for line in (spec.get('extras') or []) if str(line).strip()]
    if extras:
        lines.append('')
        lines.append('# ===== 以下是导入时无法在这个界面里表示的行，原样保留')
        lines.extend(extras)
    if problems:
        raise ValueError('\n'.join('  - ' + problem for problem in problems))
    return '\n'.join(lines) + '\n'


def _tag_list(tags) -> str:
    return ','.join(str(int(tag)) for tag in tags)


def _check_tags(planet: int, tags, problems: list[str]) -> None:
    if len(tags) > MAX_TAGS:
        problems.append(f'星球 {planet} 选了 {len(tags)} 个词条，超过上限 {MAX_TAGS} 个'
                        '（任务行一行只放 5 个条目）')
    for tag in tags:
        if int(tag) not in TAG_NAMES:
            problems.append(f'星球 {planet} 的词条索引 {tag} 不在 0-31 内')


def default_spec() -> dict:
    """Exactly the recipe the shipped config uses (so an untouched install matches this output)."""
    return {'templates': [
        {'planet': 215, 'faction': 2, 'tags': [9, 10, 11],
         'targets': [{'planet': 235, 'class': 'unoccupied', 'tags': [9, 10, 11]}]},
        {'planet': 262, 'faction': 3, 'tags': [20, 21, 23],
         'targets': [{'planet': 152, 'class': 'unoccupied', 'tags': [20, 21, 23]}]},
        {'planet': 224, 'faction': 4, 'tags': [27, 28, 29, 30],
         'targets': [{'planet': 238, 'class': 'unoccupied', 'tags': [27, 28, 29, 30]}]},
        {'planet': 215, 'faction': 2, 'tags': [],
         'targets': [{'planet': 126, 'class': 'unoccupied', 'tags': [9, 10]},
                     {'planet': 127, 'class': 'hidden', 'tags': [9, 10, 11]}]},
    ]}


def parse_cfg(text: str) -> dict:
    """Read a cfg back into a recipe, the way the addon reads it ('#' starts a comment, fields are
    whitespace separated). Statements this model cannot express are kept verbatim in `extras`, so
    importing and re-generating is lossless instead of quietly dropping somebody's line."""
    planet_tags: dict[int, tuple[list[int], int | None]] = {}
    unlocks: list[dict] = []
    extras: list[str] = []
    for raw in str(text or '').splitlines():
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if fields[0] == 'live':
            # the GUI does not model this switch, but it must survive a round trip
            extras.append(line)
            continue
        if fields[0] == 'planet' and len(fields) >= 2:
            try:
                planet = int(fields[1])
            except ValueError:
                extras.append(line)
                continue
            tags: list[int] = []
            filt = None
            index = 2
            while index < len(fields):
                key = fields[index]
                if key == 'tag' and index + 1 < len(fields):
                    for piece in fields[index + 1].split(','):
                        piece = piece.strip()
                        if piece.isdigit():
                            tags.append(int(piece))
                    index += 2
                elif key == 'filter' and index + 1 < len(fields):
                    filt = int(fields[index + 1]) if fields[index + 1].isdigit() else None
                    index += 2
                else:
                    index += 1
            planet_tags[planet] = (tags, filt)
        elif fields[0] == 'unlock' and len(fields) >= 2:
            try:
                planet = int(fields[1])
            except ValueError:
                extras.append(line)
                continue
            entry = {'planet': planet, 'faction': 2, 'source': None, 'hidden': False}
            index = 2
            while index < len(fields):
                key = fields[index]
                if key == 'faction' and index + 1 < len(fields):
                    entry['faction'] = int(fields[index + 1]) if fields[index + 1].isdigit() else 2
                    index += 2
                elif key == 'source' and index + 1 < len(fields):
                    entry['source'] = int(fields[index + 1]) if fields[index + 1].isdigit() else None
                    index += 2
                elif key == 'plan' and index + 1 < len(fields):
                    entry['hidden'] = fields[index + 1] == '127'
                    index += 2
                else:
                    index += 1
            unlocks.append(entry)
        else:
            extras.append(line)

    blocks: list[dict] = []
    seen: dict[tuple, dict] = {}
    for entry in unlocks:
        key = (entry['source'], entry['faction'])
        block = seen.get(key)
        if block is None:
            block = {'planet': entry['source'], 'faction': entry['faction'],
                     'tags': list(planet_tags.get(entry['source'] or 0, ([], None))[0]),
                     'targets': []}
            seen[key] = block
            blocks.append(block)
        tags = list(planet_tags.get(entry['planet'], ([], None))[0])
        block['targets'].append({'planet': entry['planet'],
                                 'class': 'hidden' if entry['hidden'] else 'unoccupied',
                                 'tags': tags})
    return {'templates': blocks, 'extras': extras}


def emit_html(path: Path, planets: dict) -> None:
    """Write the GUI: the template lives in tools/planet_forge_cfg_template.html so there is exactly
    one copy of the page (an inline copy in this file once drifted from the real one)."""
    template_path = ROOT / '星球工坊/tools/配置生成器模板.html'
    template = template_path.read_text(encoding='utf-8')
    live_notes: list[str] = []
    live_info = None
    found = live_path()
    if found:
        try:
            live = json.loads(found.read_text(encoding='utf-8', errors='replace'))
            live_notes, live_info = apply_live(planets, live)
            live_info['file'] = str(found)
        except Exception as error:                     # a broken export must not block the GUI
            live_notes = [f'live 导出读不了：{error}']
    data = {
        'liveNotes': live_notes,
        'live': live_info,
        'planets': {str(planet): {'name': entry.get('name', '?'),
                                  'faction': entry.get('faction') or 0,
                                  'available': entry.get('available'),
                                  'state': entry.get('state')}
                    for planet, entry in sorted(planets.items())},
        'tags': [{'id': tag, 'name': name} for tag, name in TAGS],
        'factions': {str(key): value for key, value in FACTION_NAMES.items()},
        'never': sorted(NEVER),
        'maxTags': MAX_TAGS,
        'version': NEXT_TEMPLATE_VERSION,
        'default': default_spec(),
    }
    path.write_text(template.replace('/*__DATA__*/', json.dumps(data, ensure_ascii=False)),
                    encoding='utf-8')




def self_test() -> int:
    planets = load_planets()
    failures = []
    text = render(default_spec(), planets)
    for needle in ('unlock 235 faction 2 source 215', 'unlock 127 faction 2 source 215 plan 127 rows on',
                   'planet 127 tag 9,10,11 filter 2', 'planet 152 tag 20,21,23 filter 3',
                   'planet 238 tag 27,28,29,30 filter 4'):
        if needle not in text:
            failures.append(f'默认配方里缺少：{needle}')
    for bad, why in (({'templates': [{'planet': 215, 'faction': 2, 'targets': [
            {'planet': 235, 'class': 'unoccupied', 'tags': [1, 2, 3, 4, 5, 6]}]}]}, '六个词条'),
            ({'templates': [{'planet': 268, 'faction': 2, 'targets': []}]}, '禁用槽位做模板'),
            ({'templates': [{'planet': 215, 'faction': 9, 'targets': []}]}, '非法阵营')):
        try:
            render(bad, planets)
        except ValueError:
            pass
        else:
            failures.append(f'应当被拒绝但通过了：{why}')
    # round trip: render -> parse -> render again must reproduce every statement line, and an
    # unexpressible line must survive verbatim (that is what "import an existing cfg" has to mean)
    spec = default_spec()
    spec['extras'] = ['live off', 'unlock 3 faction 2 plan 127 rows on']
    first = render(spec, planets)
    back = parse_cfg(first)
    second = render(back, planets)
    statements = lambda body: sorted(line.split('#', 1)[0].strip() for line in body.splitlines()
                                     if line.split('#', 1)[0].strip())
    # order is not compared: importing regroups lines by (source, faction), which the addon does not
    # care about -- it treats planet and unlock lines independently
    if statements(first) != statements(second):
        only_first = [line for line in statements(first) if line not in statements(second)]
        only_second = [line for line in statements(second) if line not in statements(first)]
        failures.append(f'往返不一致：只在第一遍有 {only_first[:4]}；只在第二遍有 {only_second[:4]}')
    if 'unlock 3 faction 2 plan 127 rows on' not in second or 'live off' not in second:
        failures.append('往返把无法表示的行弄丢了（extras 没有原样保留）')
    # a hand-written file without `source` must still import and re-render
    plain = parse_cfg('unlock 235 faction 2\nplanet 235 tag 9,10,11 filter 2\n')
    if statements(render(plain, planets)) != sorted(['unlock 235 faction 2',
                                                     'planet 235 tag 9,10,11 filter 2']):
        failures.append('没有 source 的手写配置往返失败')
    print(f'planet forge cfg generator: {len(failures)} problem(s)')
    for failure in failures:
        print('  FAIL ' + failure)
    return 1 if failures else 0


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            # keep the console's own encoding (GBK here) so Chinese shows up, but never crash on a
            # character it cannot represent -- writing files is always UTF-8 regardless
            stream.reconfigure(errors='replace')
        except Exception:
            pass
    args = sys.argv[1:]
    planets = load_planets()
    if '--live' in args:
        explicit = value('--live')
        if explicit and explicit.startswith('--'):
            explicit = None
        found = live_path(explicit)
        if not found:
            print('没有找到 live 导出（插件每轮会写 %LOCALAPPDATA%\\PlanetForge.live.json）——'
                  '先在游戏里让它跑一次，再用 --live 导入。')
            return 1
        try:
            live = json.loads(found.read_text(encoding='utf-8', errors='replace'))
        except Exception as error:
            print(f'live 导出读不了：{found}（{error}）')
            return 1
        notes, info = apply_live(planets, live)
        print(f'live 数据来源：{found}（导出时间 {info.get("taken")}，'
              f'{info.get("planets")} 颗星球 / {info.get("tags")} 条 tag 哈希）')
        for note in notes:
            print('  · ' + note)
        if not notes:
            print('  · 没有发现新星球或变动的 tag ✓')
        if '--json' in args:
            print(json.dumps(info, ensure_ascii=False))
        return 0

    def value(flag, default=None):
        return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else default

    if '--self-test' in args:
        return self_test()
    if '--list-tags' in args:
        for tag, name in TAGS:
            print(f'{tag:>3}  {name}')
        return 0
    if '--list-planets' in args:
        for planet, entry in sorted(planets.items()):
            kind, note = classify(planet, planets)
            if '--all' not in args and kind != 'locked':
                continue
            print(f'{planet:>4}  {note}')
        return 0
    if '--emit-html' in args:
        target = Path(value('--emit-html', str(ROOT / '星球工坊/配置生成器.html')))
        emit_html(target, planets)
        print(f'wrote {target} ({target.stat().st_size} B)')
        return 0
    if '--import' in args:
        source = Path(value('--import'))
        if not source.is_file():
            print(f'找不到这个配置：{source}')
            return 1
        spec = parse_cfg(source.read_text(encoding='utf-8', errors='replace'))
        blocks = spec['templates']
        print(f'{source} → {len(blocks)} 个模板、'
              f'{sum(len(b["targets"]) for b in blocks)} 个目标、'
              f'{len(spec.get("extras") or [])} 行原样保留')
        payload = json.dumps(spec, ensure_ascii=False, indent=2)
        if value('--save-spec'):
            out = Path(value('--save-spec'))
            out.write_text(payload, encoding='utf-8')
            print(f'配方已写出：{out}（可拖到 生成配置.bat 上安装，或用下面的文本）')
        print(payload)
        return 0
    if '--install-file' in args:
        source = Path(value('--install-file'))
        if not source.is_file():
            print(f'找不到这个文件：{source}')
            return 1
        target, backup = install(source.read_text(encoding='utf-8', errors='replace'))
        print(f'已把 {source} 安装为：{target}  ({target.stat().st_size} B)')
        if backup:
            print(f'原文件已备份为：{backup}')
        return 0
    spec = default_spec()
    if '--spec' in args:
        spec = json.loads(Path(value('--spec')).read_text(encoding='utf-8'))
    try:
        text = render(spec, planets)
    except ValueError as error:
        print('配置不合法：')
        print(error)
        return 1
    if '--install' in args:
        target, backup = install(text)
        print(f'已写入插件会读取的配置：{target}  ({target.stat().st_size} B)')
        if backup:
            print(f'原文件已备份为：{backup}')
        else:
            print('原来没有配置文件，已新建（插件不会覆盖"用户编辑过"的文件）。')
        print('游戏内约 2 秒热重载即生效；想还原就用备份文件覆盖回去。')
        return 0
    if '--report' in args or not value('--out'):
        print(text)
        return 0
    out = Path(value('--out'))
    out.write_text(text, encoding='utf-8')
    unlocks = text.count('unlock ')
    tags = text.count('planet ')
    print(f'wrote {out} ({out.stat().st_size} B): {unlocks} unlock 行, {tags} planet 行')
    return 0


if __name__ == '__main__':
    sys.exit(main())
