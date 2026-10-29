from pathlib import Path
import sys

source = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(source.parent / ".tools/lua_test_runtime"))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path = str(source / "scripts/?.lua").replace("\\", "/") + ";" + lua.globals().package.path
lua.execute((source / "tests/test_navigation.lua").read_text(encoding="utf-8"))
