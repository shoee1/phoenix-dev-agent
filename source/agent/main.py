import os, json, time, uuid, threading, subprocess, shutil, re, html
from pathlib import Path
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any
import requests
from fastapi import FastAPI, HTTPException, Depends, Request, BackgroundTasks
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.responses import HTMLResponse, PlainTextResponse
from pydantic import BaseModel, Field

APP_VERSION = "1.0.0"
DATA = Path(os.environ.get("PDA_DATA", "/data"))
WORKSPACE = Path(os.environ.get("PDA_WORKSPACE", "/workspace"))
PROJECTS = DATA / "projects"
INCIDENTS = DATA / "incidents"
LOGS = DATA / "logs"
BROKER_URL = os.environ.get("BROKER_URL", "http://phoenix-dev-broker:8790").rstrip("/")
BROKER_TOKEN = os.environ.get("BROKER_TOKEN", "")
ADMIN_USER = os.environ.get("PDA_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("PDA_ADMIN_PASSWORD", "")
DEV_SWEEP_SECONDS = int(os.environ.get("DEV_SWEEP_SECONDS", "600"))
FAST_WATCH_SECONDS = int(os.environ.get("FAST_WATCH_SECONDS", "60"))
CODEX_MODEL = os.environ.get("CODEX_MODEL", "").strip()
security = HTTPBasic()
app = FastAPI(title="Phoenix Dev Agent", version=APP_VERSION)

for p in (PROJECTS, INCIDENTS, LOGS, WORKSPACE):
    p.mkdir(parents=True, exist_ok=True)

def utcnow():
    return datetime.now(timezone.utc).isoformat()

def auth(creds: HTTPBasicCredentials = Depends(security)):
    import secrets
    if not ADMIN_PASSWORD:
        raise HTTPException(503, "Admin password not configured")
    if not (secrets.compare_digest(creds.username, ADMIN_USER) and secrets.compare_digest(creds.password, ADMIN_PASSWORD)):
        raise HTTPException(401, "Invalid credentials", headers={"WWW-Authenticate": "Basic"})
    return True

def broker(method, path, **kwargs):
    headers = kwargs.pop("headers", {})
    headers["X-Broker-Token"] = BROKER_TOKEN
    try:
        r = requests.request(method, BROKER_URL + path, headers=headers, timeout=kwargs.pop("timeout", 90), **kwargs)
    except requests.RequestException as e:
        raise HTTPException(502, f"Broker unavailable: {e}")
    if r.status_code >= 400:
        try: detail = r.json().get("detail", r.text)
        except Exception: detail = r.text
        raise HTTPException(r.status_code, f"Broker: {detail}")
    return r.json() if r.content else {}

def project_dir(pid): return PROJECTS / pid
def project_file(pid): return project_dir(pid) / "project.json"

def load_project(pid):
    f = project_file(pid)
    if not f.exists(): raise HTTPException(404, "Project not registered")
    return json.loads(f.read_text())

def save_project(cfg):
    p = project_dir(cfg["id"]); p.mkdir(parents=True, exist_ok=True)
    tmp = p/"project.json.tmp"; tmp.write_text(json.dumps(cfg, indent=2)); tmp.replace(p/"project.json")

def slugify(s):
    s = re.sub(r'[^a-zA-Z0-9._-]+','-',s.strip()).strip('-').lower()
    if not s or len(s)>64: raise ValueError("Invalid project id")
    return s

def safe_rel_log_name(path):
    return re.sub(r'[^a-zA-Z0-9._-]+','_', path)[-120:]

def init_project_files(cfg):
    p = project_dir(cfg["id"])
    (p/"hooks").mkdir(parents=True, exist_ok=True)
    (p/"diagnostics").mkdir(exist_ok=True)
    (p/"codex").mkdir(exist_ok=True)
    ws = WORKSPACE/cfg["id"]; ws.mkdir(parents=True, exist_ok=True)
    agents = ws/"AGENTS.md"
    if not agents.exists():
        agents.write_text(f"""# Phoenix Dev Agent rules — {cfg['display_name']}

- This repository is managed as Phoenix project `{cfg['id']}`.
- Never modify or operate on unrelated Unraid containers or projects.
- Production container: `{cfg['container']}`.
- Never deploy directly from an untested change.
- Use the registered test/build/candidate workflow before production promotion.
- Preserve persistent application data and existing rollback paths.
- Destructive operations, schema/data migrations, network changes, and production-data changes require explicit approval unless the project policy explicitly enables them.
- Keep PROJECT_STATE.md current after successful work.
- Prefer a complete, bundled change over a chain of tiny releases unless a blocker requires a hotfix.
- Docker orphan image cleanup may run only after a successful deployment.
""")
    state = ws/"PROJECT_STATE.md"
    if not state.exists():
        state.write_text(f"""# {cfg['display_name']} — Project State

Project ID: {cfg['id']}
Registered: {cfg['registered_at']}
Production container: {cfg['container']}
Mode: {cfg['mode']}

Current verified release: import pending
Current candidate: none
Last deployment: not yet managed by Phoenix Dev Agent

## Outstanding work
- Import/verify existing installer, build, test, deployment and rollback behaviour.
""")
    chat = ws/"CHAT_CONTEXT.md"
    if not chat.exists():
        chat.write_text(f"""# Chat handoff context

Use project ID `{cfg['id']}` when referring to this project from ChatGPT/Codex.
Phoenix Dev Agent is the authoritative source for current runtime/log/deployment state.
""")
    for action in ("test","build","deploy","rollback"):
        hf = p/"hooks"/f"{action}.sh"
        if not hf.exists():
            hf.write_text(f"""#!/bin/bash
set -euo pipefail
echo "Phoenix Dev Agent: {action} hook for {cfg['id']} has not been imported/configured yet."
exit 3
""")
            hf.chmod(0o755)

class RegisterRequest(BaseModel):
    container: str
    project_id: Optional[str] = None
    display_name: Optional[str] = None
    source_host_path: Optional[str] = None
    installer_host_path: Optional[str] = None
    appdata_host_path: Optional[str] = None
    log_files: List[str] = []
    mode: str = "development"
    auto_diagnose: bool = True
    auto_test: bool = True
    auto_build: bool = False
    auto_deploy: bool = False

class PolicyRequest(BaseModel):
    mode: Optional[str] = None
    auto_diagnose: Optional[bool] = None
    auto_test: Optional[bool] = None
    auto_build: Optional[bool] = None
    auto_deploy: Optional[bool] = None
    action_test: Optional[bool] = None
    action_build: Optional[bool] = None
    action_deploy: Optional[bool] = None
    action_rollback: Optional[bool] = None

class CodexRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=20000)
    full_auto: bool = True

