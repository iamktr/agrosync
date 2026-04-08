"""
AgroSync MCP Server
====================
Standalone MCP server owning ALL tool implementations for AgroSync.
Gemini 2.5 Flash agents in app.py connect as MCP client via stdio.

Tools (8): google_calendar, google_tasks, google_maps,
           alloydb_query, alloydb_analytics, alloydb_manage_task,
           alloydb_manage_farmer, alloydb_notes

Run:  python mcp_server.py
Requires:  pip install mcp pg8000 sqlalchemy
"""
import os, re, json, time, asyncio, urllib.parse, urllib.request, urllib.error
from datetime import datetime, timedelta
from typing import Any, Optional
from mcp.server import Server
from mcp.types import Tool, TextContent
import mcp.server.stdio
from sqlalchemy import create_engine, text

MAPS_API_KEY = os.getenv("MAPS_API_KEY", "")
DB_URL = (f"postgresql+pg8000://{os.getenv('DB_USER','')}:{os.getenv('DB_PASS','')}"
          f"@{os.getenv('DB_HOST','localhost')}/{os.getenv('DB_NAME','agrosync')}")
engine = None
def get_engine():
    global engine
    if engine is None:
        engine = create_engine(
            DB_URL,
            pool_pre_ping=True,
            pool_size=3,
            max_overflow=5,
            pool_timeout=10,
            pool_recycle=300,
            connect_args={"timeout": 8},
        )
    return engine

try:
    get_engine()
except Exception as e:
    print(f"[MCP] DB engine deferred: {e}")

