"""Isolated offline DST engine validation. Does not read or modify existing worlds."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import importlib.util
import threading
from http.server import ThreadingHTTPServer

SOURCE = Path(__file__).resolve().parents[1]
ROOT = SOURCE.parent
GAME = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together")
MOD = GAME / "mods" / "work_robot_validation"
STORAGE = Path(tempfile.mkdtemp(prefix="work_robot_test_", dir=ROOT))
CLUSTER = STORAGE / "DoNotStarveTogether" / "WorkRobotTest"
assert not MOD.exists(), f"Temporary test mod already exists: {MOD}"
assert MOD.resolve().parent == (GAME / "mods").resolve()
(CLUSTER / "Master").mkdir(parents=True, exist_ok=True)
(CLUSTER / "cluster.ini").write_text("""[GAMEPLAY]
game_mode = survival
max_players = 1
pvp = false
pause_when_empty = false
[NETWORK]
cluster_name = WorkRobot Isolated Validation
offline_cluster = true
lan_only_cluster = true
cluster_password = workrobot-test-only
[MISC]
console_enabled = true
[SHARD]
shard_enabled = false
""", encoding="utf-8")
(CLUSTER / "Master/server.ini").write_text("[NETWORK]\nserver_port = 11013\n[STEAM]\nauthentication_port = 11014\nmaster_server_port = 11015\n[SHARD]\nis_master = true\n[ACCOUNT]\nencode_user_path = false\n", encoding="utf-8")
(CLUSTER / "Master/modoverrides.lua").write_text('return { work_robot_validation = { enabled = true } }\n', encoding="utf-8")
(CLUSTER / "Master/worldgenoverride.lua").write_text('return { override_enabled = true, preset = "SURVIVAL_TOGETHER", overrides = { world_size = "small" } }\n', encoding="utf-8")
fixture = None
try:
    spec = importlib.util.spec_from_file_location("wr_bridge", SOURCE / "bridge/bridge.py")
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    planner = bridge.Planner(enabled=True, transport=lambda _: {"policy": {"guard": True, "harvest": True}})
    fixture = ThreadingHTTPServer(("127.0.0.1",8766), bridge.handler_for(planner))
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    MOD.mkdir()
    shutil.copy2(SOURCE / "modinfo.lua", MOD)
    shutil.copytree(SOURCE / "scripts", MOD / "scripts")
    shutil.copy2(SOURCE / "tests/game_smoke.lua", MOD / "scripts/work_robot_smoke.lua")
    main = (SOURCE / "modmain.lua").read_text(encoding="utf-8")
    main += '''
AddSimPostInit(function()
    GLOBAL.TheWorld:DoTaskInTime(1, function()
        local ok, err = GLOBAL.pcall(GLOBAL.require, "work_robot_smoke")
        if not ok then
            print("WR_GAME_FAILURE "..GLOBAL.tostring(err))
            GLOBAL.c_shutdown(false)
        end
    end)
end)
'''
    (MOD / "modmain.lua").write_text(main, encoding="utf-8")
    exe = GAME / "bin64/dontstarve_dedicated_server_nullrenderer_x64.exe"
    log = STORAGE / "engine_console.log"
    with log.open("wb") as out:
        process = subprocess.Popen([str(exe), "-console", "-offline", "-skip_update_server_mods", "-port", "11013",
            "-persistent_storage_root", str(STORAGE), "-conf_dir", "DoNotStarveTogether",
            "-cluster", "WorkRobotTest", "-shard", "Master"],
            cwd=exe.parent, stdout=out, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW)
        print(f"Started isolated offline DST engine, PID {process.pid}; log: {log}", flush=True)
        try:
            process.wait(timeout=240)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=15)
            raise RuntimeError(f"Engine test timeout; see {log}")
    output = log.read_text(encoding="utf-8", errors="replace")
    for line in output.splitlines():
        if "WR_GAME_" in line or "LUA ERROR" in line or "Error" in line:
            print(line)
    assert "WR_GAME_SUCCESS" in output, f"Engine validation failed; see {log}"
    assert len(planner.calls) == 1, "Group AI command must make exactly one model call"
finally:
    if fixture:
        fixture.shutdown()
        fixture.server_close()
    # Only this newly-created, exact temporary mod folder is removed.
    if MOD.exists() and MOD.resolve().parent == (GAME / "mods").resolve() and MOD.name == "work_robot_validation":
        shutil.rmtree(MOD)
