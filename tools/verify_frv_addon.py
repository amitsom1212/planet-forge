"""Verify a built BSL v15 addon package the way the loader will read it.

    python tools/verify_frv_addon.py dist/FRVAnchorHunt.zip mods/frv/anchor_hunt
"""
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import build_module as B
from hd2 import read_archive, resource_hash

if len(sys.argv) < 3:
    raise SystemExit(__doc__)
ZIP = Path(sys.argv[1])
ADDON_PATH = sys.argv[2]
ARCHIVE = 'CORE/9ba626afa44a3aa3.patch_0'

problems = 0


def check(condition, label):
    global problems
    print(f'  {"ok   " if condition else "FAIL "} {label}')
    if not condition:
        problems += 1


print(f'--- {ZIP} ({ADDON_PATH})')
check(ZIP.exists(), 'the zip exists')
with zipfile.ZipFile(ZIP) as zf:
    names = set(zf.namelist())
    check(ARCHIVE in names, f'{ARCHIVE} is in the zip')
    check('manifest.json' in names, 'manifest.json is in the zip')
    check(ARCHIVE + '.stream' in names, 'the .stream sidecar is in the zip')
    check(ARCHIVE + '.gpu_resources' in names, 'the .gpu_resources sidecar is in the zip')
    manifest = json.loads(zf.read('manifest.json').decode('utf-8'))
    check(manifest.get('Options', [{}])[0].get('Include') == ['CORE'],
          'the manifest includes CORE')
    blob = zf.read(ARCHIVE)

stage = Path('build/_addon_archive').resolve()
stage.parent.mkdir(parents=True, exist_ok=True)
stage.write_bytes(blob)
resources = read_archive(str(stage))

check(len(resources) == 1, f'the archive holds one resource ({len(resources)})')
check(resource_hash(ADDON_PATH) in resources,
      f'the entry name is the hash of {ADDON_PATH}')
payload = next(iter(resources.values()))
length = int.from_bytes(payload[0:4], 'little')
body = payload[8:]
check(length == len(body), f'the length field matches the body ({length})')
check(int.from_bytes(payload[4:8], 'little') == 2, 'the resource type is lua')
check(body[:3] != b'\x1bLJ', 'the body is source text')
check(body.split(b'\n', 1)[0].decode().strip() == f'-- HD2-Addon: {ADDON_PATH}',
      'the first line is the addon marker')

source = Path(sys.argv[3]) if len(sys.argv) > 3 else (
    Path('src') / (ADDON_PATH.rsplit('/', 1)[1] + '.lua'))
check(body == source.read_bytes(), f'the payload is {source.name}, byte for byte')

# The game's LuaJIT is Lua 5.1 with extensions: it has no `<<`, `>>` or `//`. A
# *source* addon is parsed by the game, so the operator reaches the parser and the
# addon fails to load -- which is what happened to the first anchor hunt, whose
# `1 << 20` made the loader report "unexpected symbol near '<'". Compiled modules
# only survived it because constant folding had already folded the expression away,
# which is luck rather than safety, so this is checked for every FRV source.
LUA53_OPERATORS = (('<<', 'left shift'), ('>>', 'right shift'), ('//', 'floor divide'))
for text, name in ((body.decode('utf-8', 'replace'), source.name),):
    for token, label in LUA53_OPERATORS:
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split('--', 1)[0]
            if token in code:
                check(False, f'{name}:{number} uses {token} ({label}), which the '
                             f'game\'s LuaJIT cannot parse')
                break

listing = (Path('build') / '_addon_syntax.ljbc').resolve()
env = dict(os.environ)
env['LUA_PATH'] = ';;'
result = subprocess.run([str(B.LUAJIT), '-b', str(source.resolve()), str(listing)],
                        capture_output=True, text=True, env=env, cwd=str(B.LUAJIT.parent))
check(result.returncode == 0, 'the source compiles')
if result.returncode:
    print(result.stdout, result.stderr)
if listing.exists():
    listing.unlink()

print(f'\naddon verification: {problems} problem(s)')
raise SystemExit(1 if problems else 0)