@app.get("/health")
def health():
    return {"ok": True, "version": APP_VERSION, "time": utcnow()}

@app.get("/api/status")
def api_status(_: bool = Depends(auth)):
    b = broker("GET","/health")
    return {"agent":{"ok":True,"version":APP_VERSION},"broker":b,"projects":len(list(PROJECTS.glob("*/project.json")))}

@app.get("/api/projects")
def list_projects(_: bool = Depends(auth)):
    out=[]
    for f in sorted(PROJECTS.glob("*/project.json")):
        try:
            c=json.loads(f.read_text())
            try: c["runtime"]=broker("GET",f"/project/{c['id']}/status")
            except Exception as e: c["runtime"]={"error":str(e)}
            out.append(c)
        except Exception: pass
    return out

@app.post("/api/projects/register")
def register(req: RegisterRequest, _: bool = Depends(auth)):
    inspect = broker("POST","/inspect",json={"container":req.container})
    pid = slugify(req.project_id or req.container)
    if project_file(pid).exists():
        raise HTTPException(409, "Project already registered")
    appdata = req.appdata_host_path
    if not appdata:
        mounts = inspect.get("mounts",[])
        candidates=[m.get("source") for m in mounts if str(m.get("source","")).startswith("/mnt/user/appdata/")]
        appdata = candidates[0] if candidates else None
    cfg={
        "id":pid,
        "display_name":req.display_name or pid.replace("-"," ").title(),
        "container":req.container,
        "container_image":inspect.get("image"),
        "appdata_host_path":appdata,
        "source_host_path":req.source_host_path,
        "installer_host_path":req.installer_host_path,
        "log_files":req.log_files,
        "mode":req.mode if req.mode in ("normal","development","post-deploy") else "development",
        "registered_at":utcnow(),
        "last_log_cursor":None,
        "last_fast_cursor":None,
        "last_sweep":None,
        "last_fast_watch":None,
        "policy":{
            "auto_diagnose":req.auto_diagnose,
            "auto_test":req.auto_test,
            "auto_build":req.auto_build,
            "auto_deploy":req.auto_deploy,
        },
        "actions":{"test":False,"build":False,"deploy":False,"rollback":False},
        "runtime_snapshot":inspect,
    }
    save_project(cfg); init_project_files(cfg)
    if req.source_host_path:
        broker("POST",f"/project/{pid}/import-source",json={"source_host_path":req.source_host_path},timeout=300)
    if req.installer_host_path:
        broker("POST",f"/project/{pid}/import-installer",json={"installer_host_path":req.installer_host_path},timeout=120)
    if not req.log_files and appdata:
        try:
            discovered=broker("GET",f"/project/{pid}/discover-logs").get("logs",[])
            cfg=load_project(pid); cfg["log_files"]=discovered[:100]; save_project(cfg)
        except Exception:
            pass
    return load_project(pid)

