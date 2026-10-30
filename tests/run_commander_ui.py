"""Run focus-camera checks in a real, isolated DST renderer + local server.

No desktop input, player profiles, existing worlds or published mods are used.
Lua is sent through the game's native -console standard input. Both processes
use newly-created persistent storage. The temporary local mod is removed after
the processes stop; logs remain in the generated validation directory.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile
import time

SOURCE = Path(__file__).resolve().parents[1]
ROOT = SOURCE.parent
DEFAULT_GAME = Path("D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together")


def readlog(path):
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""


def waitfor(process, path, marker, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        content = readlog(path)
        if marker in content:
            return content
        if "]: WR_UI_FAILURE " in content or "LUA ERROR" in content:
            raise RuntimeError(f"Game Lua error; inspect {path}")
        if process.poll() is not None:
            raise RuntimeError(f"Process exited ({process.returncode}); inspect {path}")
        time.sleep(.25)
    raise TimeoutError(f"Did not receive {marker!r}; inspect {path}")


def command(process, lua):
    assert "\n" not in lua, "Native console accepts one Lua command per line"
    process.stdin.write((lua + "\n").encode("utf-8"))
    process.stdin.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, default=DEFAULT_GAME)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--storage", type=Path, help="Reuse only a previous work_robot_ui_test_* validation directory")
    args = parser.parse_args()
    storage = args.storage.resolve() if args.storage else Path(tempfile.mkdtemp(prefix="work_robot_ui_test_", dir=ROOT))
    assert storage.parent == ROOT.resolve() and storage.name.startswith("work_robot_ui_test_"), "Only isolated validation storage may be reused"
    name = "wr_ui_validation_" + storage.name.rsplit("_", 1)[-1]
    mod = args.game / "mods" / name
    assert not mod.exists()
    assert mod.resolve().parent == (args.game / "mods").resolve()
    cluster = storage / "server/DoNotStarveTogether/WorkRobotUI"
    master = cluster / "Master"
    master.mkdir(parents=True, exist_ok=True)
    (cluster / "cluster.ini").write_text("""[GAMEPLAY]
