import os, signal, subprocess, sys, time, urllib.request
from pathlib import Path

children = []
remote = None
remote_restart_at = 0.0
remote_enabled = os.environ.get("REMOTE_DESKTOP_ENABLED", "1").strip().lower() not in {"0", "false", "no", "off"}
remote_home = os.environ.get("REMOTE_DESKTOP_HOME", "/data/desktop-commander/home")
remote_host_root = os.environ.get("REMOTE_DESKTOP_HOST_ROOT", "/root/host")
remote_entry = os.environ.get("REMOTE_DESKTOP_ENTRY", "/mnt/user/appdata/phoenix-dev-agent/desktop-commander/node_modules/@wonderwhy-er/desktop-commander/dist/index.js")

def stop_children(signum=None, frame=None):
    for proc in children:
        if proc and proc.poll() is None:
            proc.terminate()
    deadline = time.time() + 10
    for proc in children:
        if not proc:
            continue
        while proc.poll() is None and time.time() < deadline:
            time.sleep(0.1)
        if proc.poll() is None:
            proc.kill()

signal.signal(signal.SIGTERM, stop_children)
signal.signal(signal.SIGINT, stop_children)

broker_env = os.environ.copy()
broker_env["PDA_DATA"] = "/data"
broker = subprocess.Popen([
    "uvicorn", "broker:app", "--host", "127.0.0.1", "--port", "8790"
], cwd="/app", env=broker_env)
children.append(broker)

for _ in range(60):
    if broker.poll() is not None:
        sys.exit(broker.returncode or 1)
    try:
        with urllib.request.urlopen("http://127.0.0.1:8790/health", timeout=2) as r:
            if r.status == 200:
                break
    except Exception:
        time.sleep(0.5)
else:
    stop_children()
    raise SystemExit("broker health check timed out")

agent_env = os.environ.copy()
agent_env.update({
    "HOME": "/home/phoenix",
    "BROKER_URL": "http://127.0.0.1:8790",
    "PDA_DATA": "/data",
    "PDA_WORKSPACE": "/workspace",
})

def drop_agent_privileges():
    os.setgroups([])
    os.setgid(1000)
    os.setuid(1000)

agent = subprocess.Popen([
    "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8787"
], cwd="/app", env=agent_env, preexec_fn=drop_agent_privileges)
children.append(agent)

def start_remote():
    global remote, remote_restart_at
    if not remote_enabled:
        return
    identity = Path(remote_home) / ".desktop-commander-device" / "device.json"
    if not identity.exists():
        print("Remote Desktop Commander identity missing; retrying later", flush=True)
        remote_restart_at = time.time() + 30
        return
    host_node = Path(remote_host_root) / "usr/local/bin/node"
    host_entry = Path(remote_host_root) / remote_entry.lstrip("/")
    if not host_node.exists() or not host_entry.exists():
        print("Remote Desktop Commander host runtime missing; retrying later", flush=True)
        remote_restart_at = time.time() + 30
        return
    env = os.environ.copy()
    env["HOME"] = remote_home
    cmd = ["chroot", remote_host_root, "/usr/local/bin/node", remote_entry, "remote"]
    remote = subprocess.Popen(cmd, env=env)
    children.append(remote)
    print(f"Remote Desktop Commander started pid={remote.pid}", flush=True)

start_remote()

while True:
    if broker.poll() is not None:
        rc = broker.returncode or 1
        stop_children()
        sys.exit(rc)
    if agent.poll() is not None:
        rc = agent.returncode or 1
        stop_children()
        sys.exit(rc)
    if remote_enabled:
        if remote is not None and remote.poll() is not None:
            print(f"Remote Desktop Commander exited rc={remote.returncode}; retrying", flush=True)
            remote = None
            remote_restart_at = time.time() + 10
        if remote is None and time.time() >= remote_restart_at:
            start_remote()
    time.sleep(1)