@app.patch("/api/projects/{pid}/policy")
def update_policy(pid:str, req:PolicyRequest, _:bool=Depends(auth)):
    cfg=load_project(pid); d=req.model_dump(exclude_none=True)
    if "mode" in d:
        if d["mode"] not in ("normal","development","post-deploy"): raise HTTPException(400,"Bad mode")
        cfg["mode"]=d.pop("mode")
    for k in ("auto_diagnose","auto_test","auto_build","auto_deploy"):
        if k in d: cfg["policy"][k]=d.pop(k)
    for k in ("action_test","action_build","action_deploy","action_rollback"):
        if k in d: cfg["actions"][k.replace("action_","")]=d.pop(k)
    save_project(cfg); return cfg

@app.get("/api/projects/{pid}/logs")
def project_logs(pid:str, since:Optional[str]=None, tail:int=300, _:bool=Depends(auth)):
    load_project(pid)
    return broker("GET",f"/project/{pid}/logs",params={"since":since or "", "tail":min(max(tail,10),5000)})

@app.post("/api/projects/{pid}/sweep")
def manual_sweep(pid:str, background_tasks:BackgroundTasks, _:bool=Depends(auth)):
    load_project(pid); background_tasks.add_task(run_sweep,pid,True)
    return {"queued":True}

@app.post("/api/projects/{pid}/action/{action}")
def run_action(pid:str,action:str,background_tasks:BackgroundTasks,_:bool=Depends(auth)):
    cfg=load_project(pid)
    if action not in ("test","build","deploy","rollback"): raise HTTPException(400,"Unsupported action")
    if not cfg["actions"].get(action): raise HTTPException(403,f"{action} action is not enabled for this project")
    background_tasks.add_task(action_worker,pid,action)
    return {"queued":True,"action":action}

@app.post("/api/projects/{pid}/codex")
def codex(pid:str, req:CodexRequest, background_tasks:BackgroundTasks, _:bool=Depends(auth)):
    load_project(pid)
    background_tasks.add_task(codex_worker,pid,req.prompt,req.full_auto,None)
    return {"queued":True}


