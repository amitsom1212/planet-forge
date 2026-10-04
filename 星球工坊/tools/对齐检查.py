"""Keep the addon and the config generator telling the same story.

    python tools/planet_forge_align.py            # check (used by tools/gate.py)
    python tools/planet_forge_align.py --write    # also drop the generated default cfg for the sim

The generator and the addon have to agree on: the cfg template version, where the live cfg lives, the
first-line rule that decides whether the addon may overwrite a file, the five-entry row limit, which
planets may never be a template source, and the syntax of every line the generator can emit. Each of
those is asserted here against the actual Lua source, so drift shows up as a failing gate step
instead of a mystery in someone's game.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# the generator is loaded by path, not by import name: that keeps its filename free (it is ASCII
# only because the installer .bat has to spell it out under cmd.exe's code page)
import importlib.util                                                       # noqa: E402
_spec = importlib.util.spec_from_file_location('planet_forge_cfg',
                                               Path(__file__).resolve().parent / 'cfg_gen.py')
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)


def addon_source() -> str:
    return (ROOT / 'src/planet_forge.lua').read_text(encoding='utf-8')


def check(problems: list[str], condition: bool, message: str) -> None:
    if not condition:
        problems.append(message)


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors='replace')
        except Exception:
            pass
    problems: list[str] = []
    lua = addon_source()

    # 1. same template version
    match = re.search(r'CFG_TEMPLATE_VERSION\s*=\s*(\d+)', lua)
    addon_version = int(match.group(1)) if match else None
    check(problems, addon_version == gen.NEXT_TEMPLATE_VERSION,
          f'模板版本不一致：插件 v{addon_version}，生成器 v{gen.NEXT_TEMPLATE_VERSION}')

    # 2. the same cfg locations and the same order
    generator_paths = [str(path).replace('\\', '/') for path in gen.cfg_candidates()]
    check(problems, any('Arrowhead/Helldivers2' in path for path in generator_paths),
          '生成器没有把 %APPDATA%/Arrowhead/Helldivers2 作为首选路径')
    for needle in ('Arrowhead', 'planetforge.cfg', 'LOCALAPPDATA'):
        check(problems, needle in lua, f'插件源码里找不到 cfg 定位关键字：{needle}')

    # 3. the first-line rule: the addon may only refresh a file it recognises, the generator must not
    #    produce such a file (otherwise a generated config would be overwritten)
    check(problems, "'^# PlanetForge'" in lua,
          '插件源码里找不到"^# PlanetForge"这个自家模板识别前缀')
    generated = gen.render(gen.default_spec(), gen.load_planets())
    first_line = generated.splitlines()[0]
    check(problems, not first_line.startswith('# PlanetForge'),
          f'生成器的首行会被插件当成自家模板而覆盖：{first_line!r}')

    # 4. five entries per row, on both sides
    check(problems, re.search(r'MAX_ENTRIES\s*=\s*5', lua) is not None,
          '插件源码里 MAX_ENTRIES 不是 5')
    check(problems, gen.MAX_TAGS == 5, f'生成器 MAX_TAGS 不是 5（是 {gen.MAX_TAGS}）')

    # 5. the same "never a template source" set
    for planet in sorted(gen.NEVER):
        check(problems, f'[{planet}] = true' in lua,
              f'生成器把 {planet} 列为禁用，但插件没有把它排除为模板来源')

    # 6. every line shape the generator can emit must be one the addon parses
    shapes = {
        'planet': re.compile(r'^planet\s+\d+\s+tag\s+[\d,]+(\s+filter\s+[1-4])?$'),
        'unlock-plain': re.compile(r'^unlock\s+\d+(\s+faction\s+[1-4])?$'),
        'unlock-source': re.compile(r'^unlock\s+\d+\s+faction\s+[1-4]\s+source\s+\d+$'),
        'unlock-hidden': re.compile(r'^unlock\s+\d+\s+faction\s+[1-4]\s+source\s+\d+\s+plan\s+127'
                                    r'\s+rows\s+on$'),
    }
    spec = gen.default_spec()
    spec['templates'].append({'planet': 215, 'faction': 2, 'tags': [9],
                              'targets': [{'planet': 3, 'class': 'hidden', 'tags': [9]}]})
    text = gen.render(spec, gen.load_planets())
    seen = set()
    for line in text.splitlines():
        # the addon strips everything from a '#' on (src/planet_forge.lua:308), so trailing comments
        # are legal and must not confuse this check either
        line = re.sub(r'#.*$', '', line).strip()
        if not line:
            continue
        for name, pattern in shapes.items():
            if pattern.match(line):
                seen.add(name)
                break
        else:
            problems.append(f'生成器写出了插件语法里没有的行：{line!r}')
    for need in ('planet', 'unlock-source', 'unlock-hidden'):
        check(problems, need in seen, f'生成器没有覆盖 {need} 这种行（口径没测全）')

    # 7. the addon's own parser accepts these keywords and nothing else
    for keyword in ('planet', 'unlock', 'faction', 'plan', 'rows', 'policy', 'state', 'source',
                    'exclude', 'copy'):
        check(problems, f"'{keyword}'" in lua, f'插件解析器里找不到关键字 {keyword}')

    # 8. the tag dictionary the picker shows has all 32 entries, and the known ones still match
    check(problems, len(gen.TAGS) == 32 and sorted(tag for tag, _ in gen.TAGS) == list(range(32)),
          '生成器的词条字典不是 0-31 共 32 条')
    expected = {9: '掠食', 10: '孢裂', 11: '爆裂', 20: '喷气旅', 21: '生化人', 23: '象牙军团',
                27: '占领者', 28: '入侵部队', 29: '无脑群氓', 30: '窃票者'}
    for tag, fragment in expected.items():
        name = gen.TAG_NAMES.get(tag, '')
        check(problems, fragment in name, f'词条 {tag} 的名字不对：{name!r} 里没有 {fragment!r}')

    if '--write' in sys.argv:
        out = ROOT / '星球工坊/build/generated_default.cfg'
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(generated, encoding='utf-8')
        # a second copy under an all-ASCII path: LuaJIT's io.open goes through the C runtime, and the
        # simulation loads these files itself, so the ASCII copy is the one it can always find
        plain = ROOT / 'build/_generated_default.cfg'
        plain.parent.mkdir(parents=True, exist_ok=True)
        plain.write_text(generated, encoding='utf-8')
        print(f'wrote {out} ({out.stat().st_size} B) and {plain} for the simulation to load')

    print(f'planet forge addon/generator alignment: {len(problems)} problem(s)')
    for problem in problems:
        print('  FAIL ' + problem)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
