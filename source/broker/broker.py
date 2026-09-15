import os, json, subprocess, shutil, tarfile, tempfile, time, re
from pathlib import Path
from datetime import datetime, timezone
from typing import Optional
from fastapi import FastAPI, HTTPException, Header, Depends
from pydantic import BaseModel

DATA=Path(os.environ.get("PDA_DATA","/data"))
PROJECTS=DATA/"projects"
HOST_USER=Path("/host/user")
HOST_APPDATA=Path("/host/appdata")
HOST_WORKSPACE=Path("/host/workspace")
TOKEN=os.environ.get("BROKER_TOKEN","")
app=FastAPI(title="Phoenix Dev Broker",version="1.0.0")

def auth(x_broker_token:Optional[str]=Header(None)):
    import secrets
    if not TOKEN or not x_broker_token or not secrets.compare_digest(TOKEN,x_broker_token):
        raise HTTPException(401,"Broker authentication failed")
    return True

def run(cmd,timeout=60,check=False,cwd=None,env=None):
    p=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout,cwd=cwd,env=env)
    if check and p.returncode!=0: raise HTTPException(500,p.stdout[-12000:])
    return p

def docker_inspect(name):
    p=run(["docker","inspect",name],30)
    if p.returncode!=0: raise HTTPException(404,f"Container not found: {name}")
    x=json.loads(p.stdout)[0]
    return {
        "name":x.get("Name","").lstrip("/"),
        "image":x.get("Config",{}).get("Image"),
        "image_id":x.get("Image"),
        "running":x.get("State",{}).get("Running",False),
        "status":x.get("State",{}).get("Status"),
        "started_at":x.get("State",{}).get("StartedAt"),
        "restart_count":x.get("RestartCount",0),
        "ports":x.get("NetworkSettings",{}).get("Ports",{}),
        "networks":list((x.get("NetworkSettings",{}).get("Networks") or {}).keys()),
        "mounts":[{"source":m.get("Source"),"destination":m.get("Destination"),"mode":m.get("Mode"),"rw":m.get("RW")} for m in x.get("Mounts",[])],
        "health":(x.get("State",{}).get("Health") or {}).get("Status"),
        "labels":x.get("Config",{}).get("Labels") or {},
    }

def cfg(pid):
    f=PROJECTS/pid/"project.json"
    if not f.exists(): raise HTTPException(404,"Project is not registered")
    return json.loads(f.read_text())

def validate_project(pid):
    c=cfg(pid)
    current=docker_inspect(c["container"])
    return c,current

def host_to_mounted(path):
    p=str(Path(path))
    if p=="/mnt/user": return HOST_USER
    if p.startswith("/mnt/user/"):
        return HOST_USER / p[len("/mnt/user/"):]
    raise HTTPException(400,"Only explicit /mnt/user paths may be imported/read")

def safe_copytree(src,dst):
    if dst.exists():
        backup=dst.parent/(dst.name+".preimport-"+datetime.now().strftime("%Y%m%d%H%M%S"))
        dst.rename(backup)
    shutil.copytree(src,dst,symlinks=True,ignore=shutil.ignore_patterns(".git","__pycache__",".venv","node_modules"))

class InspectReq(BaseModel): container:str
class ImportSourceReq(BaseModel): source_host_path:str
class ImportInstallerReq(BaseModel): installer_host_path:str

@app.get("/health")
def health():
    docker_bin=shutil.which("docker")
    if not docker_bin:
        raise HTTPException(503,"Docker CLI is missing from the broker image")
    p=run([docker_bin,"version","--format","{{.Server.Version}}"],10)
    if p.returncode!=0:
        raise HTTPException(503,f"Docker Engine check failed: {(p.stdout or '').strip()[-2000:]}")
    return {"ok":True,"docker":p.stdout.strip(),"docker_cli":docker_bin}

@app.post("/inspect")
def inspect(req:InspectReq,_=Depends(auth)):
    # Deliberately only inspects the exact container explicitly named by the registration request.
    return docker_inspect(req.container)

@app.get("/project/{pid}/status")
def status(pid:str,_=Depends(auth)):
    c,s=validate_project(pid)
    return s