@app.post("/api/projects/{pid}/bootstrap")
def bootstrap_project(pid:str, background_tasks:BackgroundTasks, _:bool=Depends(auth)):
    cfg=load_project(pid)
    prompt=f"""Bootstrap Phoenix Dev Agent project `{pid}` using the existing repository and deployment information.
Read AGENTS.md and PROJECT_STATE.md first.
If /data/projects/{pid}/imported-installer exists, inspect it carefully. Also inspect existing installer/update/rollback scripts in the repository.
Create or update:
- PROJECT_STATE.md with the current detected version/state, without inventing facts.
- PHOENIX_IMPORT_REVIEW.md describing detected container/image/appdata/build/test/deploy/rollback behaviour and unresolved uncertainties.
- /data/projects/{pid}/hooks/test.sh
- /data/projects/{pid}/hooks/build.sh
- /data/projects/{pid}/hooks/deploy.sh
- /data/projects/{pid}/hooks/rollback.sh
The hooks must be complete and non-interactive, but must refuse destructive actions or unrelated-container operations.
Do not run deploy or rollback. Do not touch production. Do not enable any Phoenix action flags.
Reuse the project's proven existing install/upgrade logic wherever possible instead of inventing a parallel deployment path.
"""
    background_tasks.add_task(codex_worker,pid,prompt,True,None)
    return {"queued":True,"message":"Codex bootstrap queued; production actions remain disabled until reviewed."}

@app.post("/ui/project/{pid}/policy",response_class=HTMLResponse)
async def ui_policy(pid:str,request:Request,_:bool=Depends(auth)):
    cfg=load_project(pid); form=await request.form()
    mode=str(form.get("mode") or cfg.get("mode","development"))
    if mode not in ("normal","development","post-deploy"): mode="development"
    cfg["mode"]=mode
    for k in ("auto_diagnose","auto_test","auto_build","auto_deploy"):
        cfg["policy"][k]=form.get(k)=="on"
    for k in ("test","build","deploy","rollback"):
        cfg["actions"][k]=form.get("action_"+k)=="on"
    save_project(cfg)
    return HTMLResponse(f"<meta http-equiv='refresh' content='0;url=/project/{pid}'>")


@app.post("/ui/project/{pid}/bootstrap",response_class=HTMLResponse)
def ui_bootstrap(pid:str,background_tasks:BackgroundTasks,_:bool=Depends(auth)):
    bootstrap_project(pid,background_tasks,True)
    return HTMLResponse(f"<meta http-equiv='refresh' content='0;url=/project/{pid}'>")

@app.post("/ui/project/{pid}/sweep",response_class=HTMLResponse)
def ui_sweep(pid:str,background_tasks:BackgroundTasks,_:bool=Depends(auth)):
    load_project(pid); background_tasks.add_task(run_sweep,pid,True)
    return HTMLResponse(f"<meta http-equiv='refresh' content='0;url=/project/{pid}'>")

@app.post("/ui/project/{pid}/action/{action}",response_class=HTMLResponse)
def ui_action(pid:str,action:str,background_tasks:BackgroundTasks,_:bool=Depends(auth)):
    cfg=load_project(pid)
    if action not in ("test","build","deploy","rollback"): raise HTTPException(400,"Unsupported action")
    if not cfg["actions"].get(action): raise HTTPException(403,f"{action} action is not enabled for this project")
    background_tasks.add_task(action_worker,pid,action)
    return HTMLResponse(f"<meta http-equiv='refresh' content='0;url=/project/{pid}'>")

@app.get("/api/projects/{pid}/incidents")
def project_incidents(pid:str, _:bool=Depends(auth)):
    load_project(pid); d=INCIDENTS/pid
    out=[]
    if d.exists():
        for f in sorted(d.glob("*.json"), reverse=True)[:100]:
            try: out.append(json.loads(f.read_text()))
            except: pass
    return out

def write_runtime_log(pid, kind, text):
    d=LOGS/pid; d.mkdir(parents=True,exist_ok=True)
    f=d/f"{kind}.log"
    with f.open("a",errors="replace") as h:
        h.write(f"\n===== {utcnow()} =====\n{text}\n")

ERROR_RE=re.compile(r"(traceback|unhandled exception|\bcritical\b|\bfatal\b|\berror\b|health.?check.{0,20}(fail|down)|restart loop)",re.I)
WARN_RE=re.compile(r"\bwarn(?:ing)?\b",re.I)

