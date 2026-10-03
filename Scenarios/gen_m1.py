#!/usr/bin/env python3
# Генератор сценариев приёмки M1 (Kaban Analyst Bot). Источник истины — этот файл; JSON пересобирается: python3 gen_m1.py
import json, os
T0="2026-10-04T08:00:00.000Z"
def cmd(name, **f): return {"protocolVersion":1,"commandId":"00000000-0000-4000-8000-%012d"%cmd.n,"command":{name:f}} if not cmd.__dict__.__setitem__('n',cmd.n+1) else None
cmd.n=1
def st(status, reason=None):
    d={"status":status}
    if reason: d["reason"]=reason
    return d
def task(id, stage, s, **kw): return {"id":id,"projectId":kw.pop("projectId","p-kaban"),"stage":stage,"state":s,**kw}
def tr(task, fs, ts, frm, to, by="daemon"): return {"type":"taskTransitioned","data":{"taskId":task,"fromStage":fs,"toStage":ts,"from":frm,"to":to,"by":by}}
S=[]
def SF(path, blob, rule="pattern", size=212, pattern=".env*"):
    d={"path":path,"rule":rule,"sizeBytes":size,"blob":blob}
    if rule=="pattern": d["pattern"]=pattern
    return d
def sc(id, uc, title, given, steps): S.append({"id":id,"uc":uc,"title":title,"given":given,"steps":steps})
G=lambda tasks, **kw: {"clock":T0,"pipeline":kw.pop("pipeline","base"),"tasks":tasks,**kw}

# --- Сквозной путь и WIP
sc("M1-FLOW-01",["UC-03","UC-05","1.1"],"Задача проходит Dev→Test по зелёным гейтам, счётчик попыток сбрасывается",
 G([task("t-1","backlog",st("queued"))]),[
 {"command":cmd("moveTask",taskId="t-1",stage="dev"),"then":{"tasks":{"t-1":{"stage":"dev","state":st("queued"),"attempt":1,"autoRuns":0}}}},
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running"),"attempt":1,"autoRuns":1}},"runsStarted":1}},
 {"driver":{"task":"t-1","end":"completed","gates":"green"},"then":{"tasks":{"t-1":{"stage":"test","state":st("queued"),"attempt":1,"autoRuns":1}},
   "events":[tr("t-1","dev","dev",st("running"),st("gating"),by="agent"),tr("t-1","dev","test",st("gating"),st("queued"))]}}])
sc("M1-WIP-01",["1.2","UC-03"],"WIP стадии Dev=3: четвёртая задача ждёт с подписью «ждёт места»",
 G([task(f"t-{i}","dev",st("queued")) for i in range(1,5)]),[
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running")},"t-2":{"state":st("running")},"t-3":{"state":st("running")},"t-4":{"state":st("queued","wip_full")}},"runsStarted":3}}])
sc("M1-WIP-02",["1.2","UC-06"],"waiting_human не занимает слот: вопрос агента освобождает место для следующей задачи",
 G([task("t-1","dev",st("running"),runId="r-1"),task("t-2","dev",st("running"),runId="r-2"),task("t-3","dev",st("running"),runId="r-3"),task("t-4","dev",st("queued","wip_full"))]),[
 {"driver":{"task":"t-1","end":"asked_human","question":"Какой формат даты?"},"then":{"tasks":{"t-1":{"state":st("waiting_human","question")}},"events":[{"type":"humanRequested","data":{"taskId":"t-1"}}]}},
 {"tick":"scheduler","then":{"tasks":{"t-4":{"state":st("running")}}}},
 {"command":cmd("answerHuman",taskId="t-1",text="ISO 8601"),"then":{"tasks":{"t-1":{"state":st("queued","wip_full"),"autoRuns":0}},"note":"ответ человека сбрасывает autoRuns; попытки стадии не меняются"}}])
sc("M1-WIP-03",["1.2"],"retry_wait держит слот стадии",
 G([task("t-1","test",st("running"),runId="r-1"),task("t-2","test",st("running"),runId="r-2"),task("t-3","test",st("queued"))]),[
 {"driver":{"task":"t-1","end":"crash"},"then":{"tasks":{"t-1":{"state":st("retry_wait","crash"),"attempt":2}}}},
 {"tick":"scheduler","then":{"tasks":{"t-3":{"state":st("queued","wip_full")}},"runsStarted":0}}])

# --- Ретраи
sc("M1-RETRY-01",["1.4","UC-10"],"3 попытки с паузами 30 с и 2 мин, затем retries_exhausted",
 G([task("t-1","dev",st("running"),runId="r-1",attempt=1,autoRuns=1)]),[
 {"driver":{"task":"t-1","end":"crash"},"then":{"tasks":{"t-1":{"state":st("retry_wait","crash"),"attempt":2,"retryAt":"+30s"}}}},
 {"advance":"29s","tick":"scheduler","then":{"tasks":{"t-1":{"state":st("retry_wait","crash")}}}},
 {"advance":"1s","tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running"),"attempt":2,"autoRuns":2}}}},
 {"driver":{"task":"t-1","end":"stall_timeout"},"then":{"tasks":{"t-1":{"state":st("retry_wait","stall_timeout"),"attempt":3,"retryAt":"+2m"}}}},
 {"advance":"2m","tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running"),"attempt":3,"autoRuns":3}}}},
 {"driver":{"task":"t-1","end":"gate_failed"},"then":{"tasks":{"t-1":{"state":st("waiting_human","retries_exhausted"),"attempt":3}}}}])