@app.post("/project/{pid}/import-source")
def import_source(pid:str,req:ImportSourceReq,_=Depends(auth)):
    c,_s=validate_project(pid)
    if c.get("source_host_path") and c["source_host_path"]!=req.source_host_path:
        raise HTTPException(403,"Source path does not match registered project")
    src=host_to_mounted(req.source_host_path)
    if not src.exists() or not src.is_dir(): raise HTTPException(404,"Source directory not found")
    dst=HOST_WORKSPACE/pid
    safe_copytree(src,dst)
    return {"ok":True,"destination":f"/mnt/user/dev/phoenix-projects/{pid}","files":sum(1 for _ in dst.rglob("*"))}

@app.post("/project/{pid}/import-installer")
def import_installer(pid:str,req:ImportInstallerReq,_=Depends(auth)):
    c,_s=validate_project(pid)
    if c.get("installer_host_path") and c["installer_host_path"]!=req.installer_host_path:
        raise HTTPException(403,"Installer path does not match registered project")
    src=host_to_mounted(req.installer_host_path)
    if not src.exists() or not src.is_file(): raise HTTPException(404,"Installer file not found")
    dst=PROJECTS/pid/"imported-installer"
    shutil.copy2(src,dst)
    return {"ok":True,"bytes":dst.stat().st_size}

def file_logs(c,tail=1000):
    out=[]
    appdata=c.get("appdata_host_path")
    if not appdata: return out
    base=host_to_mounted(appdata).resolve()
    for requested in c.get("log_files",[]):
        # absolute host path or path relative to appdata
        hp=requested if requested.startswith("/") else str(Path(appdata)/requested)
        mp=host_to_mounted(hp)
        try:
            rp=mp.resolve()
            if base not in rp.parents and rp!=base: continue
            if not rp.is_file(): continue
            with rp.open("rb") as f:
                f.seek(0,2); size=f.tell(); f.seek(max(0,size-512000))
                txt=f.read().decode(errors="replace").splitlines()[-tail:]
            out += [f"[file:{requested}] {line}" for line in txt]
        except Exception: pass
    return out


@app.get("/project/{pid}/discover-logs")
def discover_logs(pid:str,_=Depends(auth)):
    c,_s=validate_project(pid)
    appdata=c.get("appdata_host_path")
    if not appdata:
        return {"logs":[]}
    base=host_to_mounted(appdata)
    if not base.exists() or not base.is_dir():
        return {"logs":[]}
    found=[]
    for f in base.rglob("*"):
        try:
            if len(found)>=100: break
            if not f.is_file(): continue
            rel=f.relative_to(base)
            if len(rel.parts)>5: continue
            n=f.name.lower()
            if n.endswith(".log") or n in ("log","logs.txt","app.log","application.log","error.log","debug.log"):
                if f.stat().st_size <= 1024*1024*1024:
                    found.append(str(rel))
        except Exception:
            pass
    return {"logs":sorted(found)}

@app.get("/project/{pid}/logs")
def logs(pid:str,since:str="",tail:int=1000,_=Depends(auth)):
    c,s=validate_project(pid)
    cmd=["docker","logs","--timestamps","--tail",str(min(max(tail,10),5000))]
    if since: cmd += ["--since",since]
    cmd.append(c["container"])
    p=run(cmd,60)
    lines=(p.stdout or "").splitlines()
    lines += file_logs(c,min(tail,2000))
    cursor=datetime.now(timezone.utc).isoformat()
    return {"project":pid,"container":c["container"],"cursor":cursor,"combined":lines[-5000:],"runtime":s}

@app.post("/project/{pid}/action/{action}")
def action(pid:str,action:str,_=Depends(auth)):
    c,_s=validate_project(pid)
    if action not in ("test","build","deploy","rollback"): raise HTTPException(400,"Unsupported action")
    if not c.get("actions",{}).get(action): raise HTTPException(403,f"{action} action disabled")
    hook=PROJECTS/pid/"hooks"/f"{action}.sh"
    if not hook.exists(): raise HTTPException(404,"Hook missing")
    env=os.environ.copy()
    env.update({
        "PDA_PROJECT_ID":pid,
        "PDA_CONTAINER":c["container"],
        "PDA_WORKSPACE":f"/host/workspace/{pid}",
        "PDA_APPDATA":str(host_to_mounted(c["appdata_host_path"])) if c.get("appdata_host_path") else "",
        "PDA_PRODUCTION_IMAGE":c.get("container_image") or "",
    })
    p=run(["bash",str(hook)],1800,cwd=f"/host/workspace/{pid}",env=env)
    return {"action":action,"exit_code":p.returncode,"output":(p.stdout or "")[-50000:]}