def fingerprint(text):
    s=text.lower()
    s=re.sub(r'\b[0-9a-f]{8,}\b','<hex>',s)
    s=re.sub(r'\b\d+(?:\.\d+)+\b','<num>',s)
    s=re.sub(r'\b\d+\b','<n>',s)
    import hashlib
    return hashlib.sha256(s[:4000].encode(errors="ignore")).hexdigest()[:16]

def create_incident(pid, severity, summary, excerpt, fp):
    d=INCIDENTS/pid; d.mkdir(parents=True,exist_ok=True)
    # dedupe recent same fingerprint
    for f in sorted(d.glob("*.json"),reverse=True)[:20]:
        try:
            x=json.loads(f.read_text())
            if x.get("fingerprint")==fp and x.get("status") in ("new","investigating","candidate"):
                x["occurrences"]=x.get("occurrences",1)+1; x["last_seen"]=utcnow()
                f.write_text(json.dumps(x,indent=2)); return x,False
        except: pass
    iid=datetime.now().strftime("%Y%m%d-%H%M%S")+"-"+fp[:6]
    item={"id":iid,"project":pid,"severity":severity,"summary":summary[:300],"fingerprint":fp,
          "first_seen":utcnow(),"last_seen":utcnow(),"occurrences":1,"status":"new","excerpt":excerpt[-16000:]}
    (d/f"{iid}.json").write_text(json.dumps(item,indent=2))
    return item,True

def action_worker(pid,action):
    try:
        r=broker("POST",f"/project/{pid}/action/{action}",timeout=1800)
        write_runtime_log(pid,f"action-{action}",json.dumps(r,indent=2))
    except Exception as e:
        write_runtime_log(pid,f"action-{action}",f"FAILED: {e}")

def codex_worker(pid,prompt,full_auto=True,incident_id=None):
    ws=WORKSPACE/pid
    outdir=project_dir(pid)/"codex"; outdir.mkdir(exist_ok=True)
    stamp=datetime.now().strftime("%Y%m%d-%H%M%S")
    logfile=outdir/f"{stamp}.log"
    cmd=["codex","exec","--json","-C",str(ws)]
    if full_auto: cmd.append("--full-auto")
    if CODEX_MODEL: cmd += ["-m",CODEX_MODEL]
    cmd.append(prompt)
    env=os.environ.copy()
    try:
        p=subprocess.run(cmd,cwd=ws,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=3600,env=env)
        logfile.write_text(p.stdout or "")
        write_runtime_log(pid,"codex",f"exit={p.returncode}\n{p.stdout or ''}")
        if incident_id:
            f=INCIDENTS/pid/f"{incident_id}.json"
            if f.exists():
                x=json.loads(f.read_text()); x["codex_exit"]=p.returncode; x["codex_log"]=str(logfile); x["status"]="investigating" if p.returncode==0 else "codex-failed"; f.write_text(json.dumps(x,indent=2))
        if p.returncode==0:
            cfg=load_project(pid)
            if cfg["policy"].get("auto_test") and cfg["actions"].get("test"): action_worker(pid,"test")
            if cfg["policy"].get("auto_build") and cfg["actions"].get("build"): action_worker(pid,"build")
            if cfg["policy"].get("auto_deploy") and cfg["actions"].get("deploy"): action_worker(pid,"deploy")
    except Exception as e:
        logfile.write_text(f"FAILED: {e}")
        write_runtime_log(pid,"codex",f"FAILED: {e}")