sc("M1-RETRY-02",["1.4"],"Счётчик попыток считается на заход в стадию",
 G([task("t-1","dev",st("retry_wait","crash"),attempt=2,autoRuns=1,retryAt=T0)]),[
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running"),"attempt":2}}}},
 {"driver":{"task":"t-1","end":"completed","gates":"green"},"then":{"tasks":{"t-1":{"stage":"test","state":st("queued"),"attempt":1}}}},
 {"tick":"scheduler"},
 {"driver":{"task":"t-1","end":"returned","to":"dev"},"then":{"tasks":{"t-1":{"stage":"dev","state":st("queued"),"attempt":1,"bounces":{"test_dev":1}}}}}])
sc("M1-RETRY-03",["1.4","UC-10"],"После gate_failed повтор идёт в том же клоне, после crash состояние сохраняется в refs/kaban/wip и клон откатывается",
 G([task("t-1","dev",st("running"),runId="r-1")]),[
 {"driver":{"task":"t-1","end":"gate_failed"},"then":{"tasks":{"t-1":{"state":st("retry_wait","gate_failed")}},"clone":{"t-1":"kept"}}},
 {"advance":"30s","tick":"scheduler"},
 {"driver":{"task":"t-1","end":"crash","dirty":True},"then":{"tasks":{"t-1":{"state":st("retry_wait","crash")}},"clone":{"t-1":"reset"},"refs":["refs/kaban/wip/<runId>"]}}])
for reason,flag in [("rate_limit",{"level":"mac","flag":"rate_limited","step":1,"until":"+15m"}),("runner_auth",{"level":"mac","flag":"runner_unavailable","reason":"runner_auth"}),("daemon_restart",None)]:
    then={"tasks":{"t-1":{"state":st("retry_wait",reason),"attempt":1,"autoRuns":0}}}
    if flag: then["flags"]=[flag]
    sc(f"M1-NOCHARGE-{reason}",["1.4","UC-09","UC-20"],f"{reason}: попытка и max_runs_per_task не списываются",
     G([task("t-1","dev",st("running"),runId="r-1",attempt=1,autoRuns=1)]),[{"driver":{"task":"t-1","end":reason},"then":then,"note":"autoRuns возвращается к значению до запуска"}])
sc("M1-RATE-01",["UC-09 а"],"Cooldown rate-limit растёт 15→30→60 мин, снимается вручную",
 G([task("t-1","dev",st("running"),runId="r-1")]),[
 {"driver":{"task":"t-1","end":"rate_limit"},"then":{"flags":[{"level":"mac","flag":"rate_limited","step":1,"until":"+15m"}]}},
 {"advance":"15m","tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running")}},"flags":[]}},
 {"driver":{"task":"t-1","end":"rate_limit"},"then":{"flags":[{"level":"mac","flag":"rate_limited","step":2,"until":"+30m"}]}},
 {"command":cmd("resumeAfterRateLimit"),"then":{"flags":[]}},
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running")}}}}])
sc("M1-SILENT-01",["1.4"],"Молчаливый выход: попытка не списывается, проба не чаще раза в 10 минут на модель",
 G([task("t-1","dev",st("running"),runId="r-1",model="claude-opus"),task("t-2","test",st("running"),runId="r-2",model="claude-opus")]),[
 {"driver":{"task":"t-1","end":"silent_exit"},"then":{"tasks":{"t-1":{"state":st("retry_wait","silent_exit"),"attempt":1}},"probes":[{"model":"claude-opus","at":"+0s"}]}},
 {"advance":"3m","driver":{"task":"t-2","end":"silent_exit"},"then":{"probes":[],"note":"вторая проба по той же модели не раньше +10m от первой"}}])