game_mode = survival
max_players = 1
pvp = false
pause_when_empty = false
[NETWORK]
cluster_name = WorkRobot Isolated UI Validation
offline_cluster = true
lan_only_cluster = true
cluster_password = workrobot-ui-test
[MISC]
console_enabled = true
[SHARD]
shard_enabled = false
""", encoding="utf-8")
    (master / "server.ini").write_text("[NETWORK]\nserver_port = 11016\n[STEAM]\nauthentication_port = 11017\nmaster_server_port = 11018\n[SHARD]\nis_master = true\n[ACCOUNT]\nencode_user_path = false\n", encoding="utf-8")
    (master / "modoverrides.lua").write_text(f"return {{ {name} = {{ enabled = true }} }}\n", encoding="utf-8")
    (master / "worldgenoverride.lua").write_text('return { override_enabled = true, preset = "SURVIVAL_TOGETHER", overrides = { world_size = "small", season_start = "autumn", day = "onlyday" } }\n', encoding="utf-8")
    processes, outputs = [], []
    server_log, client_log = storage / "server_console.log", storage / "client_console.log"
    try:
        mod.mkdir()
        shutil.copy2(SOURCE / "modinfo.lua", mod)
        shutil.copytree(SOURCE / "scripts", mod / "scripts")
        shutil.copy2(SOURCE / "tests/commander_ui.lua", mod / "scripts/wr_ui_validation.lua")
        main_lua = (SOURCE / "modmain.lua").read_text(encoding="utf-8")
        main_lua += '''
AddSimPostInit(function()
    if GLOBAL.TheWorld.ismastersim then
        GLOBAL.TheWorld:DoTaskInTime(1, function() print("WR_UI_SERVER_READY") end)
    end
end)
'''
        (mod / "modmain.lua").write_text(main_lua, encoding="utf-8")
        env = os.environ.copy()
        env["SteamAppId"] = "322330"
        def launch(exe, arguments, log):
            out = log.open("wb")
            outputs.append(out)
            proc = subprocess.Popen([str(exe), *arguments], cwd=exe.parent,
                stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW, env=env)
            processes.append(proc)
            return proc
        server = launch(args.game / "bin64/dontstarve_dedicated_server_nullrenderer_x64.exe",
            ["-console", "-offline", "-skip_update_server_mods", "-persistent_storage_root", str(storage / "server"),
             "-conf_dir", "DoNotStarveTogether", "-cluster", "WorkRobotUI", "-shard", "Master"], server_log)
        print(f"Native UI validation logs: {storage}", flush=True)
        waitfor(server, server_log, "WR_UI_SERVER_READY", args.timeout)
        client = launch(args.game / "bin64/dontstarve_steam_x64.exe",
            ["-console", "-offline", "-windowed", "-persistent_storage_root", str(storage / "client"), "-conf_dir", "WorkRobotUI"], client_log)
        waitfor(client, client_log, "Reset() returning", args.timeout)
        command(client, 'Profile:SetWarnModsEnabled(false); c_connect("127.0.0.1",11016,"workrobot-ui-test")')
        # A loaded world is necessary before the native spawn RPC can run.
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            command(client, 'local s=TheFrontEnd:GetActiveScreen(); if TheWorld and ((s and s.name=="LobbyScreen") or (ThePlayer and ThePlayer.HUD)) then print("WR_UI_CLIENT_WORLD_READY") else print("WR_UI_WAIT_SCREEN",s and s.name) end')
            time.sleep(1)
            if "WR_UI_CLIENT_WORLD_READY\t" in readlog(client_log):
                break
            if client.poll() is not None:
                raise RuntimeError(f"Client failed to connect; see {client_log}")
        else:
            raise TimeoutError(f"Client world did not load; see {client_log}")
        command(client, 'local s=TheFrontEnd:GetActiveScreen(); if s and s.name=="LobbyScreen" then TheFrontEnd:PopScreen() end; if not ThePlayer then TheNet:SendSpawnRequestToServer("wilson",nil,nil,nil,nil,nil,{},nil,{}) end')
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if client.poll() is not None:
                raise RuntimeError(f"Client exited before spawning; see {client_log}")
            command(client, 'if ThePlayer and ThePlayer.HUD then print("WR_UI_PLAYER_READY") end')
            time.sleep(1)
            if "WR_UI_PLAYER_READY\t" in readlog(client_log):
                break
        else:
            raise TimeoutError(f"Client player did not spawn; see {client_log}")
        command(server, 'local p=AllPlayers[1]; assert(p); local x,y,z=p.Transform:GetWorldPosition(); local r=SpawnPrefab("work_robot"); r.Transform:SetPosition(x+2,y,z+2); r.components.wr_worker:SetHome(r:GetPosition()); local c=SpawnPrefab("treasurechest"); c.Transform:SetPosition(x+5,y,z+2); local b=SpawnPrefab("berrybush"); b.Transform:SetPosition(x+7,y,z+2); local l=SpawnPrefab("log"); l.Transform:SetPosition(x+12,y,z+2); print("WR_UI_FIXTURE_READY",r.GUID,c.GUID,b.GUID,l.GUID)')
        waitfor(server, server_log, "WR_UI_FIXTURE_READY\t", 20)
        time.sleep(2)
        command(client, 'local ok,err=pcall(require,"wr_ui_validation"); if not ok then print("WR_UI_FAILURE "..tostring(err)) end')
        output = waitfor(client, client_log, "WR_UI_SUCCESS", 90)
        for line in output.splitlines():
            if "WR_UI_PASS" in line or "WR_UI_SUCCESS" in line:
                print(line)
        print("Client and server used isolated storage; real focus HUD, camera and mod RPCs were exercised.")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
        for output in outputs:
            output.close()
        if mod.exists() and mod.resolve().parent == (args.game / "mods").resolve() and mod.name == name:
            shutil.rmtree(mod)


if __name__ == "__main__":
    main()