def run_sweep(pid, manual=False, fast=False):
    try:
        cfg=load_project(pid)
        cursor_key="last_fast_cursor" if fast else "last_log_cursor"
        since=cfg.get(cursor_key)
        data=broker("GET",f"/project/{pid}/logs",params={"since":since or "", "tail":3000},timeout=120)
        text="\n".join(data.get("combined",[]))
        now=utcnow()
        cfg[cursor_key]=data.get("cursor") or now
        cfg["last_fast_watch" if fast else "last_sweep"]=now
        save_project(cfg)
        if text:
            write_runtime_log(pid,"sweep-fast" if fast else "sweep",text[-50000:])
        m=ERROR_RE.search(text)
        if m:
            excerpt=text[max(0,m.start()-6000):m.start()+10000]
            fp=fingerprint(excerpt)
            inc,created=create_incident(pid,"error","New error/critical log signature detected",excerpt,fp)
            if created and cfg["policy"].get("auto_diagnose"):
                prompt=f"""A Phoenix Dev Agent incident has been detected for project {pid}.
Read AGENTS.md, PROJECT_STATE.md, and the incident evidence at /data/incidents/{pid}/{inc['id']}.json if available.
Diagnose the error using the repository and prepare the smallest correct fix on the working tree.
Do not deploy production. Do not touch unrelated projects or containers.
Add/update tests where appropriate. Summarize what you changed and why.
Incident excerpt:
{excerpt[-8000:]}
"""
                # codex container sees /data incidents under /data, so provide repo-side incident copy too
                cdir=WORKSPACE/pid/".phoenix"; cdir.mkdir(exist_ok=True)
                (cdir/"LATEST_INCIDENT.md").write_text(f"# Incident {inc['id']}\n\n```\n{excerpt[-12000:]}\n```\n")
                threading.Thread(target=codex_worker,args=(pid,prompt,True,inc["id"]),daemon=True).start()
        elif not fast and WARN_RE.search(text):
            fp=fingerprint(text[-10000:])
            create_incident(pid,"warning","Warning pattern detected during development sweep",text[-12000:],fp)
    except Exception as e:
        write_runtime_log(pid,"scheduler",f"sweep failed: {e}")

def scheduler():
    last_dev={}
    last_fast={}
    while True:
        now=time.time()
        for f in list(PROJECTS.glob("*/project.json")):
            try:
                cfg=json.loads(f.read_text()); pid=cfg["id"]
                if cfg.get("mode") in ("development","post-deploy"):
                    if now-last_fast.get(pid,0)>=FAST_WATCH_SECONDS:
                        last_fast[pid]=now; threading.Thread(target=run_sweep,args=(pid,False,True),daemon=True).start()
                    if now-last_dev.get(pid,0)>=DEV_SWEEP_SECONDS:
                        last_dev[pid]=now; threading.Thread(target=run_sweep,args=(pid,False,False),daemon=True).start()
            except Exception as e:
                pass
        time.sleep(5)

@app.on_event("startup")
def start_scheduler():
    threading.Thread(target=scheduler,daemon=True).start()

def page(body,title="Phoenix Dev Agent"):
    return f"""<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>
<title>{html.escape(title)}</title><style>
body{{font-family:system-ui;background:#101215;color:#e8ecef;margin:0}}header{{padding:20px 28px;background:#171a1f;border-bottom:1px solid #2a3038}}
main{{max-width:1200px;margin:auto;padding:24px}}.card{{background:#171a1f;border:1px solid #2a3038;border-radius:12px;padding:18px;margin:14px 0}}
a{{color:#82b7ff}}button,input,select{{padding:8px 10px;margin:4px;background:#20252c;color:#fff;border:1px solid #3b4552;border-radius:7px}}
table{{width:100%;border-collapse:collapse}}th,td{{padding:9px;border-bottom:1px solid #2a3038;text-align:left}}pre{{white-space:pre-wrap;background:#0d0f12;padding:12px;border-radius:8px;max-height:600px;overflow:auto}}
.ok{{color:#76d275}}.bad{{color:#ff7979}}.muted{{color:#9aa4ae}}</style></head><body>
<header><b>Phoenix Dev Agent</b> <span class=muted>v{APP_VERSION}</span></header><main>{body}</main></body></html>"""

