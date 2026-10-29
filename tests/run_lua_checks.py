from pathlib import Path
import sys
root=Path(__file__).resolve().parents[2]
source=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/".tools/lua_test_runtime"))
from lupa.lua51 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path=str(source/"scripts/?.lua").replace("\\","/")+";"+lua.globals().package.path
for path in source.rglob("*.lua"):
    lua.execute("assert(loadstring(...))",path.read_text(encoding="utf-8"))
lua.execute((source/"tests/test_policy.lua").read_text(encoding="utf-8"))
print("All mod Lua files parse under Lua 5.1")