# --- Лимит запусков
sc("M1-RUNLIMIT-01",["1.4","F27"],"max_runs_per_task=12: тринадцатый автоматический запуск не стартует",
 G([task("t-1","dev",st("queued"),autoRuns=12)]),[
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("waiting_human","run_limit")}},"runsStarted":0}}])
sc("M1-RUNLIMIT-02",["1.4","F27"],"Действие человека сбрасывает счётчик автоматических запусков",
 G([task("t-1","dev",st("waiting_human","run_limit"),autoRuns=12)]),[
 {"command":cmd("retryStage",taskId="t-1"),"then":{"tasks":{"t-1":{"state":st("queued"),"autoRuns":0,"attempt":1}}}},
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running"),"autoRuns":1}}}}])

# --- Возвраты и max_waiting_human
sc("M1-BOUNCE-01",["1.3","UC-07"],"Лимит возвратов Test→Dev = 3",
 G([task("t-1","test",st("running"),runId="r-1",bounces={"test_dev":3})]),[
 {"driver":{"task":"t-1","end":"returned","to":"dev"},"then":{"tasks":{"t-1":{"stage":"test","state":st("waiting_human","bounce_limit")}}}}])
sc("M1-BOUNCE-02",["1.3"],"Общий потолок возвратов 5 срабатывает раньше лимита пары",
 G([task("t-1","ai_review",st("running"),runId="r-1",bounces={"test_dev":3,"ai_review_dev":1})]),[
 {"driver":{"task":"t-1","end":"returned","to":"dev"},"then":{"tasks":{"t-1":{"state":st("waiting_human","bounce_limit")}}}}])
sc("M1-MAXWH-01",["1.2","UC-06"],"max_waiting_human=3 останавливает приём новых задач проекта, ревью не считается",
 G([task("t-1","dev",st("waiting_human","question")),task("t-2","test",st("waiting_human","retries_exhausted")),task("t-3","human_review",st("waiting_human","review")),task("t-4","dev",st("running"),runId="r-4"),task("t-5","dev",st("queued"))]),[
 {"tick":"scheduler","then":{"flags":[],"tasks":{"t-5":{"state":st("running")}},"note":"ожидающих без ревью 2 < 3"}},
 {"driver":{"task":"t-4","end":"asked_human"},"then":{"flags":[{"level":"project","flag":"intake_paused","projectId":"p-kaban"}]}},
 {"command":cmd("answerHuman",taskId="t-1",text="ok"),"then":{"flags":[]}}])

# --- Флаги и очередь
sc("M1-MODELFLAG-01",["UC-09 в","1.1"],"Задача на модели с флагом ждёт в queued и не держит очередь",
 G([task("t-1","dev",st("queued"),modelOverride="claude-opus"),task("t-2","dev",st("queued"))],modelFlags=[{"modelId":"claude-opus","reason":"unavailable","requested":"claude-opus","since":T0}]),[
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("queued","model_flag")},"t-2":{"state":st("running")}}}},
 {"command":cmd("clearModelFlag",modelId="claude-opus"),"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running")}}}}])