@app.get("/",response_class=HTMLResponse)
def home(_:bool=Depends(auth)):
    rows=[]
    for f in sorted(PROJECTS.glob("*/project.json")):
        try:
            c=json.loads(f.read_text()); st=broker("GET",f"/project/{c['id']}/status")
            rows.append(f"<tr><td><a href='/project/{c['id']}'>{html.escape(c['display_name'])}</a></td><td>{html.escape(c['container'])}</td><td>{html.escape(c['mode'])}</td><td class={'ok' if st.get('running') else 'bad'}>{'Running' if st.get('running') else 'Stopped'}</td><td>{html.escape(str(st.get('image','')))}</td></tr>")
        except Exception as e: pass
    body=f"""<div class=card><h2>Registered projects</h2><table><tr><th>Project</th><th>Container</th><th>Mode</th><th>Status</th><th>Image</th></tr>{''.join(rows) or '<tr><td colspan=5>No projects registered.</td></tr>'}</table></div>
<div class=card><h2>Register existing Unraid app</h2>
<form method=post action=/ui/register>
<input name=container placeholder='Existing container name' required>
<input name=project_id placeholder='Project ID (optional)'>
<input name=display_name placeholder='Display name (optional)'>
<input name=source_host_path placeholder='/mnt/user/... existing source (optional)' size=45>
<input name=installer_host_path placeholder='/mnt/user/... installer/script (optional)' size=45>
<button>Register only this app</button></form>
<p class=muted>Registration never enrolls other containers. Deployment actions start disabled until their hooks are verified.</p></div>"""
    return page(body)

@app.post("/ui/register",response_class=HTMLResponse)
async def ui_register(request:Request,_:bool=Depends(auth)):
    form=await request.form()
    req=RegisterRequest(container=str(form.get("container","")),project_id=str(form.get("project_id") or "") or None,
        display_name=str(form.get("display_name") or "") or None,source_host_path=str(form.get("source_host_path") or "") or None,
        installer_host_path=str(form.get("installer_host_path") or "") or None)
    try:
        register(req,True)
        return HTMLResponse("<meta http-equiv='refresh' content='0;url=/'>")
    except Exception as e:
        return page(f"<div class=card><h2>Registration failed</h2><pre>{html.escape(str(e))}</pre><a href='/'>Back</a></div>")

@app.get("/project/{pid}",response_class=HTMLResponse)
def project_page(pid:str,_:bool=Depends(auth)):
    c=load_project(pid); st=broker("GET",f"/project/{pid}/status")
    incs=[]
    d=INCIDENTS/pid
    if d.exists():
        for f in sorted(d.glob("*.json"),reverse=True)[:10]:
            try:
                x=json.loads(f.read_text()); incs.append(f"<tr><td>{x['id']}</td><td>{x['severity']}</td><td>{x['status']}</td><td>{html.escape(x['summary'])}</td><td>{x.get('occurrences',1)}</td></tr>")
            except: pass
    body=f"""<p><a href='/'>← Projects</a></p><div class=card><h2>{html.escape(c['display_name'])}</h2>
<p>Container: <b>{html.escape(c['container'])}</b> · Runtime: <b class={'ok' if st.get('running') else 'bad'}>{'Running' if st.get('running') else 'Stopped'}</b> · Mode: <b>{html.escape(c['mode'])}</b></p>
<p>10-minute sweep: {html.escape(str(c.get('last_sweep') or 'not yet'))} · Fast watcher: {html.escape(str(c.get('last_fast_watch') or 'not yet'))}</p>
<p><a href='/project/{pid}/logs'>Live/recent logs</a></p>
<form method=post action='/ui/project/{pid}/sweep'><button>Run log sweep now</button></form></div>
<div class=card><h3>Automation</h3>
<form method=post action='/ui/project/{pid}/policy'>
<label>Mode <select name=mode><option {'selected' if c['mode']=='normal' else ''}>normal</option><option {'selected' if c['mode']=='development' else ''}>development</option><option {'selected' if c['mode']=='post-deploy' else ''}>post-deploy</option></select></label><br>
<label><input type=checkbox name=auto_diagnose {'checked' if c['policy'].get('auto_diagnose') else ''}> Auto diagnose incidents with Codex</label><br>
<label><input type=checkbox name=auto_test {'checked' if c['policy'].get('auto_test') else ''}> Auto test after successful Codex change</label><br>
<label><input type=checkbox name=auto_build {'checked' if c['policy'].get('auto_build') else ''}> Auto build after successful Codex change</label><br>
<label><input type=checkbox name=auto_deploy {'checked' if c['policy'].get('auto_deploy') else ''}> Auto deploy (only if deploy action is also enabled)</label><hr>
<b>Permitted project actions</b><br>
<label><input type=checkbox name=action_test {'checked' if c['actions'].get('test') else ''}> Test</label>
<label><input type=checkbox name=action_build {'checked' if c['actions'].get('build') else ''}> Build</label>
<label><input type=checkbox name=action_deploy {'checked' if c['actions'].get('deploy') else ''}> Deploy production</label>
<label><input type=checkbox name=action_rollback {'checked' if c['actions'].get('rollback') else ''}> Rollback</label><br>
<button>Save policy</button></form>
<form method=post action='/ui/project/{pid}/bootstrap'><button>Bootstrap from existing installer/source with Codex</button></form>
<form method=post action='/ui/project/{pid}/action/test'><button>Run test</button></form>
<form method=post action='/ui/project/{pid}/action/build'><button>Build candidate</button></form>
<form method=post action='/ui/project/{pid}/action/deploy'><button>Deploy production</button></form>
<form method=post action='/ui/project/{pid}/action/rollback'><button>Rollback</button></form>
<p class=muted>Production deploy remains blocked unless this project's deploy action is explicitly enabled.</p></div>
<div class=card><h3>Application logs</h3><pre>{html.escape(json.dumps(c.get('log_files',[]),indent=2))}</pre></div>
<div class=card><h3>Incidents</h3><table><tr><th>ID</th><th>Severity</th><th>Status</th><th>Summary</th><th>Count</th></tr>{''.join(incs) or '<tr><td colspan=5>None</td></tr>'}</table></div>"""
    return page(body,c["display_name"])

