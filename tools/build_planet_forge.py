"""Build the PlanetForge config-driven writer package.

    python tools/build_planet_forge.py

Same wrapper pattern as the other PlanetForge packages: the Chinese Arsenal display name lives in a
UTF-8 source file rather than being handed to the build through whatever console code page is
active, and the gate step stays one command.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import build_frv_addon as B  # noqa: E402

SOURCE = 'src/planet_forge.lua'
ADDON = 'mods/codex/planet_forge'
NAME = 'PlanetForge'
DISPLAY = '星球工坊（词条写入 · cfg 驱动）'
DESCRIPTION = ('Puts campaign enemy-template modifiers (tag table indices) on the planets listed in '
               '%APPDATA%\\Arrowhead\\Helldivers2\\planetforge.cfg, up to five tags per planet, '
               're-read about every 2 s. Verified mechanism (tag 9 on planet 215 shows in the '
               'mission screen enemy forecast). Only rows whose count is 0 are used; every row is '
               'snapshotted and read back, and restarting the game restores everything.')


def main():
    argv = sys.argv
    try:
        sys.argv = ['build_frv_addon.py', SOURCE, ADDON, NAME, DISPLAY, DESCRIPTION]
        return B.main()
    finally:
        sys.argv = argv


if __name__ == '__main__':
    raise SystemExit(main())
