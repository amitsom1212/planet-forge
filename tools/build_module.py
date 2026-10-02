"""Compile the Codex AC-8 module sources and build an Arsenal patch archive.

Mirrors the reference Codex build: compile each Lua source to a LuaJIT dump,
wrap it in the engine's `lua` resource, and pack the resources into
`9ba626afa44a3aa3.patch_0`.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from hd2 import ARCHIVE, lua_resource, make_archive, resource_hash

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src'
BUILD = ROOT / 'build'
LUAJIT = Path(os.environ.get('HD2_LUAJIT', r'C:\Users\ASUS\AppData\Local\Temp\dsh-mS58Aa\luajit\src\luajit.exe'))

# resource name -> source file
MODULES = {
    'mods/codex/gun_calibration': 'module_bridge_ext.lua',
    'mods/codex/ac8_probe': 'ac8_probe.lua',
    'mods/codex/ac8_he_mode1': 'ac8_he_heavy_burn.lua',
    # The legacy HE mode 2 slot is retired again (its source is unused); the M-105 tier now has
    # a clean path of its own -- see the MGX-42 / M-105 block below.
    'mods/codex/ac8_he_mode2': 'ac8_he_mode2.lua',
    'mods/codex/ac8_flak_mode1': 'ac8_flak_heavy_burn.lua',
    # The effects-only flak tier ("只添加特殊效果、数值均不变") rides the other retired legacy slot.
    'mods/codex/ac8_flak_mode2': 'ac8_flak_effects_only.lua',
    # The legacy Brasch slot is retired again (its source is unused); the MGX-42 tier now has a
    # clean path of its own -- see the MGX-42 / M-105 block below.
    'mods/codex/ac8_general_brasch': 'ac8_general_brasch.lua',
    # MGX-42 Bullet Storm and M-105 Stalwart: a heavy-burn tier plus the same three round
    # substitutions the VG-70 package offers. These are NEW resource paths, so the shared
    # dispatcher (module_bridge_ext.lua, listed above) had to grow to include them -- and the
    # user must delete and re-import these two packages so the refreshed dispatcher reaches the
    # game (Arsenal does not refresh that resource on a plain update).
    'mods/codex/mgx42_heavy_burn': 'ac8_mgx42_heavy_burn.lua',
    'mods/codex/mgx42_to_mg206': 'ac8_mgx42_to_mg206.lua',
    'mods/codex/mgx42_to_hyena': 'ac8_mgx42_to_hyena.lua',
    'mods/codex/mgx42_to_mg43': 'ac8_mgx42_to_mg43.lua',
    'mods/codex/m105_heavy_burn': 'ac8_m105_heavy_burn.lua',
    'mods/codex/m105_to_mg206': 'ac8_m105_to_mg206.lua',
    'mods/codex/m105_to_hyena': 'ac8_m105_to_hyena.lua',
    'mods/codex/m105_to_mg43': 'ac8_m105_to_mg43.lua',
    # The VG-70's heavy-burn tier rides another retired legacy slot (the old flak hunt).
    'mods/codex/ac8_flak_hunt': 'ac8_vg70_heavy_burn.lua',
    # Snapshot patcher test modes: they edit the authoritative 64 KiB damage
    # snapshot by verified offset instead of matching heap copies by value.
    'mods/codex/ac8_snap_aphet': 'ac8_snap_aphet.lua',
    'mods/codex/ac8_snap_271': 'ac8_snap_271.lua',
    'mods/codex/ac8_snap_304': 'ac8_snap_304.lua',
    'mods/codex/ac8_snap_212': 'ac8_snap_212.lua',
    # Read-only weapon-map probe: dumps the reference weapon's weapon records and
    # scans the ProjectileWeapon array for round markers, to locate the field that
    # says which ammunition a weapon fires.
    'mods/codex/ac8_snap_weaponmap': 'ac8_snap_weaponmap.lua',
    # Ammo-id swap test: points the AC-8's APHET WeaponRounds record at another
    # round id, to find out whether that id is what selects a weapon's round.
    'mods/codex/ac8_snap_ammoswap': 'ac8_snap_ammoswap.lua',
    # Round substitution: the AC-8's own projectile-settings record gets another
    # round's calibre/speed/mass, in place, with its damage_type left alone.
    'mods/codex/ac8_swap_he': 'ac8_snap_swap_he.lua',
    'mods/codex/ac8_swap_flak': 'ac8_snap_swap_flak.lua',
    # Whole-record substitution: the AC-8's round becomes a byte copy of the target
    # round, keeping only the ranges that identify it (its id, its damage_type).
    'mods/codex/ac8_round_he': 'ac8_snap_round_he.lua',
    'mods/codex/ac8_round_he_full': 'ac8_snap_round_he_full.lua',
    'mods/codex/ac8_round_flak': 'ac8_snap_round_flak.lua',
    # Read-only dump of the whole round table, for identifying a round the probe
    # never captured and for choosing substitution targets.
    'mods/codex/ac8_round_table': 'ac8_snap_roundtable.lua',
    # Canary substitutions: rounds whose flight is unmistakable, used to settle
    # whether a record is the one a weapon mode actually reads.
    'mods/codex/ac8_canary_flak': 'ac8_snap_canary_flak.lua',
    'mods/codex/ac8_shell_he': 'ac8_snap_shell_he.lua',
    # Flak hunt: the HE round copied over the seven 23 mm candidates.
    'mods/codex/ac8_flak_hunt': 'ac8_snap_flak_hunt.lua',
    # Read-only dump of every weapon slot's ammo reference.
    'mods/codex/ac8_ammo_refs': 'ac8_snap_ammorefs.lua',
    # Flak hunt 2: the last five 20 mm rounds.
    'mods/codex/ac8_flak_hunt2': 'ac8_snap_flak_hunt2.lua',
    'mods/codex/ac8_breaker_to_pacifier': 'ac8_breaker_to_pacifier.lua',
    'mods/codex/ac8_breaker_to_hyena': 'ac8_breaker_to_hyena.lua',
    'mods/codex/ac8_breaker_to_re_educator': 'ac8_breaker_to_re_educator.lua',
    'mods/codex/ac8_gallant_to_pacifier': 'ac8_gallant_to_pacifier.lua',
    'mods/codex/ac8_gallant_to_hyena': 'ac8_gallant_to_hyena.lua',
    'mods/codex/ac8_gallant_to_re_educator': 'ac8_gallant_to_re_educator.lua',
    'mods/codex/ac8_purifier_to_epoch_p2': 'ac8_purifier_to_epoch_p2.lua',
    'mods/codex/ac8_vg70_to_mg206': 'ac8_vg70_to_mg206.lua',
    'mods/codex/ac8_vg70_to_hyena': 'ac8_vg70_to_hyena.lua',
    'mods/codex/ac8_vg70_to_mg43': 'ac8_vg70_to_mg43.lua',
    'mods/codex/ac8_purifier_to_epoch_p1': 'ac8_purifier_to_epoch_p1.lua',
    # The "heavy penetration + burning" tiers: by-id damage edits (AP + Fire /
    # BurningHeavy / StunMedium, resolved by name from the live status table) plus
    # the one-handed byte in the weapon's EquipmentComponent.
    'mods/codex/ac8_sp_heavy_burn': 'ac8_sp_heavy_burn.lua',
    # The retired effect-template slot now carries the Purifier's base heavy-burn tier (AoE
    # status on its two explosion records). It is reused on purpose: a NEW resource path needs
    # the dispatcher resource to list it, and Arsenal did not refresh that resource when only
    # an option was added, so a brand-new path deploys nothing and writes no log at all.
    'mods/codex/ac8_sp_effect_template': 'ac8_purifier_heavy_burn.lua',
    'mods/codex/ac8_gallant_heavy_burn': 'ac8_gallant_heavy_burn.lua',
    # Breaker family (SG-225 原版破裂者 and SG-225IE 高燃破裂者): three round
    # substitutions each plus a heavy-penetration burning tier, 32 pellets, one-handed.
    'mods/codex/ac8_brk_to_pacifier': 'ac8_brk_to_pacifier.lua',
    'mods/codex/ac8_brk_to_hyena': 'ac8_brk_to_hyena.lua',
    'mods/codex/ac8_brk_to_re_educator': 'ac8_brk_to_re_educator.lua',
    'mods/codex/ac8_brk_heavy_burn': 'ac8_brk_heavy_burn.lua',
    'mods/codex/ac8_bie_to_pacifier': 'ac8_bie_to_pacifier.lua',
    'mods/codex/ac8_bie_to_hyena': 'ac8_bie_to_hyena.lua',
    'mods/codex/ac8_bie_to_re_educator': 'ac8_bie_to_re_educator.lua',
    'mods/codex/ac8_bie_heavy_burn': 'ac8_bie_heavy_burn.lua',
    # Diagnostic isolation builds: Breaker pellets+one-handed only (never touches the
    # shared dt 173 damage record) and Gallant AP only (no status slots).
    'mods/codex/ac8_brk_pellets_only': 'ac8_brk_pellets_only.lua',
    'mods/codex/ac8_sp_status_only': 'ac8_sp_status_only.lua',
    'mods/codex/ac8_gallant_ap_only': 'ac8_gallant_ap_only.lua',
    # Read-only status-effect / equipment-component probe (no writes at all).
    'mods/codex/ac8_snap_statusdump': 'ac8_snap_statusdump.lua',
    # Snapshot-patch builds of the three real mods.
    'mods/codex/ac8_snap_he1': 'ac8_snap_he1.lua',
    'mods/codex/ac8_snap_he2': 'ac8_snap_he2.lua',
    'mods/codex/ac8_snap_flak1': 'ac8_snap_flak1.lua',
    'mods/codex/ac8_snap_flak2': 'ac8_snap_flak2.lua',
    'mods/codex/ac8_snap_brasch': 'ac8_snap_brasch.lua',
    'mods/codex/ac8_snap_brasch406': 'ac8_snap_brasch406.lua',
    # Global edits: all weapons, not just the autocannon.
    'mods/codex/ac8_ap_plus1': 'ac8_ap_plus1.lua',
    'mods/codex/ac8_ap_plus2': 'ac8_ap_plus2.lua',
    'mods/codex/ac8_ap_plus4': 'ac8_ap_plus4.lua',
    'mods/codex/ac8_fire_rate_600': 'ac8_fire_rate_600.lua',
    'mods/codex/ac8_fire_rate_900': 'ac8_fire_rate_900.lua',
    'mods/codex/ac8_fire_rate_2000': 'ac8_fire_rate_2000.lua',
}

INCLUDE_PREFIX = '--@include '


def inline_sources(source: Path, seen=None):
    """Splice `--@include <file>` (optionally `as Name`) into the chunk.

    Included files must define their public table as a file-scope local and must
    NOT end with `return`; their `return <name>` line is dropped so the
    definitions can be spliced above the module body. The `as` name is emitted
    as `local <name> = <name>` when it differs from the file's own table name.
    """
    seen = seen or set()
    out = []
    for line in source.read_text(encoding='utf-8').splitlines(keepends=True):
        stripped = line.strip()
        if not stripped.startswith(INCLUDE_PREFIX):
            out.append(line)
            continue

        spec = stripped[len(INCLUDE_PREFIX):].strip().split()
        name = spec[0]
        alias = None
        if len(spec) >= 3 and spec[1] == 'as':
            alias = spec[2]
        elif len(spec) >= 2:
            raise RuntimeError(f'bad include spec: {stripped}')

        target = SRC / name
        if name in seen:
            raise RuntimeError(f'circular include: {name}')
        if not target.exists():
            raise RuntimeError(f'include not found: {target}')
        seen.add(name)

        table = Path(name).stem
        binding = alias or table
        out.append(f'-- >>> begin inlined {name}\n')
        # Splice the include's own lines first, minus its trailing
        # `return <its table>` (which would otherwise end this chunk), then
        # bind the local this chunk uses.
        included = inline_sources(target, seen).splitlines(keepends=True)
        while included and included[-1].strip() == '':
            included.pop()
        if included and included[-1].strip() == f'return {table}':
            included.pop()
            out.append(f'-- (dropped `return {table}` from {name})\n')
        out.extend(included)
        # Only bind when the include declares its table under a different name;
        # `local X = X` would shadow the table with itself.
        if binding != table:
            out.append(f'\nlocal {binding} = {table}\n')
        out.append(f'-- <<< end inlined {name}\n')
        seen.discard(name)
    return ''.join(out)


def compile_module(source: Path, output: Path):
    """Inline includes, then compile to a LuaJIT dump (keeping the chunk name)."""
    output.parent.mkdir(parents=True, exist_ok=True)
    staged = output.with_suffix('.staged.lua')
    staged.write_text(inline_sources(source), encoding='utf-8', newline='\n')

    env = dict(os.environ)
    env['LUA_PATH'] = ';;'
    # Run from the LuaJIT directory: its default module search path is relative,
    # so the compiler only finds its own jit/* helpers when cwd is its own folder.
    result = subprocess.run(
        [str(LUAJIT), '-b', str(staged), str(output)],
        capture_output=True, text=True, env=env, cwd=str(LUAJIT.parent),
    )
    if result.returncode:
        raise RuntimeError(f'luajit -b failed for {source}:\n{result.stdout}{result.stderr}')
    return output.read_bytes()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--name', default='CodexAC8Probe')
    parser.add_argument('--out', default=str(BUILD))
    args = parser.parse_args()

    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    resources = {}
    report = {'modules': {}}
    for name, filename in MODULES.items():
        source = SRC / filename
        if not source.exists():
            print(f'  skip {name}: {filename} not found')
            continue
        bytecode = compile_module(source, outdir / (source.stem + '.ljbc'))
        resource = lua_resource(bytecode)
        resources[resource_hash(name)] = resource
        report['modules'][name] = {
            'resource_hash': f'{resource_hash(name):#018x}',
            'bytecode_bytes': len(bytecode),
            'resource_bytes': len(resource),
        }
        print(f'  {name}: {len(bytecode)} bytes bytecode -> {resource_hash(name):#018x}')

    if not resources:
        raise SystemExit('no modules to build')

    archive = make_archive(resources)
    (outdir / ARCHIVE).write_bytes(archive)
    (outdir / (ARCHIVE + '.stream')).write_bytes(b'')
    (outdir / (ARCHIVE + '.gpu_resources')).write_bytes(b'')
    print(f'  archive: {len(archive)} bytes -> {outdir / ARCHIVE}')

    report['archive'] = {
        'file': ARCHIVE,
        'size': len(archive),
        'resources': len(resources),
        'luajit': str(LUAJIT),
    }
    (outdir / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