@app.get("/project/{pid}/logs",response_class=HTMLResponse)
def logs_page(pid:str,_:bool=Depends(auth)):
    load_project(pid); x=broker("GET",f"/project/{pid}/logs",params={"tail":500})
    text="\n".join(x.get("combined",[]))
    return page(f"<p><a href='/project/{pid}'>← Project</a></p><div class=card><h2>Recent logs</h2><pre>{html.escape(text)}</pre></div>","Logs")

@app.get("/api/codex/version")
def codex_version(_:bool=Depends(auth)):
    out={"installed":False,"authenticated":False}
    try:
        r=subprocess.run(["codex","--version"],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
        out.update({"installed":r.returncode==0,"version":r.stdout.strip()})
        q=subprocess.run(["codex","login","status"],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
        out["login_status"]=q.stdout.strip()
        out["authenticated"]=q.returncode==0 and "logged in" in q.stdout.lower() and "not logged in" not in q.stdout.lower()
        return out
    except Exception as e:
        out["error"]=str(e); return out

@app.get("/api/projects/{pid}/context")
def project_context(pid:str, _:bool=Depends(auth)):
    c=load_project(pid)
    runtime=broker("GET",f"/project/{pid}/status")
    logs=broker("GET",f"/project/{pid}/logs",params={"tail":250})
    state_file=WORKSPACE/pid/"PROJECT_STATE.md"
    state=state_file.read_text(errors="replace")[-20000:] if state_file.exists() else ""
    incidents=[]
    d=INCIDENTS/pid
    if d.exists():
        for f in sorted(d.glob("*.json"),reverse=True)[:10]:
            try:
                x=json.loads(f.read_text())
                incidents.append({k:x.get(k) for k in ("id","severity","summary","status","occurrences","first_seen","last_seen")})
            except: pass
    return {
        "project_id":pid,
        "display_name":c["display_name"],
        "mode":c["mode"],
        "runtime":runtime,
        "project_state":state,
        "recent_incidents":incidents,
        "recent_logs":logs.get("combined",[])[-250:],
        "generated_at":utcnow(),
    }
