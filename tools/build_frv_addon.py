"""Build one BSL v15 addon from a Lua source file.

    python tools/build_frv_addon.py <source.lua> <addon path> <zip name> <display name> \
        [description] [guid]

The addon convention, as DRIVER HUD uses it (and as verified against DRIVER HUD's
own archive): the resource is plain Lua source whose *first line* declares

    -- HD2-Addon: mods/<group>/<name>

and the archive entry is named by the MurmurHash64A of that same path. No compiler,
no dispatcher, and nothing that can collide with another mod's bridge.

`guid` is derived from the zip name unless one is passed, so every package gets a stable
GUID of its own. That matters because **Arsenal identifies mods by GUID**: the historical
constant below was shared by seven packages, so importing a second one silently replaced
the first -- which turns "I tested the part patch" into "I tested the dump addon".
"""
import json
import shutil
import sys
import uuid
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import build_module as B
from build_mods import ARCHIVE
from hd2 import lua_resource, make_archive, resource_hash, sha256_upper

DIST = Path('dist')
FOLDER = 'CORE'
# The historical constant, kept only so it is possible to reproduce an old package on
# purpose (`--guid <that value>`). Do not hand it to new addons: see the docstring.
DEFAULT_GUID = 'c0d5a1e2-7b48-4f36-9d21-5e8a4b70c913'
# Namespace for the deterministic per-package GUIDs (uuid5). Fixed forever: changing it
# would re-identify every package to Arsenal and look like a different mod.
GUID_NAMESPACE = uuid.UUID('6f9619ff-8b86-d011-b42d-00c04fc964ff')
# A fixed timestamp so the same inputs always produce the same zip: the sha256 printed
# here is quoted in the notes, and a difference then means the content really changed.
STAMP = (2026, 9, 21, 0, 0, 0)


def guid_for(zip_name):
    """A stable GUID for one package, derived from its (already unique) zip name."""
    return str(uuid.uuid5(GUID_NAMESPACE, 'hd2-codex-frv/' + zip_name))



def write_zip(root, zip_path):
    """Zip a package directory with deterministic entry metadata."""
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(root.rglob('*')):
            if not path.is_file():
                continue
            info = zipfile.ZipInfo(path.relative_to(root).as_posix(), date_time=STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, path.read_bytes())
    return zip_path


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    addon_path = sys.argv[2]
    name = sys.argv[3]
    display = sys.argv[4] if len(sys.argv) > 4 else name
    description = sys.argv[5] if len(sys.argv) > 5 else display
    guid = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else guid_for(name)

    text = source.read_text(encoding='utf-8')
    first_line = text.splitlines()[0].strip()
    assert first_line == f'-- HD2-Addon: {addon_path}', (
        f'{source.name}: the addon marker must be the first line, found {first_line!r}')

    root = DIST / name
    if root.exists():
        shutil.rmtree(root)
    folder = root / FOLDER
    folder.mkdir(parents=True, exist_ok=True)

    key = resource_hash(addon_path)
    payload = lua_resource(text.encode('utf-8'))
    (folder / ARCHIVE).write_bytes(make_archive({key: payload}))
    for suffix in ('.stream', '.gpu_resources'):
        (folder / (ARCHIVE + suffix)).write_bytes(b'')

    manifest = {
        'Version': 1,
        'Guid': guid,
        'Name': display,
        'Description': description,
        'Options': [
            {'Name': display, 'Description': description, 'Include': [FOLDER]},
        ],
    }
    (root / 'manifest.json').write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

    zip_path = DIST / (name + '.zip')
    write_zip(root, zip_path)

    print(f'addon    : {addon_path}')
    print(f'guid     : {guid}')
    print(f'name hash: {key:#018x}')
    print(f'payload  : {len(payload)} bytes (source)')
    print(f'zip      : {zip_path}  {sha256_upper(zip_path.read_bytes())}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