def init_db():
    with get_engine().begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS farmers (farmer_id SERIAL PRIMARY KEY, name VARCHAR(120) NOT NULL, gender VARCHAR(10), contact VARCHAR(60), city VARCHAR(100), country VARCHAR(100), sub_region VARCHAR(100));
            CREATE TABLE IF NOT EXISTS inventory (item_id SERIAL PRIMARY KEY, farmer_id INTEGER REFERENCES farmers(farmer_id) ON DELETE CASCADE, crop_name VARCHAR(100), stock NUMERIC(12,2) DEFAULT 0, harvest_date DATE, status VARCHAR(30) DEFAULT 'In-Field');
            CREATE TABLE IF NOT EXISTS tasks (task_id SERIAL PRIMARY KEY, farmer_id INTEGER REFERENCES farmers(farmer_id) ON DELETE CASCADE, title VARCHAR(200), description TEXT, status VARCHAR(30) DEFAULT 'Pending', priority VARCHAR(10) DEFAULT 'Medium', due_date DATE);
            CREATE TABLE IF NOT EXISTS notes (note_id SERIAL PRIMARY KEY, farmer_id INTEGER REFERENCES farmers(farmer_id) ON DELETE SET NULL, title VARCHAR(200) NOT NULL, content TEXT NOT NULL, tags VARCHAR(200), created_at TIMESTAMP DEFAULT NOW(), updated_at TIMESTAMP DEFAULT NOW());
        """))
try:
    init_db()
except Exception as e:
    print(f"[MCP] init_db skipped: {e}")

server = Server("agrosync-mcp-server")

TOOLS = [
    Tool(name="google_calendar", description="Manage Google Calendar events (list_events, create_event, update_event, delete_event). Requires access_token. For list_events you can pass time_min/time_max as ISO 8601 strings to filter by date range.",
         inputSchema={"type":"object","properties":{"action":{"type":"string","enum":["list_events","create_event","update_event","delete_event"]},"access_token":{"type":"string"},"title":{"type":"string"},"start_datetime":{"type":"string"},"end_datetime":{"type":"string"},"description":{"type":"string"},"location":{"type":"string"},"add_meet_link":{"type":"boolean"},"event_id":{"type":"string"},"max_results":{"type":"integer"},"time_min":{"type":"string","description":"ISO 8601 datetime for list_events lower bound"},"time_max":{"type":"string","description":"ISO 8601 datetime for list_events upper bound"}},"required":["action","access_token"]}),
    Tool(name="google_tasks", description="Manage Google Tasks (list_tasks, create_task, update_task, delete_task). Requires access_token.",
         inputSchema={"type":"object","properties":{"action":{"type":"string","enum":["list_tasks","create_task","update_task","delete_task"]},"access_token":{"type":"string"},"title":{"type":"string"},"notes":{"type":"string"},"due_date":{"type":"string"},"task_id":{"type":"string"},"status":{"type":"string"}},"required":["action","access_token"]}),
    Tool(name="google_maps", description="Google Maps: embed_map, search_location, directions (origin+destination), nearby_search (location+keyword+radius_m).",
         inputSchema={"type":"object","properties":{"action":{"type":"string","enum":["embed_map","search_location","directions","nearby_search"]},"location":{"type":"string"},"zoom":{"type":"integer"},"origin":{"type":"string"},"destination":{"type":"string"},"keyword":{"type":"string"},"radius_m":{"type":"integer"}},"required":["action"]}),
    Tool(name="alloydb_query", description="Query AlloyDB across farmers, inventory, tasks with ILIKE filters. ALWAYS call before create/delete to resolve IDs.",
         inputSchema={"type":"object","properties":{"name":{"type":"string"},"city":{"type":"string"},"country":{"type":"string"},"sub_region":{"type":"string"},"gender":{"type":"string"},"crop_name":{"type":"string"},"inventory_status":{"type":"string"},"task_title":{"type":"string"},"priority":{"type":"string"},"task_status":{"type":"string"},"need_inventory":{"type":"boolean"},"need_tasks":{"type":"boolean"}}}),
    Tool(name="alloydb_analytics", description="Aggregation analytics. Metrics: stock_by_farmer, stock_by_country, stock_by_region, stock_by_crop, stock_ranking, stock_extremes, crop_diversity_by_region, crop_diversity_by_country, crop_diversity_by_farmer, crop_list_by_region, crop_list_by_country, inventory_status_breakdown, harvest_upcoming, harvest_overdue, task_load_by_farmer, task_load_by_country, tasks_overdue, tasks_due_soon, high_priority_tasks, farmer_count_by_country, farmer_count_by_region, farmer_gender_breakdown.",
         inputSchema={"type":"object","properties":{"metric":{"type":"string"},"country":{"type":"string"},"sub_region":{"type":"string"},"farmer_name":{"type":"string"},"crop_name":{"type":"string"},"top_n":{"type":"integer"},"order":{"type":"string"},"days_ahead":{"type":"integer"}},"required":["metric"]}),
    Tool(name="alloydb_manage_task", description="Create, update, delete, or delete_all tasks in AlloyDB.",
         inputSchema={"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete","delete_all"]},"farmer_id":{"type":"integer"},"farmer_name":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"},"due_date":{"type":"string"},"priority":{"type":"string"},"task_id":{"type":"integer"},"new_status":{"type":"string"},"new_priority":{"type":"string"}},"required":["action"]}),
    Tool(name="alloydb_manage_farmer", description="Create, update, or delete farmer profiles in AlloyDB.",
         inputSchema={"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"farmer_id":{"type":"integer"},"name":{"type":"string"},"gender":{"type":"string"},"contact":{"type":"string"},"city":{"type":"string"},"country":{"type":"string"},"sub_region":{"type":"string"}},"required":["action"]}),
    Tool(name="alloydb_manage_inventory", description="Create, update, or delete inventory items in AlloyDB.",
         inputSchema={"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"item_id":{"type":"integer"},"farmer_id":{"type":"integer"},"farmer_name":{"type":"string"},"crop_name":{"type":"string"},"stock":{"type":"number"},"harvest_date":{"type":"string"},"status":{"type":"string","enum":["In-Field","Harvested","Sold","Stored"]}},"required":["action"]}),
    Tool(name="alloydb_notes", description="Create, list, search, update, or delete notes in AlloyDB.",
         inputSchema={"type":"object","properties":{"action":{"type":"string","enum":["create","list","search","update","delete"]},"note_id":{"type":"integer"},"farmer_id":{"type":"integer"},"title":{"type":"string"},"content":{"type":"string"},"tags":{"type":"string"},"search_query":{"type":"string"}},"required":["action"]}),
]

@server.list_tools()
async def list_tools() -> list[Tool]:
    return TOOLS

def _gapi(method, url, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"Authorization":f"Bearer {token}","Content-Type":"application/json"}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except: return e.code, {"error": raw.decode(errors="replace")[:300]}

def _strip_ids(rows):
    return [{k:v for k,v in row.items() if not k.endswith("_id")} for row in rows]
def _fmt_dates(rows):
    out = []
    for row in rows:
        nr = {}
        for k,v in row.items():
            if v and isinstance(v,str) and re.match(r'\d{4}-\d{2}-\d{2}T',v): nr[k]=v[:10]
            elif hasattr(v,'isoformat'): nr[k]=v.isoformat()[:10]
            else: nr[k]=v
        out.append(nr)
    return out

@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    try:
        result = _dispatch(name, arguments)
        return [TextContent(type="text", text=result)]
    except Exception as e:
        return [TextContent(type="text", text=json.dumps({"error":str(e)}))]

def _dispatch(name, args):
    if name=="google_calendar": return _h_cal(args)
    elif name=="google_tasks": return _h_tasks(args)
    elif name=="google_maps": return _h_maps(args)
    elif name=="alloydb_query": return _h_query(args)
    elif name=="alloydb_analytics": return _h_analytics(args)
    elif name=="alloydb_manage_task": return _h_mtask(args)
    elif name=="alloydb_manage_farmer": return _h_mfarmer(args)
    elif name=="alloydb_manage_inventory": return _h_minventory(args)
    elif name=="alloydb_notes": return _h_notes(args)
    else: return json.dumps({"error":f"Unknown tool: {name}"})

# ═══ GOOGLE CALENDAR ═══
def _h_cal(a):
    token=a.get("access_token",""); action=a.get("action","")
    if not token: return json.dumps({"error":"NOT_AUTHENTICATED"})
    base="https://www.googleapis.com/calendar/v3/calendars/primary/events"
    if action=="list_events":
        mr=int(a.get("max_results",10))
        tmin=a.get("time_min","") or datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        params=f"timeMin={urllib.parse.quote(tmin)}&singleEvents=true&orderBy=startTime&maxResults={mr}"
        tmax=a.get("time_max","")
        if tmax: params+=f"&timeMax={urllib.parse.quote(tmax)}"
        s,d=_gapi("GET",f"{base}?{params}",token)
        if s>=400: return json.dumps({"error":f"Calendar API {s}"})
        evts=[{"event_id":e.get("id"),"title":e.get("summary","Untitled"),"start":e.get("start",{}).get("dateTime") or e.get("start",{}).get("date",""),"location":e.get("location","")} for e in d.get("items",[])]
        return json.dumps({"status":"SUCCESS","events":evts,"count":len(evts)})
    elif action=="create_event":
        sdt=a.get("start_datetime",""); edt=a.get("end_datetime","")
        if not sdt or not edt: return json.dumps({"error":"start/end datetime required."})
        tz="Asia/Kolkata"
        body={"summary":a.get("title","AgroSync Meeting"),"description":a.get("description",""),"start":{"dateTime":sdt,"timeZone":tz},"end":{"dateTime":edt,"timeZone":tz}}
        loc=a.get("location","")
        if loc: body["location"]=loc
        if a.get("add_meet_link",True):
            body["conferenceData"]={"createRequest":{"requestId":f"agrosync-{int(time.time())}","conferenceSolutionKey":{"type":"hangoutsMeet"}}}
        url=f"{base}?conferenceDataVersion=1" if a.get("add_meet_link",True) else base
        s,evt=_gapi("POST",url,token,body)
        if s>=400: return json.dumps({"error":f"Calendar API {s}"})
        r={"status":"SUCCESS","action":"Event Created","event_id":evt.get("id"),"title":evt.get("summary"),"start":evt.get("start",{}).get("dateTime",""),"meet_link":evt.get("hangoutLink","")}
        if loc:
            enc=urllib.parse.quote(loc)
            r["maps_snippet"]=f'<div class="maps-embed-wrapper"><iframe src="https://www.google.com/maps?q={enc}&output=embed" width="100%" height="220" style="border:0;border-radius:8px;" allowfullscreen="" loading="lazy"></iframe><div class="maps-embed-caption">📍 {loc}</div></div>'
            r["location"]=loc
        return json.dumps(r)
    elif action=="update_event":
        eid=a.get("event_id","")
        if not eid: return json.dumps({"error":"event_id required."})
        tz="Asia/Kolkata"
        body={}
        if a.get("title"): body["summary"]=a["title"]
        if a.get("description"): body["description"]=a["description"]
        if a.get("start_datetime"): body["start"]={"dateTime":a["start_datetime"],"timeZone":tz}
        if a.get("end_datetime"): body["end"]={"dateTime":a["end_datetime"],"timeZone":tz}
        if a.get("location"): body["location"]=a["location"]
        if not body: return json.dumps({"error":"Nothing to update."})
        s,evt=_gapi("PATCH",f"{base}/{eid}",token,body)
        if s>=400: return json.dumps({"error":f"Calendar API {s}"})
        return json.dumps({"status":"SUCCESS","action":"Event Updated","event_id":eid,"title":evt.get("summary","")})
    elif action=="delete_event":
        eid=a.get("event_id","")
        if not eid: return json.dumps({"error":"event_id required."})
        s,_=_gapi("DELETE",f"{base}/{eid}",token)
        if s in(200,204): return json.dumps({"status":"SUCCESS","action":"Event Deleted","event_id":eid})
        return json.dumps({"error":f"Delete failed {s}"})
    return json.dumps({"error":f"Unknown action: {action}"})

# ═══ GOOGLE TASKS ═══
def _h_tasks(a):
    token=a.get("access_token",""); action=a.get("action","")
    if not token: return json.dumps({"error":"NOT_AUTHENTICATED"})
    base="https://tasks.googleapis.com/tasks/v1/lists/@default/tasks"
    if action=="list_tasks":
        s,d=_gapi("GET",f"{base}?showCompleted=false",token)
        if s>=400: return json.dumps({"error":f"Tasks API {s}"})
        ts=[{"task_id":t.get("id"),"title":t.get("title","Untitled"),"notes":t.get("notes",""),"due":t.get("due","")[:10] if t.get("due") else "","status":t.get("status","")} for t in d.get("items",[])]
        return json.dumps({"status":"SUCCESS","tasks":ts,"count":len(ts)})
    elif action=="create_task":
        title=a.get("title","")
        if not title: return json.dumps({"error":"title required."})
        body={"title":title}
        if a.get("notes"): body["notes"]=a["notes"]
        if a.get("due_date"): body["due"]=a["due_date"]
        s,t=_gapi("POST",base,token,body)
        if s>=400: return json.dumps({"error":f"Tasks API {s}"})
        return json.dumps({"status":"SUCCESS","action":"Task Created in Google Tasks","task_id":t.get("id"),"title":t.get("title")})
    elif action=="update_task":
        tid=a.get("task_id","")
        if not tid: return json.dumps({"error":"task_id required."})
        body={}
        if a.get("title"): body["title"]=a["title"]
        if a.get("notes"): body["notes"]=a["notes"]
        if a.get("due_date"): body["due"]=a["due_date"]
        if a.get("status"): body["status"]=a["status"]
        if not body: return json.dumps({"error":"Nothing to update."})
        s,t=_gapi("PATCH",f"{base}/{tid}",token,body)
        if s>=400: return json.dumps({"error":f"Tasks API {s}"})
        return json.dumps({"status":"SUCCESS","action":"Task Updated in Google Tasks","task_id":tid,"title":t.get("title","")})
    elif action=="delete_task":
        tid=a.get("task_id","")
        if not tid: return json.dumps({"error":"task_id required."})
        s,_=_gapi("DELETE",f"{base}/{tid}",token)
        if s in(200,204): return json.dumps({"status":"SUCCESS","action":"Task Deleted from Google Tasks"})
        return json.dumps({"error":f"Delete failed {s}"})
    return json.dumps({"error":f"Unknown action: {action}"})

# ═══ GOOGLE MAPS ═══
def _h_maps(a):
    act=a.get("action","embed_map")
    loc=a.get("location",""); zoom=int(a.get("zoom",13))
    if act=="directions":
        ori=a.get("origin",""); dest=a.get("destination","")
        if not ori or not dest: return json.dumps({"error":"origin and destination required."})
        eori=urllib.parse.quote(ori); edest=urllib.parse.quote(dest)
        src=f"https://www.google.com/maps/embed/v1/directions?key={MAPS_API_KEY}&origin={eori}&destination={edest}" if MAPS_API_KEY else f"https://www.google.com/maps/dir/{eori}/{edest}"
        snip=f'<div class="maps-embed-wrapper"><iframe src="{src}" width="100%" height="300" style="border:0;border-radius:8px;" allowfullscreen="" loading="lazy"></iframe><div class="maps-embed-caption">🧭 {ori} → {dest}</div></div>'
        return json.dumps({"status":"SUCCESS","origin":ori,"destination":dest,"maps_snippet":snip,"embed_src":src})
    elif act=="nearby_search":
        kw=a.get("keyword",""); radius=int(a.get("radius_m",5000))
        if not loc: return json.dumps({"error":"location required."})
        enc=urllib.parse.quote(f"{kw} near {loc}")
        src=f"https://www.google.com/maps/embed/v1/search?key={MAPS_API_KEY}&q={enc}" if MAPS_API_KEY else f"https://www.google.com/maps?q={enc}&output=embed"
        snip=f'<div class="maps-embed-wrapper"><iframe src="{src}" width="100%" height="240" style="border:0;border-radius:8px;" allowfullscreen="" loading="lazy"></iframe><div class="maps-embed-caption">📍 {kw} near {loc}</div></div>'
        return json.dumps({"status":"SUCCESS","location":loc,"keyword":kw,"maps_snippet":snip,"embed_src":src})
    if not loc: return json.dumps({"error":"location required."})
    enc=urllib.parse.quote(loc)
    if act=="embed_map":
        src=f"https://www.google.com/maps/embed/v1/place?key={MAPS_API_KEY}&q={enc}&zoom={zoom}" if MAPS_API_KEY else f"https://www.google.com/maps?q={enc}&output=embed"
    else:
        src=f"https://www.google.com/maps/embed/v1/search?key={MAPS_API_KEY}&q={enc}" if MAPS_API_KEY else f"https://www.google.com/maps?q={enc}&output=embed"
    snip=f'<div class="maps-embed-wrapper"><iframe src="{src}" width="100%" height="240" style="border:0;border-radius:8px;" allowfullscreen="" loading="lazy" referrerpolicy="no-referrer-when-downgrade"></iframe><div class="maps-embed-caption">📍 {loc}</div></div>'
    return json.dumps({"status":"SUCCESS","location":loc,"maps_snippet":snip,"embed_src":src})

# ═══ ALLOYDB QUERY ═══
def _h_query(a):
    fc="f.name, f.gender, f.contact, f.city, f.country, f.sub_region"
    ic="i.crop_name, i.stock, i.harvest_date, i.status AS inventory_status"
    tc="t.title, t.description AS task_description, t.due_date, t.status AS task_status, t.priority"
    ni=a.get("need_inventory") or a.get("crop_name") or a.get("inventory_status")
    nt=a.get("need_tasks") or a.get("priority") or a.get("task_status") or a.get("task_title")
    if ni and nt:
        sel=f"SELECT f.farmer_id, {fc}, i.item_id, {ic}, t.task_id, {tc}"; fr="FROM farmers f LEFT JOIN inventory i ON f.farmer_id=i.farmer_id LEFT JOIN tasks t ON f.farmer_id=t.farmer_id"
    elif ni:
        sel=f"SELECT f.farmer_id, {fc}, i.item_id, {ic}"; fr="FROM farmers f LEFT JOIN inventory i ON f.farmer_id=i.farmer_id"
    elif nt:
        sel=f"SELECT f.farmer_id, {fc}, t.task_id, {tc}"; fr="FROM farmers f LEFT JOIN tasks t ON f.farmer_id=t.farmer_id"
    else:
        sel=f"SELECT f.farmer_id, {fc}"; fr="FROM farmers f"
    wh,p=["1=1"],{}
    fm={"name":"f.name","city":"f.city","country":"f.country","sub_region":"f.sub_region","gender":"f.gender","crop_name":"i.crop_name","inventory_status":"i.status","task_title":"t.title","priority":"t.priority","task_status":"t.status"}
    for k,col in fm.items():
        if a.get(k): wh.append(f"{col} ILIKE :{k}"); p[k]=f"%{a[k]}%"
    sql=f"{sel} {fr} WHERE {' AND '.join(wh)}"
    with get_engine().connect() as conn:
        rows=conn.execute(text(sql),p).fetchall()
    if not rows: return "RESULT: NOT_FOUND – No records match the query in AlloyDB."
    raw=[dict(r._mapping) for r in rows]
    display=_strip_ids(_fmt_dates(raw))
    idmap=[{"__internal__farmer_id":r.get("farmer_id"),"__internal__item_id":r.get("item_id"),"__internal__task_id":r.get("task_id"),"name":r.get("name"),"title":r.get("title")} for r in raw]
    return json.dumps({"display_data":display,"id_map":idmap,"row_count":len(display)},default=str)

# ═══ ALLOYDB ANALYTICS (full 21-metric engine) ═══
def _h_analytics(a):
    metric=a.get("metric","").strip().lower()
    country=a.get("country"); sub_region=a.get("sub_region")
    farmer_nm=a.get("farmer_name"); crop_nm=a.get("crop_name")
    top_n=a.get("top_n"); order="ASC" if str(a.get("order","desc")).lower()=="asc" else "DESC"
    days_ahead=int(a.get("days_ahead",30)); today_str=datetime.now().strftime('%Y-%m-%d')

    def sw(aliases=("f","i","t"), extra=None):
        c,p=["1=1"],{}; af,ai,at=aliases
        if country and af: c.append(f"{af}.country ILIKE :country"); p["country"]=f"%{country}%"
        if sub_region and af: c.append(f"{af}.sub_region ILIKE :sub_region"); p["sub_region"]=f"%{sub_region}%"
        if farmer_nm and af: c.append(f"{af}.name ILIKE :farmer_nm"); p["farmer_nm"]=f"%{farmer_nm}%"
        if crop_nm and ai: c.append(f"{ai}.crop_name ILIKE :crop_nm"); p["crop_nm"]=f"%{crop_nm}%"
        if extra:
            for ec,ep in extra: c.append(ec); p.update(ep)
        return " AND ".join(c), p

    def lm(): return f"LIMIT {int(top_n)}" if top_n else ""
    def run(sql,p):
        with get_engine().connect() as conn:
            rows=conn.execute(text(sql),p).fetchall()
        if not rows: return json.dumps({"result":"NOT_FOUND","message":"No data matched."})
        return json.dumps([dict(r._mapping) for r in rows],default=str)

    if metric=="stock_by_farmer":
        wh,p=sw()
        return run(f"SELECT f.name AS farmer,f.city,f.country,f.sub_region,SUM(i.stock) AS total_stock,MAX(i.stock) AS max_single_item_stock,MIN(i.stock) AS min_single_item_stock,COUNT(i.item_id) AS crop_lines FROM farmers f LEFT JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.farmer_id,f.name,f.city,f.country,f.sub_region ORDER BY total_stock {order} {lm()}",p)
    elif metric=="stock_by_country":
        wh,p=sw()
        return run(f"SELECT f.country,SUM(i.stock) AS total_stock,MAX(i.stock) AS max_stock,MIN(i.stock) AS min_stock,ROUND(AVG(i.stock),0) AS avg_stock,COUNT(DISTINCT f.farmer_id) AS farmers,COUNT(i.item_id) AS crop_lines FROM farmers f LEFT JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.country ORDER BY total_stock {order} {lm()}",p)
    elif metric=="stock_by_region":
        wh,p=sw()
        return run(f"SELECT f.sub_region,SUM(i.stock) AS total_stock,MAX(i.stock) AS max_stock,MIN(i.stock) AS min_stock,ROUND(AVG(i.stock),0) AS avg_stock,COUNT(DISTINCT f.farmer_id) AS farmers FROM farmers f LEFT JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.sub_region ORDER BY total_stock {order} {lm()}",p)
    elif metric=="stock_by_crop":
        wh,p=sw()
        return run(f"SELECT i.crop_name,SUM(i.stock) AS total_stock,MAX(i.stock) AS max_stock,MIN(i.stock) AS min_stock,ROUND(AVG(i.stock),0) AS avg_stock,COUNT(DISTINCT f.farmer_id) AS farmer_count FROM inventory i JOIN farmers f ON i.farmer_id=f.farmer_id WHERE {wh} GROUP BY i.crop_name ORDER BY total_stock {order} {lm()}",p)
    elif metric=="stock_ranking":
        wh,p=sw()
        return run(f"SELECT RANK() OVER (ORDER BY SUM(i.stock) DESC) AS rank,f.name AS farmer,f.country,f.sub_region,SUM(i.stock) AS total_stock FROM farmers f LEFT JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.farmer_id,f.name,f.country,f.sub_region ORDER BY total_stock {order} {lm()}",p)
    elif metric=="stock_extremes":
        wh,p=sw()
        return run(f"WITH ranked AS (SELECT f.name AS farmer,f.country,f.sub_region,i.crop_name,i.stock,RANK() OVER (ORDER BY i.stock DESC) AS rk_max,RANK() OVER (ORDER BY i.stock ASC) AS rk_min FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh}) SELECT CASE WHEN rk_max=1 THEN 'Highest Stock' ELSE 'Lowest Stock' END AS label,farmer,country,sub_region,crop_name,stock FROM ranked WHERE rk_max=1 OR rk_min=1",p)
    elif metric=="crop_diversity_by_region":
        wh,p=sw()
        return run(f"SELECT f.sub_region,COUNT(DISTINCT i.crop_name) AS unique_crops,SUM(i.stock) AS total_stock,COUNT(DISTINCT f.farmer_id) AS farmers FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.sub_region ORDER BY unique_crops {order}",p)
    elif metric=="crop_diversity_by_country":
        wh,p=sw()
        return run(f"SELECT f.country,COUNT(DISTINCT i.crop_name) AS unique_crops,SUM(i.stock) AS total_stock,COUNT(DISTINCT f.farmer_id) AS farmers FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.country ORDER BY unique_crops {order}",p)
    elif metric=="crop_diversity_by_farmer":
        wh,p=sw()
        return run(f"SELECT f.name AS farmer,f.country,f.sub_region,COUNT(DISTINCT i.crop_name) AS unique_crops,STRING_AGG(DISTINCT i.crop_name,', ' ORDER BY i.crop_name) AS crops FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.farmer_id,f.name,f.country,f.sub_region ORDER BY unique_crops {order} {lm()}",p)
    elif metric=="crop_list_by_region":
        wh,p=sw()
        return run(f"SELECT f.sub_region,STRING_AGG(DISTINCT i.crop_name,', ' ORDER BY i.crop_name) AS crops,COUNT(DISTINCT i.crop_name) AS unique_crops FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.sub_region ORDER BY f.sub_region",p)
    elif metric=="crop_list_by_country":
        wh,p=sw()
        return run(f"SELECT f.country,STRING_AGG(DISTINCT i.crop_name,', ' ORDER BY i.crop_name) AS crops,COUNT(DISTINCT i.crop_name) AS unique_crops FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY f.country ORDER BY f.country",p)
    elif metric=="inventory_status_breakdown":
        gc="f.sub_region" if sub_region else "f.country"
        wh,p=sw()
        return run(f"SELECT {gc} AS scope,i.status,COUNT(i.item_id) AS item_count,SUM(i.stock) AS total_stock FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} GROUP BY {gc},i.status ORDER BY {gc},i.status",p)
    elif metric=="harvest_upcoming":
        fs=(datetime.now()+timedelta(days=days_ahead)).strftime('%Y-%m-%d')
        wh,p=sw(extra_conds=[("i.harvest_date BETWEEN :today AND :future",{"today":today_str,"future":fs})])
        return run(f"SELECT f.name AS farmer,f.country,f.sub_region,i.crop_name,i.stock,i.harvest_date,i.status FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} ORDER BY i.harvest_date ASC {lm()}",p)
    elif metric=="harvest_overdue":
        wh,p=sw(extra_conds=[("i.harvest_date < :today AND i.status='In-Field'",{"today":today_str})])
        p["today_disp"]=today_str
        return run(f"SELECT f.name AS farmer,f.country,f.sub_region,i.crop_name,i.stock,i.harvest_date,(:today_disp::date - i.harvest_date::date) AS days_overdue FROM farmers f JOIN inventory i ON f.farmer_id=i.farmer_id WHERE {wh} ORDER BY days_overdue DESC",p)
    elif metric=="task_load_by_farmer":
        wh,p=sw(aliases=("f",None,"t"))
        return run(f"SELECT f.name AS farmer,f.country,f.sub_region,COUNT(t.task_id) AS total_tasks,COUNT(t.task_id) FILTER (WHERE t.priority='High') AS high_priority,COUNT(t.task_id) FILTER (WHERE t.priority='Medium') AS medium_priority,COUNT(t.task_id) FILTER (WHERE t.priority='Low') AS low_priority,COUNT(t.task_id) FILTER (WHERE t.status='Pending') AS pending FROM farmers f LEFT JOIN tasks t ON f.farmer_id=t.farmer_id WHERE {wh} GROUP BY f.farmer_id,f.name,f.country,f.sub_region ORDER BY total_tasks {order} {lm()}",p)
    elif metric=="task_load_by_country":
        wh,p=sw(aliases=("f",None,"t"))
        return run(f"SELECT f.country,COUNT(t.task_id) AS total_tasks,COUNT(t.task_id) FILTER (WHERE t.priority='High') AS high_priority,COUNT(t.task_id) FILTER (WHERE t.priority='Medium') AS medium_priority,COUNT(t.task_id) FILTER (WHERE t.priority='Low') AS low_priority,COUNT(DISTINCT f.farmer_id) AS farmers FROM farmers f LEFT JOIN tasks t ON f.farmer_id=t.farmer_id WHERE {wh} GROUP BY f.country ORDER BY total_tasks {order}",p)
    elif metric=="tasks_overdue":
        wh,p=sw(aliases=("f",None,"t"),extra=[("t.due_date < :today AND t.status!='Completed'",{"today":today_str})])
        p["today_d"]=today_str
        return run(f"SELECT f.name AS farmer,f.country,t.title,t.priority,t.due_date,(:today_d::date - t.due_date::date) AS days_overdue FROM farmers f JOIN tasks t ON f.farmer_id=t.farmer_id WHERE {wh} ORDER BY days_overdue DESC {lm()}",p)
    elif metric=="tasks_due_soon":
        fd=(datetime.now()+timedelta(days=days_ahead)).strftime('%Y-%m-%d')
        wh,p=sw(aliases=("f",None,"t"),extra=[("t.due_date BETWEEN :today AND :future AND t.status!='Completed'",{"today":today_str,"future":fd})])
        return run(f"SELECT f.name AS farmer,f.country,f.sub_region,t.title,t.priority,t.due_date,t.status FROM farmers f JOIN tasks t ON f.farmer_id=t.farmer_id WHERE {wh} ORDER BY t.due_date ASC {lm()}",p)
    elif metric=="high_priority_tasks":
        wh,p=sw(aliases=("f",None,"t"),extra=[("t.priority='High'",{})])
        return run(f"SELECT f.name AS farmer,f.country,f.sub_region,t.title,t.description AS task_description,t.due_date,t.status FROM farmers f JOIN tasks t ON f.farmer_id=t.farmer_id WHERE {wh} ORDER BY t.due_date ASC {lm()}",p)
    elif metric=="farmer_count_by_country":
        wh,p=sw(aliases=("f",None,None))
        return run(f"SELECT f.country,COUNT(f.farmer_id) AS total_farmers FROM farmers f WHERE {wh} GROUP BY f.country ORDER BY total_farmers {order}",p)
    elif metric=="farmer_count_by_region":
        wh,p=sw(aliases=("f",None,None))
        return run(f"SELECT f.sub_region,f.country,COUNT(f.farmer_id) AS total_farmers FROM farmers f WHERE {wh} GROUP BY f.sub_region,f.country ORDER BY total_farmers {order}",p)
    elif metric=="farmer_gender_breakdown":
        wh,p=sw(aliases=("f",None,None))
        return run(f"SELECT f.country,COUNT(f.farmer_id) FILTER (WHERE f.gender='Male') AS male_farmers,COUNT(f.farmer_id) FILTER (WHERE f.gender='Female') AS female_farmers,COUNT(f.farmer_id) AS total_farmers FROM farmers f WHERE {wh} GROUP BY f.country ORDER BY total_farmers {order}",p)
    elif metric=="region_crop_summary":
        return run("SELECT f.country,f.sub_region,STRING_AGG(DISTINCT i.crop_name,', ' ORDER BY i.crop_name) AS crops,COUNT(DISTINCT f.farmer_id) AS farmer_count,SUM(i.stock) AS total_stock FROM farmers f LEFT JOIN inventory i ON f.farmer_id=i.farmer_id GROUP BY f.country,f.sub_region ORDER BY f.country,f.sub_region",{})
    elif metric=="alerts_combined":
        alerts=[]
        with get_engine().connect() as conn:
            for r in conn.execute(text("SELECT f.name,t.title,t.due_date,t.priority FROM tasks t JOIN farmers f ON t.farmer_id=f.farmer_id WHERE t.due_date<:today AND t.status!='Completed' ORDER BY t.due_date LIMIT 10"),{"today":today_str}).fetchall():
                alerts.append({"type":"overdue_task","severity":"high","message":f"Task '{r[1]}' for {r[0]} was due {r[2]} (priority: {r[3]})"})
            fs=(datetime.now()+timedelta(days=7)).strftime('%Y-%m-%d')
            for r in conn.execute(text("SELECT f.name,i.crop_name,i.harvest_date FROM inventory i JOIN farmers f ON i.farmer_id=f.farmer_id WHERE i.harvest_date BETWEEN :today AND :future AND i.status='In-Field' ORDER BY i.harvest_date LIMIT 10"),{"today":today_str,"future":fs}).fetchall():
                alerts.append({"type":"upcoming_harvest","severity":"medium","message":f"{r[1]} harvest for {r[0]} on {r[2]}"})
            for r in conn.execute(text("SELECT f.name,i.crop_name,i.harvest_date FROM inventory i JOIN farmers f ON i.farmer_id=f.farmer_id WHERE i.harvest_date<:today AND i.status='In-Field' ORDER BY i.harvest_date LIMIT 10"),{"today":today_str}).fetchall():
                alerts.append({"type":"overdue_harvest","severity":"high","message":f"{r[1]} for {r[0]} — harvest was due {r[2]} but still In-Field"})
        return json.dumps({"alerts":alerts,"count":len(alerts),"generated_at":today_str})
    else:
        return json.dumps({"error":f"Unknown metric: {metric}"})

# ═══ ALLOYDB MANAGE TASK ═══
def _h_mtask(a):
    action=a.get("action","").lower()
    with get_engine().begin() as conn:
        if action=="create":
            fid=a.get("farmer_id")
            if not fid: return "ERROR: farmer_id required. Call alloydb_query first."
            rd=a.get("due_date",""); m=re.search(r'\d{4}-\d{2}-\d{2}',rd); ds=m.group(0) if m else datetime.now().strftime('%Y-%m-%d')
            pr=a.get("priority","Medium")
            if pr not in("High","Medium","Low"): pr="Medium"
            conn.execute(text("INSERT INTO tasks(farmer_id,title,description,status,priority,due_date) VALUES(:fid,:title,:desc,'Pending',:priority,:due_date)"),{"fid":int(float(fid)),"title":a.get("title","New Task"),"desc":a.get("description",""),"priority":pr,"due_date":ds})
            return json.dumps({"status":"SUCCESS","action":"Task Created","farmer":a.get("farmer_name",""),"title":a.get("title","New Task"),"due_date":ds,"priority":pr})
        elif action=="update":
            tid=a.get("task_id")
            if not tid: return "ERROR: task_id required."
            s,p=[],{"tid":int(float(tid))}
            if a.get("new_status"): s.append("status=:ns"); p["ns"]=a["new_status"]
            if a.get("new_priority"): s.append("priority=:np"); p["np"]=a["new_priority"]
            if a.get("title"): s.append("title=:title"); p["title"]=a["title"]
            if a.get("due_date"):
                m=re.search(r'\d{4}-\d{2}-\d{2}',a["due_date"])
                if m: s.append("due_date=:dd"); p["dd"]=m.group(0)
            if not s: return "ERROR: Nothing to update."
            row=conn.execute(text(f"UPDATE tasks SET {','.join(s)} WHERE task_id=:tid RETURNING title,status,priority,due_date"),p).fetchone()
            if not row: return json.dumps({"status":"NOT_FOUND"})
            return json.dumps({"status":"SUCCESS","action":"Task Updated","title":row[0],"new_status":row[1],"priority":row[2],"due_date":str(row[3])[:10] if row[3] else "N/A"})
        elif action=="delete":
            tid=a.get("task_id")
            if not tid: return "ERROR: task_id required."
            ti=int(float(tid))
            row=conn.execute(text("SELECT title,due_date,priority FROM tasks WHERE task_id=:tid"),{"tid":ti}).fetchone()
            if not row: return json.dumps({"status":"NOT_FOUND"})
            conn.execute(text("DELETE FROM tasks WHERE task_id=:tid"),{"tid":ti})
            return json.dumps({"status":"SUCCESS","action":"Task Deleted","title":row[0],"due_date":str(row[1])[:10] if row[1] else "N/A","priority":row[2]})
        elif action=="delete_all":
            fid=a.get("farmer_id")
            if not fid: return "ERROR: farmer_id required."
            fi=int(float(fid))
            rows=conn.execute(text("SELECT title FROM tasks WHERE farmer_id=:fid"),{"fid":fi}).fetchall()
            if not rows: return json.dumps({"status":"NOT_FOUND","message":"No tasks found."})
            conn.execute(text("DELETE FROM tasks WHERE farmer_id=:fid"),{"fid":fi})
            return json.dumps({"status":"SUCCESS","action":"All Tasks Deleted","deleted_count":len(rows)})
    return json.dumps({"error":f"Unknown action: {action}"})

# ═══ ALLOYDB MANAGE FARMER ═══
def _h_mfarmer(a):
    action=a.get("action","").lower()
    with get_engine().begin() as conn:
        if action=="create":
            nm=a.get("name")
            if not nm: return json.dumps({"error":"name required."})
            conn.execute(text("INSERT INTO farmers(name,gender,contact,city,country,sub_region) VALUES(:name,:gender,:contact,:city,:country,:sub_region)"),{"name":nm,"gender":a.get("gender",""),"contact":a.get("contact",""),"city":a.get("city",""),"country":a.get("country",""),"sub_region":a.get("sub_region","")})
            return json.dumps({"status":"SUCCESS","action":"Farmer Created","name":nm})
        elif action=="update":
            fid=a.get("farmer_id")
            if not fid: return json.dumps({"error":"farmer_id required."})
            s,p=[],{"fid":int(float(fid))}
            for c in("name","gender","contact","city","country","sub_region"):
                if a.get(c): s.append(f"{c}=:{c}"); p[c]=a[c]
            if not s: return json.dumps({"error":"Nothing to update."})
            row=conn.execute(text(f"UPDATE farmers SET {','.join(s)} WHERE farmer_id=:fid RETURNING name"),p).fetchone()
            if not row: return json.dumps({"status":"NOT_FOUND"})
            return json.dumps({"status":"SUCCESS","action":"Farmer Updated","name":row[0]})
        elif action=="delete":
            fid=a.get("farmer_id")
            if not fid: return json.dumps({"error":"farmer_id required."})
            fi=int(float(fid))
            row=conn.execute(text("SELECT name FROM farmers WHERE farmer_id=:fid"),{"fid":fi}).fetchone()
            if not row: return json.dumps({"status":"NOT_FOUND"})
            conn.execute(text("DELETE FROM farmers WHERE farmer_id=:fid"),{"fid":fi})
            return json.dumps({"status":"SUCCESS","action":"Farmer Deleted","name":row[0]})
    return json.dumps({"error":f"Unknown action: {action}"})

# ═══ ALLOYDB MANAGE INVENTORY ═══
def _h_minventory(a):
    action=a.get("action","").lower()
    with get_engine().begin() as conn:
        if action=="create":
            fid=a.get("farmer_id")
            if not fid: return json.dumps({"error":"farmer_id required. Call alloydb_query first."})
            crop=a.get("crop_name","")
            if not crop: return json.dumps({"error":"crop_name required."})
            stock=float(a.get("stock",0))
            hd=a.get("harvest_date",""); m=re.search(r'\d{4}-\d{2}-\d{2}',hd); ds=m.group(0) if m else None
            st=a.get("status","In-Field")
            if st not in("In-Field","Harvested","Sold","Stored"): st="In-Field"
            conn.execute(text("INSERT INTO inventory(farmer_id,crop_name,stock,harvest_date,status) VALUES(:fid,:crop,:stock,:hd,:st)"),
                {"fid":int(float(fid)),"crop":crop,"stock":stock,"hd":ds,"st":st})
            return json.dumps({"status":"SUCCESS","action":"Inventory Created","crop_name":crop,"stock":stock,"farmer_name":a.get("farmer_name","")})
        elif action=="update":
            iid=a.get("item_id")
            if not iid: return json.dumps({"error":"item_id required."})
            s,p=[],{"iid":int(float(iid))}
            if a.get("crop_name"): s.append("crop_name=:crop"); p["crop"]=a["crop_name"]
            if a.get("stock") is not None: s.append("stock=:stock"); p["stock"]=float(a["stock"])
            if a.get("harvest_date"):
                m=re.search(r'\d{4}-\d{2}-\d{2}',a["harvest_date"])
                if m: s.append("harvest_date=:hd"); p["hd"]=m.group(0)
            if a.get("status"): s.append("status=:st"); p["st"]=a["status"]
            if not s: return json.dumps({"error":"Nothing to update."})
            row=conn.execute(text(f"UPDATE inventory SET {','.join(s)} WHERE item_id=:iid RETURNING crop_name,stock,status"),p).fetchone()
            if not row: return json.dumps({"status":"NOT_FOUND"})
            return json.dumps({"status":"SUCCESS","action":"Inventory Updated","crop_name":row[0],"stock":str(row[1]),"status":row[2]})
        elif action=="delete":
            iid=a.get("item_id")
            if not iid: return json.dumps({"error":"item_id required."})
            ii=int(float(iid))
            row=conn.execute(text("SELECT crop_name,stock FROM inventory WHERE item_id=:iid"),{"iid":ii}).fetchone()
            if not row: return json.dumps({"status":"NOT_FOUND"})
            conn.execute(text("DELETE FROM inventory WHERE item_id=:iid"),{"iid":ii})
            return json.dumps({"status":"SUCCESS","action":"Inventory Deleted","crop_name":row[0],"stock":str(row[1])})
    return json.dumps({"error":f"Unknown action: {action}"})

# ═══ ALLOYDB NOTES ═══
def _h_notes(a):
    action=a.get("action","").lower()
    with get_engine().begin() as conn:
        if action=="create":
            ct=a.get("content","")
            if not ct: return json.dumps({"error":"content required."})
            fid=a.get("farmer_id")
            conn.execute(text("INSERT INTO notes(farmer_id,title,content,tags) VALUES(:fid,:title,:content,:tags)"),{"fid":int(float(fid)) if fid else None,"title":a.get("title","Untitled Note"),"content":ct,"tags":a.get("tags","")})
            return json.dumps({"status":"SUCCESS","action":"Note Created","title":a.get("title","Untitled Note")})
        elif action=="list":
            fid=a.get("farmer_id")
            if fid: rows=conn.execute(text("SELECT note_id,title,content,tags,created_at FROM notes WHERE farmer_id=:fid ORDER BY created_at DESC"),{"fid":int(float(fid))}).fetchall()
            else: rows=conn.execute(text("SELECT note_id,title,content,tags,created_at FROM notes ORDER BY created_at DESC LIMIT 20")).fetchall()
            if not rows: return json.dumps({"result":"NOT_FOUND","message":"No notes found."})
            return json.dumps([{"note_id":r[0],"title":r[1],"content":r[2],"tags":r[3],"created_at":str(r[4])[:16]} for r in rows],default=str)
        elif action=="search":
            q=a.get("search_query","")
            if not q: return json.dumps({"error":"search_query required."})
            rows=conn.execute(text("SELECT note_id,title,content,tags,created_at FROM notes WHERE title ILIKE :q OR content ILIKE :q OR tags ILIKE :q ORDER BY created_at DESC LIMIT 20"),{"q":f"%{q}%"}).fetchall()
            if not rows: return json.dumps({"result":"NOT_FOUND","message":f"No notes matching '{q}'."})
            return json.dumps([{"note_id":r[0],"title":r[1],"content":r[2],"tags":r[3],"created_at":str(r[4])[:16]} for r in rows],default=str)
        elif action=="update":
            nid=a.get("note_id")
            if not nid: return json.dumps({"error":"note_id required."})
            s,p=[],{"nid":int(float(nid))}
            if a.get("title"): s.append("title=:title"); p["title"]=a["title"]
            if a.get("content"): s.append("content=:content"); p["content"]=a["content"]
            if a.get("tags"): s.append("tags=:tags"); p["tags"]=a["tags"]
            s.append("updated_at=NOW()")
            if len(s)<=1: return json.dumps({"error":"Nothing to update."})
            row=conn.execute(text(f"UPDATE notes SET {','.join(s)} WHERE note_id=:nid RETURNING title"),p).fetchone()
            if not row: return json.dumps({"status":"NOT_FOUND"})
            return json.dumps({"status":"SUCCESS","action":"Note Updated","title":row[0]})
        elif action=="delete":
            nid=a.get("note_id")
            if not nid: return json.dumps({"error":"note_id required."})
            row=conn.execute(text("DELETE FROM notes WHERE note_id=:nid RETURNING title"),{"nid":int(float(nid))}).fetchone()
            if not row: return json.dumps({"status":"NOT_FOUND"})
            return json.dumps({"status":"SUCCESS","action":"Note Deleted","title":row[0]})
    return json.dumps({"error":f"Unknown action: {action}"})

# ═══ ENTRY POINT ═══
async def main():
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())

if __name__=="__main__":
    import sys
    if "--help" in sys.argv: print(__doc__); sys.exit(0)
    asyncio.run(main())