sc("M1-POOL-01",["UC-09 б","1.6"],"Исчерпан пул Om: встают только стадии на Om-моделях, composer-* работают",
 G([task("t-1","dev",st("queued")),task("t-2","test",st("queued"))],stageModels={"dev":"claude-opus","test":"composer-2"},flags=[{"level":"pool","flag":"usage_exhausted","pool":"om","resetsAt":"2026-10-17T00:00:00.000Z"}]),[
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("queued","quota_om")},"t-2":{"state":st("running")}}}}])
sc("M1-POOL-02",["UC-09 б"],"Пул неизвестен: встаёт весь Мак, текущие запуски доигрывают",
 G([task("t-1","dev",st("running"),runId="r-1"),task("t-2","test",st("queued"))],flags=[{"level":"mac","flag":"usage_exhausted"}]),[
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running")},"t-2":{"state":st("queued")}},"runsStarted":0,"runsKilled":0}}])
sc("M1-PIPE-01",["UC-23","1.5"],"Стадия без модели: проект pipeline_invalid, ничего нового не стартует, идущий запуск доигрывает",
 G([task("t-1","dev",st("running"),runId="r-1"),task("t-2","dev",st("queued"))]),[
 {"pipelineApplied":{"stages":{"test":{"model":None}}},"then":{"flags":[{"level":"project","flag":"unavailable","projectId":"p-kaban","reason":"pipeline_invalid"}],"runsKilled":0}},
 {"tick":"scheduler","then":{"tasks":{"t-2":{"state":st("queued")}},"runsStarted":0}},
 {"pipelineApplied":{"stages":{"test":{"model":"composer-2"}}},"tick":"scheduler","then":{"flags":[],"tasks":{"t-2":{"state":st("running")}}}}])
sc("M1-PIPE-02",["UC-23","1.5"],"validatePipeline: стадия без модели или auto — ошибка, MCP вне белого списка — предупреждение",
 G([]),[
 {"command":cmd("validatePipeline",projectId="p-kaban",content="<pipeline: dev.model = auto, test.mcp = [github] при пустом белом списке>"),
  "then":{"ephemeral":[{"type":"pipelineDraftValidated","data":{"issues":[{"severity":"error","path":"stages.dev.model","stageId":"dev","code":"model_auto_forbidden"},{"severity":"warning","path":"stages.test.mcp[0]","stageId":"test","code":"mcp_not_allowlisted"}]}}]}}])
sc("M1-PAUSE-01",["UC-11"],"Пауза задачи останавливает запуск и освобождает слот, продолжение ставит в очередь",
 G([task("t-1","dev",st("running"),runId="r-1",attempt=1,autoRuns=1)]),[
 {"command":cmd("pauseTask",taskId="t-1"),"then":{"tasks":{"t-1":{"state":st("paused")}},"runsKilled":1,"runEnd":"paused_by_human"}},
 {"command":cmd("resumeTask",taskId="t-1"),"then":{"tasks":{"t-1":{"state":st("queued"),"attempt":1,"autoRuns":0}}}}])
sc("M1-MACPAUSE-01",["UC-11"],"Пауза всего Мака: новые запуски не стартуют, текущие доигрывают",
 G([task("t-1","dev",st("running"),runId="r-1"),task("t-2","dev",st("queued"))]),[
 {"command":cmd("pauseAll"),"tick":"scheduler","then":{"flags":[{"level":"mac","flag":"paused"}],"runsStarted":0,"runsKilled":0}},
 {"command":cmd("resumeAll"),"tick":"scheduler","then":{"flags":[],"tasks":{"t-2":{"state":st("running")}}}}])
sc("M1-CANCEL-01",["UC-07","UC-11"],"Отмена задачи с сохранением ветки",
 G([task("t-1","dev",st("running"),runId="r-1")]),[
 {"command":cmd("cancelTask",taskId="t-1",keepBranch=True),"then":{"tasks":{"t-1":{"state":st("cancelled")}},"runsKilled":1,"refs":["kaban/archive/t-1"]}}])
sc("M1-FAIR-01",["UC-14","F19"],"Общий потолок 4 делится между двумя проектами с равным весом",
 G([task(f"a-{i}","dev",st("queued"),projectId="p-a") for i in range(1,5)]+[task(f"b-{i}","dev",st("queued"),projectId="p-b") for i in range(1,5)],maxConcurrentRuns=4),[
 {"tick":"scheduler","then":{"runsStarted":4,"runningByProject":{"p-a":2,"p-b":2}}}])

# --- Подмена, git, подозрительные файлы
sc("M1-SUBST-01",["UC-22"],"Cursor подменил модель: задача в model_substituted, попытка не списана, флаг на модели",
 G([task("t-1","dev",st("running"),runId="r-1",attempt=1,autoRuns=1),task("t-2","dev",st("queued"))],stageModels={"dev":"claude-opus"}),[
 {"driver":{"task":"t-1","end":"model_substituted","actual":"claude-sonnet"},"then":{"tasks":{"t-1":{"state":st("waiting_human","model_substituted"),"attempt":1,"autoRuns":0}},
   "ephemeral":[{"type":"modelFlagsChanged","data":[{"modelId":"claude-opus","reason":"substituted","requested":"claude-opus","actual":"claude-sonnet"}]}]}},
 {"tick":"scheduler","then":{"tasks":{"t-2":{"state":st("queued","model_flag")}}}}])
sc("M1-GIT-01",["UC-17"],"Пятый отказ git за запуск останавливает запуск",
 G([task("t-1","dev",st("running"),runId="r-1")]),[
 {"driver":{"task":"t-1","gitDenied":4},"then":{"tasks":{"t-1":{"state":st("running")}}}},
 {"driver":{"task":"t-1","gitDenied":1},"then":{"tasks":{"t-1":{"state":st("waiting_human","git_denials")}},"runsKilled":1}}])
sc("M1-SUSP-01",["UC-25","F29"],"Подозрительные файлы в diff ветки: waiting_human, попытка не списана, принятый набор больше не срабатывает",
 G([task("t-1","dev",st("running"),runId="r-1",attempt=1)]),[
 {"driver":{"task":"t-1","end":"completed","gates":"green","branchFiles":[{"path":".env.local","blob":"a1b2c3","sizeBytes":212},{"path":".env.example","blob":"e0e0e0","sizeBytes":90}]},
  "then":{"tasks":{"t-1":{"stage":"dev","state":st("waiting_human","suspicious_files"),"attempt":1,"suspiciousFiles":[SF(".env.local","a1b2c3")]}},"events":[{"type":"suspiciousFilesFound","data":{"taskId":"t-1","files":[SF(".env.local","a1b2c3")]}}],"note":".env.example в allow и не попадает"}},
 {"command":cmd("acceptSuspiciousFiles",taskId="t-1",files=[{"path":".env.local","blob":"a1b2c3"}]),"then":{"events":[{"type":"suspiciousFilesAccepted","data":{"taskId":"t-1","by":"human"}}],"tasks":{"t-1":{"stage":"test","state":st("queued"),"attempt":1,"suspiciousFiles":[]}},"runsStarted":0,"note":"демон перепроверил diff, задача сделала отложенный переход без нового запуска"}},
 {"note":"если blob .env.local изменится, проверка сработает снова (M1-SUSP-02)"}])
sc("M1-SUSP-02",["UC-25"],"Изменённый принятый файл и файл больше 5 МБ срабатывают снова",
 G([task("t-1","dev",st("running"),runId="r-1")],acceptedFiles={"t-1":[{"path":".env.local","blob":"a1b2c3"}]}),[
 {"driver":{"task":"t-1","end":"completed","gates":"green","branchFiles":[{"path":".env.local","blob":"ffff01","sizeBytes":230},{"path":"assets/dump.bin","blob":"d4e5f6","sizeBytes":7340032}]},
  "then":{"tasks":{"t-1":{"state":st("waiting_human","suspicious_files"),"suspiciousFiles":[SF(".env.local","ffff01",size=230),SF("assets/dump.bin","d4e5f6",rule="size",size=7340032)]}},"events":[{"type":"suspiciousFilesFound","data":{"files":[SF(".env.local","ffff01",size=230),SF("assets/dump.bin","d4e5f6",rule="size",size=7340032)]}}]}}])

sc("M1-SUSP-03",["UC-25"],"acceptSuspiciousFiles с устаревшим набором отклоняется, ничего не принимается",
 G([task("t-1","dev",st("waiting_human","suspicious_files"),suspiciousFiles=[SF(".env.local","ffff01",size=230)])]),[
 {"command":cmd("acceptSuspiciousFiles",taskId="t-1",files=[{"path":".env.local","blob":"a1b2c3"}]),"then":{"commandError":"stale_suspicious_files","tasks":{"t-1":{"state":st("waiting_human","suspicious_files")}},"events":[]}}])
sc("M1-SUSP-04",["UC-25","F23"],"«Попросить убрать» (answerHuman) набор не принимает: новый запуск, после гейтов проверка заново",
 G([task("t-1","dev",st("waiting_human","suspicious_files"),suspiciousFiles=[SF(".env.local","a1b2c3")])]),[
 {"command":cmd("answerHuman",taskId="t-1",text="убери .env.local из ветки"),"then":{"tasks":{"t-1":{"stage":"dev","state":st("queued")}},"acceptedFiles":{"t-1":[]}}},
 {"tick":"scheduler","then":{"tasks":{"t-1":{"state":st("running")}}}},
 {"driver":{"task":"t-1","end":"completed","gates":"green","branchFiles":[{"path":".env.local","blob":"a1b2c3","sizeBytes":212}]},"then":{"tasks":{"t-1":{"state":st("waiting_human","suspicious_files"),"suspiciousFiles":[SF(".env.local","a1b2c3")]}},"events":[{"type":"suspiciousFilesFound","data":{"files":[SF(".env.local","a1b2c3")]}}]}}])
sc("M1-SUSP-05",["UC-25"],"Повтор стадии принимает текущий набор",
 G([task("t-1","dev",st("waiting_human","suspicious_files"),suspiciousFiles=[SF(".env.local","a1b2c3")])]),[
 {"command":cmd("retryStage",taskId="t-1"),"then":{"events":[{"type":"suspiciousFilesAccepted","data":{"taskId":"t-1"}}],"tasks":{"t-1":{"state":st("queued"),"suspiciousFiles":[]}}}}])


# taskUpdated: на проводе всегда полная TaskCard (арх. §5). В data кладём полную карточку для проигрывания
# в KabanBoardCore, а в check перечисляем поля, которые сверяет тест демона (остальные заполнены по умолчанию).
import datetime as _dt
CARD={"stage":"stageId","state":"state","attempt":"attempt","autoRuns":"runsSinceHuman","bounces":"bounceByReason",
      "suspiciousFiles":"suspiciousFiles","retryAt":"retryAt","priority":"priority","model":"model","title":"title",
      "branch":"branch","projectId":"projectId","overlapsWith":"overlapsWith"}
def _t(x): return _dt.datetime.strptime(x,"%Y-%m-%dT%H:%M:%S.%fZ")
def _iso(d): return d.strftime("%Y-%m-%dT%H:%M:%S.")+"%03dZ"%(d.microsecond//1000)
def _dur(x):
    n=int(x[:-1].lstrip("+")); return _dt.timedelta(**{{"s":"seconds","m":"minutes","h":"hours"}[x[-1]]:n})
def _card(t, now):
    c={"id":t["id"],"projectId":"p-kaban","title":"Задача "+t["id"],"stageId":"backlog","state":{"status":"queued"},
       "priority":0,"branch":"kaban/"+t["id"],"attempt":0,"maxAttempts":3,"runsSinceHuman":0,"bounceByReason":{},
       "overlapsWith":[],"unusedGitGrants":0,"model":None,"retryAt":None,"suspiciousFiles":[],"updatedAt":_iso(now)}
    for k,v in t.items():
        if k in CARD: c[CARD[k]]=v
    return c
def add_task_updated(s):
    now=_t(s["given"].get("clock",T0))
    cards={t["id"]:_card(t,now) for t in s["given"].get("tasks",[])}
    for step in s["steps"]:
        if "advance" in step: now=now+_dur(step["advance"])
        th=step.get("then")
        if not th or "commandError" in th or "tasks" not in th: continue
        ups=[]
        for tid,exp in th["tasks"].items():
            c=cards.setdefault(tid,_card({"id":tid},now))
            ch={}
            for k,v in exp.items():
                if k not in CARD: continue
                f=CARD[k]
                if k=="retryAt" and isinstance(v,str) and v.startswith("+"): v=_iso(now+_dur(v))
                if c.get(f)!=v: ch[f]=v
            if "state" in ch and ch["state"].get("status")!="retry_wait" and "retryAt" not in ch and c.get("retryAt"): ch["retryAt"]=None
            if not ch: continue
            c.update(ch); c["updatedAt"]=_iso(now)
            ev={"type":"taskUpdated","data":dict(c),"check":["id"]+sorted(ch)}
            if "command" in step: ev["commandId"]=step["command"]["commandId"]
            ups.append(ev)
        if ups: th["events"]=th.get("events",[])+ups
for s_ in S: add_task_updated(s_)
os.makedirs("M1",exist_ok=True)
for f in os.listdir("M1"): os.remove(os.path.join("M1",f))
for s in S:
    json.dump(s,open(f"M1/{s['id']}.json","w",encoding="utf-8"),ensure_ascii=False,indent=2,sort_keys=False)
print(len(S),"scenarios")
