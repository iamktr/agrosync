"""
AgroSync Intelligence — Gemini 2.5 Flash Multi-Agent System
=============================================================
Primary Coordinator + 3 Specialist Sub-Agents, all powered by Gemini.
ALL tool execution is delegated to mcp_server.py via MCP protocol.
"""
import os, re, time, json, asyncio, threading, queue
from typing import Optional
from datetime import datetime, timedelta
from concurrent.futures import ThreadPoolExecutor, as_completed
from functools import wraps
from flask import Flask, request, jsonify, render_template, session, Response
from sqlalchemy import create_engine, text, pool
import vertexai
from vertexai.generative_models import GenerativeModel, Tool, FunctionDeclaration, Part, Content

app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "agrosync-zero-hallucination-v2026")
app.config.update(
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Lax',
    PERMANENT_SESSION_LIFETIME=3600,
)

PROJECT_ID   = "cohort-1-hackathon"
LOCATION     = os.getenv("VERTEX_LOCATION", "global")  # "global" distributes load across regions
MODEL_ID     = "gemini-2.5-flash"
API_KEY      = os.getenv("AGROSYNC_API_KEY", "")
GOOGLE_CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID", "")
MAPS_API_KEY = os.getenv("MAPS_API_KEY", "")

# ═══════════════════════════════════════════════════════════════════════════════
# AlloyDB — ROBUST CONNECTION POOL
# ═══════════════════════════════════════════════════════════════════════════════
DB_URL = (f"postgresql+pg8000://{os.getenv('DB_USER', '')}:{os.getenv('DB_PASS', '')}"
          f"@{os.getenv('DB_HOST', 'localhost')}/{os.getenv('DB_NAME', 'agrosync')}")

try:
    vertexai.init(project=PROJECT_ID, location=LOCATION)
    print(f"[INIT] Vertex AI initialized — project={PROJECT_ID}, location={LOCATION}")
except Exception as e:
    print(f"[INIT] Vertex AI init failed: {e} — will retry on first request")

engine = None
def get_engine():
    global engine
    if engine is None:
        try:
            engine = create_engine(
                DB_URL,
                pool_pre_ping=True,
                pool_size=3,
                max_overflow=5,
                pool_timeout=10,
                pool_recycle=300,
                connect_args={"timeout": 8},
            )
            print(f"[INIT] DB engine created")
        except Exception as e:
            print(f"[INIT] DB engine failed: {e}")
            raise
    return engine

# Try creating engine at startup, but don't crash if it fails
try:
    get_engine()
except Exception as e:
    print(f"[INIT] DB deferred — will retry on first request: {e}")

agent_executor = ThreadPoolExecutor(max_workers=3)

# ═══════════════════════════════════════════════════════════════════════════════
# LIVE STATUS SYSTEM — SSE per-request
# ═══════════════════════════════════════════════════════════════════════════════
# Each request gets a unique ID; status updates are pushed via SSE
_status_queues = {}  # request_id -> queue.Queue

def push_status(request_id: str, message: str):
    q = _status_queues.get(request_id)
    if q:
        q.put(message)

def close_status(request_id: str):
    q = _status_queues.get(request_id)
    if q:
        q.put("__DONE__")


# ═══════════════════════════════════════════════════════════════════════════════
# MCP CLIENT BRIDGE — connects to mcp_server.py
# ═══════════════════════════════════════════════════════════════════════════════

class MCPClientBridge:
    def __init__(self):
        self._loop = None
        self._session = None
        self._ready = threading.Event()
        self._tools = []
        self._error = None

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()
        if not self._ready.wait(timeout=15):
            print(f"[MCP] Bridge timeout: {self._error or 'unknown'}")

    def _run(self):
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._connect())
        except Exception as e:
            self._error = str(e); self._ready.set()

    async def _connect(self):
        try:
            from mcp import ClientSession, StdioServerParameters
            from mcp.client.stdio import stdio_client
            params = StdioServerParameters(
                command="python",
                args=[os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp_server.py")],
                env={**os.environ})
            async with stdio_client(params) as (r, w):
                async with ClientSession(r, w) as sess:
                    await sess.initialize()
                    tools_result = await sess.list_tools()
                    self._tools = [{"name": t.name, "description": t.description} for t in tools_result.tools]
                    print(f"[MCP] Connected — {len(self._tools)} tools: {[t['name'] for t in self._tools]}")
                    self._session = sess
                    self._ready.set()
                    while True:
                        await asyncio.sleep(1)
        except ImportError:
            self._error = "MCP SDK not installed. pip install mcp"
            print(f"[MCP] {self._error}"); self._ready.set()
        except Exception as e:
            self._error = str(e); print(f"[MCP] Error: {e}"); self._ready.set()

    @property
    def is_connected(self): return self._session is not None

    def call_tool(self, name: str, arguments: dict, timeout: float = 25) -> str:
        if not self.is_connected:
            return json.dumps({"error": "MCP_NOT_CONNECTED", "message": self._error or "MCP bridge unavailable."})
        try:
            future = asyncio.run_coroutine_threadsafe(self._session.call_tool(name, arguments), self._loop)
            result = future.result(timeout=timeout)
            texts = [c.text for c in result.content if hasattr(c, 'text')]
            return texts[0] if texts else json.dumps({"status": "SUCCESS"})
        except Exception as e:
            return json.dumps({"error": "MCP_CALL_FAILED", "message": str(e)[:300]})

mcp = MCPClientBridge()
try:
    mcp.start()
except Exception as e:
    print(f"[MCP] Skipped: {e}")


# ═══════════════════════════════════════════════════════════════════════════════
# AUTH DECORATOR
# ═══════════════════════════════════════════════════════════════════════════════

def require_api_key(f):
    @wraps(f)
    def decorated(*a, **kw):
        if not API_KEY: return f(*a, **kw)
        if session.get('history') is not None: return f(*a, **kw)
        if request.headers.get('X-API-Key', '') != API_KEY:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*a, **kw)
    return decorated


# ═══════════════════════════════════════════════════════════════════════════════
# GEMINI TOOL DECLARATIONS
# ═══════════════════════════════════════════════════════════════════════════════

get_data_tool = FunctionDeclaration(name="alloydb_query",
    description="Query AlloyDB for agricultural data across farmers, inventory, and tasks tables. ALWAYS call this before any create/delete operation to resolve IDs.",
    parameters={"type":"object","properties":{"name":{"type":"string"},"city":{"type":"string"},"country":{"type":"string"},"sub_region":{"type":"string"},"gender":{"type":"string"},"crop_name":{"type":"string"},"inventory_status":{"type":"string"},"task_title":{"type":"string"},"priority":{"type":"string"},"task_status":{"type":"string"},"need_inventory":{"type":"boolean"},"need_tasks":{"type":"boolean"}}})

manage_task_tool = FunctionDeclaration(name="alloydb_manage_task",
    description="Create, update, or delete task(s) in AlloyDB.",
    parameters={"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete","delete_all"]},"farmer_id":{"type":"integer"},"farmer_name":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"},"due_date":{"type":"string"},"priority":{"type":"string"},"task_id":{"type":"integer"},"new_status":{"type":"string"},"new_priority":{"type":"string"}},"required":["action"]})

get_analytics_tool = FunctionDeclaration(name="alloydb_analytics",
    description="Run aggregation analytics on AlloyDB. Metrics: stock_by_farmer, stock_by_country, stock_by_region, stock_by_crop, stock_ranking, stock_extremes, crop_diversity_by_region, crop_diversity_by_country, crop_diversity_by_farmer, crop_list_by_region, crop_list_by_country, inventory_status_breakdown, harvest_upcoming, harvest_overdue, task_load_by_farmer, task_load_by_country, tasks_overdue, tasks_due_soon, high_priority_tasks, farmer_count_by_country, farmer_count_by_region, farmer_gender_breakdown.",
    parameters={"type":"object","properties":{"metric":{"type":"string"},"country":{"type":"string"},"sub_region":{"type":"string"},"farmer_name":{"type":"string"},"crop_name":{"type":"string"},"top_n":{"type":"integer"},"order":{"type":"string"},"days_ahead":{"type":"integer"}},"required":["metric"]})

manage_farmer_tool = FunctionDeclaration(name="alloydb_manage_farmer",
    description="Create, update, or delete a farmer profile in AlloyDB.",
    parameters={"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"farmer_id":{"type":"integer"},"name":{"type":"string"},"gender":{"type":"string"},"contact":{"type":"string"},"city":{"type":"string"},"country":{"type":"string"},"sub_region":{"type":"string"}},"required":["action"]})

manage_inventory_tool = FunctionDeclaration(name="alloydb_manage_inventory",
    description="Create, update, or delete inventory items in AlloyDB. Requires farmer_id (call alloydb_query first to resolve).",
    parameters={"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"item_id":{"type":"integer"},"farmer_id":{"type":"integer"},"farmer_name":{"type":"string"},"crop_name":{"type":"string"},"stock":{"type":"number"},"harvest_date":{"type":"string"},"status":{"type":"string","enum":["In-Field","Harvested","Sold","Stored"]}},"required":["action"]})

manage_note_tool = FunctionDeclaration(name="alloydb_notes",
    description="Create, list, search, update, or delete notes in AlloyDB.",
    parameters={"type":"object","properties":{"action":{"type":"string","enum":["create","list","search","update","delete"]},"note_id":{"type":"integer"},"farmer_id":{"type":"integer"},"title":{"type":"string"},"content":{"type":"string"},"tags":{"type":"string"},"search_query":{"type":"string"}},"required":["action"]})

google_calendar_tool = FunctionDeclaration(name="google_calendar",
    description="Manage Google Calendar via MCP (list_events, create_event, update_event, delete_event). Use time_min/time_max for date filtering.",
    parameters={"type":"object","properties":{"action":{"type":"string","enum":["list_events","create_event","update_event","delete_event"]},"title":{"type":"string"},"start_datetime":{"type":"string"},"end_datetime":{"type":"string"},"description":{"type":"string"},"location":{"type":"string"},"add_meet_link":{"type":"boolean"},"event_id":{"type":"string"},"max_results":{"type":"integer"},"time_min":{"type":"string","description":"ISO 8601 lower bound for list_events"},"time_max":{"type":"string","description":"ISO 8601 upper bound for list_events"}},"required":["action"]})

google_tasks_tool = FunctionDeclaration(name="google_tasks",
    description="Manage Google Tasks via MCP (list_tasks, create_task, update_task, delete_task).",
    parameters={"type":"object","properties":{"action":{"type":"string","enum":["list_tasks","create_task","update_task","delete_task"]},"title":{"type":"string"},"notes":{"type":"string"},"due_date":{"type":"string"},"task_id":{"type":"string"},"status":{"type":"string"}},"required":["action"]})

google_maps_tool = FunctionDeclaration(name="google_maps",
    description="Google Maps via MCP: embed_map, search_location, directions (origin+destination), nearby_search (location+keyword).",
    parameters={"type":"object","properties":{"action":{"type":"string","enum":["embed_map","search_location","directions","nearby_search"]},"location":{"type":"string"},"zoom":{"type":"integer"},"origin":{"type":"string"},"destination":{"type":"string"},"keyword":{"type":"string"},"radius_m":{"type":"integer"}},"required":["action"]})

# Primary Agent delegation tools
ask_db_agent_tool = FunctionDeclaration(name="ask_db_agent",
    description="Delegate to the Database Specialist Agent for ANY query about farmers, crops, inventory, analytics, tasks, farmer management, or inventory management.",
    parameters={"type":"object","properties":{"instruction":{"type":"string"}},"required":["instruction"]})

ask_google_agent_tool = FunctionDeclaration(name="ask_google_agent",
    description="Delegate to the Google Workspace Agent for calendar, tasks, or maps operations.",
    parameters={"type":"object","properties":{"instruction":{"type":"string"}},"required":["instruction"]})

ask_notes_agent_tool = FunctionDeclaration(name="ask_notes_agent",
    description="Delegate to the Notes & Knowledge Agent for creating, searching, listing, or deleting notes.",
    parameters={"type":"object","properties":{"instruction":{"type":"string"}},"required":["instruction"]})


# ═══════════════════════════════════════════════════════════════════════════════
# AGENT PROMPTS — OPTIMISED FOR SPEED + QUALITY
# ═══════════════════════════════════════════════════════════════════════════════

def build_primary_prompt():
    return f"""Today is {datetime.now().strftime('%A, %B %d, %Y')}. You are AgroSync Intelligence — the Primary Coordinator of an APAC agricultural multi-agent system powered by Gemini 2.5 Flash.

You have THREE specialist sub-agents. You NEVER call tools directly — you delegate:
1. Database Specialist (ask_db_agent): AlloyDB queries, analytics, task/farmer/inventory CRUD.
2. Google Workspace Specialist (ask_google_agent): Google Calendar, Tasks, Maps.
3. Notes & Knowledge Specialist (ask_notes_agent): Note creation, search, listing, deletion.

RULES:
- Never guess data. Always delegate.
- Provide DETAILED instructions with full context from conversation history.
- MULTI-SYSTEM SYNC: "Create a task" for a farmer → call BOTH ask_google_agent AND ask_db_agent.
- Pass through Markdown tables and Maps HTML snippets from sub-agents verbatim — do NOT reformat or summarize tables.
- After completing a request, mention any noteworthy insight (overdue tasks, upcoming harvests).
- When sub-agent returns data with tables, pass the ENTIRE table through unchanged. Do NOT truncate.
- Be concise in your own commentary. Let the data speak.
"""

def build_db_prompt():
    return f"""Today is {datetime.now().strftime('%Y-%m-%d')}. You are the AgroSync Database Specialist Agent (Gemini). You call tools via MCP to manage AlloyDB.

TOOLS: alloydb_query, alloydb_analytics, alloydb_manage_task, alloydb_manage_farmer, alloydb_manage_inventory, alloydb_notes

RESPONSE FORMAT RULES — CRITICAL:
- ALWAYS present query results as clean Markdown tables.
- Use section headers like **Stock Extremes (Farmers)** or **Stock Extremes (Crops)** to organize output.
- For stock extremes, show TWO tables: one for farmer-level extremes (with columns: Label, Farmer, Country, Sub_Region, Crop Name, Stock) and one for crop-level totals (Crop Name, Total Stock) sorted descending. Add a 📌 insight line after each table.
- For harvest date questions, compute days from today ({datetime.now().strftime('%Y-%m-%d')}) and state which crop has longest/shortest time to harvest.
- Include ALL relevant columns. Never omit farmer, country, sub_region, crop_name, or stock from results.
- ID fields (__internal__*_id) are for mutation tools only. Never show them to users.
- For DELETE: call alloydb_query first, disambiguate if multiple matches.
- For INVENTORY CRUD: use alloydb_manage_inventory (create/update/delete). Resolve farmer_id via alloydb_query first. Statuses: In-Field, Harvested, Sold, Stored.
- For FARMER DELETE: use alloydb_manage_farmer(action='delete'). This cascades and removes their inventory and tasks too — warn the user.
- For UPDATE: call alloydb_query first to get task_id, then alloydb_manage_task(action='update').
- For ANALYTICS: use alloydb_analytics with the correct metric name.
- For questions about "who has highest/lowest stock", use metric stock_extremes.
- For questions about "which crop is highest/lowest stocked", use metric stock_by_crop with appropriate order.
- For harvest date analysis, use metric harvest_upcoming with a large days_ahead (e.g. 365).
- ONLY use data from tool results. Never hallucinate.
- Be thorough. Answer ALL parts of the user's question in a single response.

CREATE / UPDATE FIELD RULES — CRITICAL:
When the user asks to CREATE or UPDATE a record but has NOT provided all the necessary fields, DO NOT call the tool yet. Instead, present the required fields as a clean Markdown form so the user knows exactly what to fill in. Pre-fill any values already mentioned. Use this format:

**📝 To create a new [Farmer/Task/Inventory Item/Note], please provide:**

| Field | Your Value |
|---|---|
| **Name** | _(required)_ |
| **Gender** | _(Male/Female)_ |
| ... | ... |

Here are the fields per table (NEVER show *_id columns — those are auto-generated):

**Farmers** — name *(required)*, gender, contact, city, country, sub_region
**Tasks** — farmer name *(required, to resolve farmer_id)*, title *(required)*, description, due_date (YYYY-MM-DD), priority (High/Medium/Low)
**Inventory** — farmer name *(required, to resolve farmer_id)*, crop_name *(required)*, stock *(required)*, harvest_date (YYYY-MM-DD), status (In-Field/Harvested/Sold/Stored)
**Notes** — title *(required)*, content *(required)*, tags (comma-separated, optional), farmer name (optional, to link note)

If the user HAS provided all required fields, proceed directly — call alloydb_query to resolve any farmer_id needed, then call the appropriate tool.
For UPDATE, always call alloydb_query first to find the existing record, then show current values alongside the fields the user can change.
"""

def build_google_prompt():
    today = datetime.now()
    tomorrow = today + timedelta(days=1)
    return f"""Today is {today.strftime('%A, %B %d, %Y')}. Tomorrow is {tomorrow.strftime('%A, %B %d, %Y')}.

You are the AgroSync Google Workspace Specialist Agent (Gemini). You call tools via MCP.
You have FULL CREATE, READ, UPDATE, and DELETE capabilities for ALL of these:

TOOLS:
1. **google_calendar** — actions: list_events, create_event, update_event, delete_event
   - list_events: use time_min/time_max (ISO 8601) to filter by date range. Example for tomorrow: time_min="{tomorrow.strftime('%Y-%m-%d')}T00:00:00+05:30", time_max="{tomorrow.strftime('%Y-%m-%d')}T23:59:59+05:30"
   - create_event: requires title, start_datetime, end_datetime (ISO 8601 with timezone e.g. 2025-01-15T10:00:00+05:30)
   - update_event: requires event_id (call list_events first to get it)
   - delete_event: requires event_id (call list_events first to get it)
2. **google_tasks** — actions: list_tasks, create_task, update_task, delete_task
   - create_task: requires title. Optional: notes, due_date (RFC 3339)
   - update_task/delete_task: requires task_id (call list_tasks first)
3. **google_maps** — actions: embed_map, search_location, directions, nearby_search
   - embed_map/search_location: requires location
   - directions: requires origin + destination
   - nearby_search: requires location + keyword

CRITICAL RULES:
- You CAN and MUST access Google Calendar, Tasks, and Maps. These are your primary tools.
- For ANY delete/update request: ALWAYS call list first to get IDs, then show the user what you found and confirm before deleting.
- For date-relative queries ("tomorrow", "next week"), compute the correct ISO dates using today's date above.
- For create_event: use ISO 8601 datetimes with timezone +05:30.
- ALWAYS pass through maps_snippet HTML verbatim in your response.
- NEVER say you cannot access Google services. You have full access via MCP tools.

CREATE / UPDATE FIELD RULES:
When the user asks to CREATE or UPDATE but has NOT provided all required fields, present them as a Markdown table:

**Calendar Event** — title *(required)*, date *(required)*, start time *(required)*, duration/end time, description, location, add Google Meet link (yes/no)
**Google Task** — title *(required)*, notes, due_date (YYYY-MM-DD)

If all required fields are provided, proceed directly with the tool call.
For UPDATE, call list first to find the event/task, then show current values alongside editable fields.
Return clean summaries."""

def build_notes_prompt():
    return """You are the AgroSync Notes & Knowledge Specialist Agent (Gemini). You call tools via MCP.

TOOLS: alloydb_notes, alloydb_query (to resolve farmer IDs)
RULES:
- Always call the tool. Never invent note contents. Return clean Markdown.

CREATE / UPDATE FIELD RULES:
When the user asks to CREATE or UPDATE a note but has NOT provided all required fields, present them:

**Note** — title *(required)*, content *(required)*, tags (comma-separated, optional), farmer name (optional, to link)

If all required fields are provided, proceed directly. For UPDATE, call list/search first to find the note, then show current values."""


# ═══════════════════════════════════════════════════════════════════════════════
# SUB-AGENT EXECUTION — ALL tool calls go through MCP
# ═══════════════════════════════════════════════════════════════════════════════

def _run_safe(runner, instruction, access_token, name, request_id=None):
    for attempt in range(3):
        try:
            return runner(instruction, access_token, request_id)
        except Exception as e:
            err = str(e)
            if ("429" in err or "RESOURCE_EXHAUSTED" in err) and attempt < 2:
                wait = 2 ** (attempt + 1)  # 2s, 4s
                if request_id: push_status(request_id, f"Rate limited — retrying in {wait}s…")
                time.sleep(wait)
                continue
            return f"[{name} Error] {err[:300]}"

def _execute_tool_via_mcp(call_name, call_args, access_token, request_id=None):
    args = dict(call_args)
    if call_name.startswith("google_") and access_token:
        args["access_token"] = access_token

    # Push live status
    status_map = {
        "alloydb_query": "Querying AlloyDB…",
        "alloydb_analytics": "Running analytics on AlloyDB…",
        "alloydb_manage_task": "Managing tasks in AlloyDB…",
        "alloydb_manage_farmer": "Updating farmer records…",
        "alloydb_manage_inventory": "Managing inventory in AlloyDB…",
        "alloydb_notes": "Accessing notes in AlloyDB…",
        "google_calendar": "Talking to Google Calendar…",
        "google_tasks": "Syncing with Google Tasks…",
        "google_maps": "Fetching map data…",
    }
    if request_id:
        push_status(request_id, status_map.get(call_name, f"Calling {call_name}…"))

    return mcp.call_tool(call_name, args)

def _run_sub_agent(prompt_fn, tool_declarations, instruction, access_token, request_id=None):
    tools = Tool(function_declarations=tool_declarations)
    model = GenerativeModel(MODEL_ID, tools=[tools], system_instruction=prompt_fn())
    chat = model.start_chat()
    response = chat.send_message(instruction)

    for _ in range(4):  # reduced from 6 to 4 for speed
        if not response.candidates or not response.candidates[0].content.parts: break
        fn_calls = [p.function_call for p in response.candidates[0].content.parts if hasattr(p, 'function_call') and p.function_call]
        if not fn_calls: break

        tool_results = []
        for call in fn_calls:
            result = _execute_tool_via_mcp(call.name, dict(call.args), access_token, request_id)
            tool_results.append(Part.from_function_response(name=call.name, response={"content": result}))
        response = chat.send_message(tool_results)

    return "".join(p.text for p in response.candidates[0].content.parts if hasattr(p, 'text') and p.text) or "Agent completed."

def run_db_agent(instruction, access_token, request_id=None):
    if request_id: push_status(request_id, "Database Agent activated…")
    return _run_sub_agent(build_db_prompt,
        [get_data_tool, manage_task_tool, get_analytics_tool, manage_farmer_tool, manage_inventory_tool, manage_note_tool],
        instruction, access_token, request_id)

def run_google_agent(instruction, access_token, request_id=None):
    if request_id: push_status(request_id, "Google Workspace Agent activated…")
    return _run_sub_agent(build_google_prompt,
        [google_calendar_tool, google_tasks_tool, google_maps_tool],
        instruction, access_token, request_id)

def run_notes_agent(instruction, access_token, request_id=None):
    if request_id: push_status(request_id, "Notes Agent activated…")
    return _run_sub_agent(build_notes_prompt,
        [manage_note_tool, get_data_tool],
        instruction, access_token, request_id)


# ═══════════════════════════════════════════════════════════════════════════════
# FLASK ROUTES
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/')
def index(): return render_template('index.html')

@app.route('/config')
def get_config():
    return jsonify({'google_client_id': GOOGLE_CLIENT_ID, 'maps_api_key': MAPS_API_KEY})

@app.route('/health')
def health():
    try:
        with get_engine().connect() as c: c.execute(text("SELECT 1"))
        return jsonify({"status": "ok", "db": "connected", "mcp": mcp.is_connected}), 200
    except Exception as e:
        return jsonify({"status": "error", "db": str(e)}), 500

@app.route('/summary')
def get_summary():
    try:
        result = mcp.call_tool("alloydb_analytics", {"metric": "region_crop_summary"})
        data = json.loads(result)
        if isinstance(data, list):
            return jsonify({"details": [{"country":r.get("country"),"sub_region":r.get("sub_region"),"crops":r.get("crops") or "No Data","farmer_count":r.get("farmer_count"),"total_stock":r.get("total_stock")} for r in data]})
        return jsonify({"details": [], "note": data.get("message", "No data")})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/alerts')
@require_api_key
def get_alerts():
    try:
        result = mcp.call_tool("alloydb_analytics", {"metric": "alerts_combined"})
        return jsonify(json.loads(result))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ─── MCP PROXY ENDPOINTS ─────────────────────────────────────────────────────

@app.route('/mcp/calendar', methods=['POST'])
def mcp_calendar_proxy():
    try:
        body = request.json or {}
        token = body.pop("access_token", "")
        if not token: return jsonify({"error": "access_token required"}), 401
        body["access_token"] = token
        result = mcp.call_tool("google_calendar", body)
        return jsonify(json.loads(result))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/mcp/tasks', methods=['POST'])
def mcp_tasks_proxy():
    try:
        body = request.json or {}
        token = body.pop("access_token", "")
        if not token: return jsonify({"error": "access_token required"}), 401
        body["access_token"] = token
        result = mcp.call_tool("google_tasks", body)
        return jsonify(json.loads(result))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/mcp/tools')
def mcp_tools():
    if mcp.is_connected:
        return jsonify({"protocol":"MCP","version":"2024-11-05","serverInfo":{"name":"AgroSync MCP Server","version":"1.0.0"},"tools":mcp._tools,"status":"connected"})
    return jsonify({"status":"disconnected","error":mcp._error}), 503

@app.route('/mcp/maps_snippet', methods=['POST'])
def mcp_maps_snippet():
    try:
        body = request.json or {}
        loc = body.get("location","").strip()
        if not loc: return jsonify({"error":"location required"}), 400
        result = mcp.call_tool("google_maps", {"action":"embed_map","location":loc,"zoom":int(body.get("zoom",13))})
        return jsonify(json.loads(result))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/docs')
def api_docs():
    return jsonify({
        "info": {"title":"AgroSync Intelligence API","version":"2.0.0"},
        "architecture": "Gemini 2.5 Flash (Primary + 3 Sub-Agents) → MCP Client → mcp_server.py → Google APIs + AlloyDB",
    })

# ═══════════════════════════════════════════════════════════════════════════════
# SSE STATUS STREAM
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/status/<request_id>')
def status_stream(request_id):
    def generate():
        q = queue.Queue()
        _status_queues[request_id] = q
        try:
            while True:
                try:
                    msg = q.get(timeout=60)
                    if msg == "__DONE__":
                        yield f"data: {json.dumps({'done': True})}\n\n"
                        break
                    yield f"data: {json.dumps({'status': msg})}\n\n"
                except queue.Empty:
                    yield f"data: {json.dumps({'status': 'Still processing…'})}\n\n"
        finally:
            _status_queues.pop(request_id, None)

    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})


# ═══════════════════════════════════════════════════════════════════════════════
# LOCAL INTENT ROUTER — skips the Primary Coordinator to save 1-2 Gemini calls
# ═══════════════════════════════════════════════════════════════════════════════

_DB_KEYWORDS = re.compile(
    r'farmer|crop|inventory|stock|harvest|task|analytics|query|who has|highest|lowest|'
    r'overdue|pending|create.*task|delete.*task|update.*task|how many|count|total|'
    r'show me|list.*farmer|list.*task|list.*inventory|diversity|region|country|'
    r'sub.?region|priority|status|gender|city|contact|manage|profile|'
    r'add.*crop|add.*inventory|remove.*crop|remove.*inventory|update.*stock|'
    r'delete.*farmer|remove.*farmer|add.*farmer|insert',
    re.IGNORECASE
)
_GOOGLE_KEYWORDS = re.compile(
    r'calendar|schedule|meeting|event|google task|map|maps|location|venue|'
    r'remind|appointment|google|tomorrow|next week|direction|navigate|nearby|'
    r'delete.*event|delete.*meeting|cancel.*meeting|reschedule',
    re.IGNORECASE
)
_NOTES_KEYWORDS = re.compile(
    r'note|notes|knowledge|memo|write down|jot|remember this',
    re.IGNORECASE
)

def _detect_intent(query):
    """Return agent runner(s) to call directly, or None to use primary coordinator."""
    q = query.lower()
    db_match = bool(_DB_KEYWORDS.search(q))
    google_match = bool(_GOOGLE_KEYWORDS.search(q))
    notes_match = bool(_NOTES_KEYWORDS.search(q))

    hits = sum([db_match, google_match, notes_match])

    # Single clear intent → skip primary coordinator
    if hits == 1:
        if db_match: return [("DB Agent", run_db_agent)]
        if google_match: return [("Google Agent", run_google_agent)]
        if notes_match: return [("Notes Agent", run_notes_agent)]

    # Multi-intent (e.g. "create a task and a calendar event") → both agents in parallel
    if hits >= 2:
        agents = []
        if db_match: agents.append(("DB Agent", run_db_agent))
        if google_match: agents.append(("Google Agent", run_google_agent))
        if notes_match: agents.append(("Notes Agent", run_notes_agent))
        return agents

    # No clear match → fall through to primary coordinator
    return None


# ═══════════════════════════════════════════════════════════════════════════════
# CHAT ROUTE — with fast local routing
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/ask', methods=['POST'])
@require_api_key
def handle_query():
    try:
        payload = request.json or {}
        user_input = payload.get("query", "").strip()
        access_token = payload.get("access_token", "")
        request_id = payload.get("request_id", "")

        if not user_input:
            return jsonify({"agent_response": "Please enter a message."})

        if re.fullmatch(r'(hi|hello|hey|howdy|hola)[\s!.]*', user_input.lower()):
            session['history'] = []
            return jsonify({"agent_response": (
                "### 👋 Welcome to AgroSync Intelligence.\n"
                "I am the Primary Coordinator — powered by **Gemini 2.5 Flash** with tools served via **MCP**.\n\n"
                "**AlloyDB (via MCP):** Query/create/update farmers, inventory, tasks, notes; 21+ analytics metrics\n"
                "**Google Services (via MCP):** Calendar, Tasks, Maps\n\n"
                "What would you like to know?"
            )})

        if 'history' not in session: session['history'] = []

        if request_id:
            push_status(request_id, "Analyzing your request…")

        # ─── FAST PATH: local intent routing (skips primary coordinator) ───
        detected = _detect_intent(user_input)
        if detected:
            if request_id:
                push_status(request_id, f"Routing directly to {detected[0][0]}…")

            if len(detected) == 1:
                # Single agent — direct call
                name, runner = detected[0]
                final = _run_safe(runner, user_input, access_token, name, request_id)
            else:
                # Multiple agents in parallel
                futures = {}
                for name, runner in detected:
                    futures[agent_executor.submit(_run_safe, runner, user_input, access_token, name, request_id)] = name
                parts = []
                for future in as_completed(futures):
                    parts.append(future.result())
                final = "\n\n---\n\n".join(parts)

            if not final or final.strip() == "":
                final = "No results found."

            session['history'].append({"role": "user", "text": user_input})
            session['history'].append({"role": "model", "text": final})
            if len(session['history']) > 16: session['history'] = session['history'][-16:]
            session.modified = True

            if request_id: close_status(request_id)
            return jsonify({"agent_response": final})

        # ─── SLOW PATH: use primary coordinator for ambiguous queries ───
        if request_id: push_status(request_id, "Using primary coordinator…")

        primary_tools = Tool(function_declarations=[ask_db_agent_tool, ask_google_agent_tool, ask_notes_agent_tool])
        model = GenerativeModel(MODEL_ID, tools=[primary_tools], system_instruction=build_primary_prompt())
        gemini_history = [Content(role="user" if t["role"]=="user" else "model", parts=[Part.from_text(t["text"])]) for t in session['history'][-6:]]
        chat = model.start_chat(history=gemini_history)

        for attempt in range(2):
            try:
                if request_id: push_status(request_id, "Routing to specialist agents…")
                response = chat.send_message(user_input)

                for _ in range(4):
                    if not response.candidates or not response.candidates[0].content.parts: break
                    fn_calls = [p.function_call for p in response.candidates[0].content.parts if hasattr(p,'function_call') and p.function_call]
                    if not fn_calls: break

                    tool_results = []
                    agent_map = {
                        "ask_db_agent": ("DB Agent", run_db_agent),
                        "ask_google_agent": ("Google Agent", run_google_agent),
                        "ask_notes_agent": ("Notes Agent", run_notes_agent),
                    }

                    if len(fn_calls) > 1:
                        futures = {}
                        for call in fn_calls:
                            name, runner = agent_map.get(call.name, ("Unknown", None))
                            inst = dict(call.args).get("instruction", "")
                            if runner:
                                futures[agent_executor.submit(_run_safe, runner, inst, access_token, name, request_id)] = call
                        for future in as_completed(futures):
                            call = futures[future]
                            tool_results.append(Part.from_function_response(name=call.name, response={"content": future.result()}))
                    else:
                        for call in fn_calls:
                            name, runner = agent_map.get(call.name, ("Unknown", None))
                            inst = dict(call.args).get("instruction", "")
                            reply = _run_safe(runner, inst, access_token, name, request_id) if runner else "Unknown agent."
                            tool_results.append(Part.from_function_response(name=call.name, response={"content": reply}))

                    if request_id: push_status(request_id, "Composing final response…")
                    response = chat.send_message(tool_results)

                final = "".join(p.text for p in response.candidates[0].content.parts if hasattr(p,'text') and p.text) or "Done."
                session['history'].append({"role":"user","text":user_input})
                session['history'].append({"role":"model","text":final})
                if len(session['history']) > 16: session['history'] = session['history'][-16:]
                session.modified = True

                if request_id: close_status(request_id)
                return jsonify({"agent_response": final})

            except Exception as e:
                err = str(e)
                if ("429" in err or "RESOURCE_EXHAUSTED" in err) and attempt < 1:
                    wait = 3 * (attempt + 1)
                    if request_id: push_status(request_id, f"Rate limited — retrying in {wait}s…")
                    time.sleep(wait); continue
                raise
    except Exception as e:
        if request_id: close_status(request_id)
        return jsonify({"agent_response": f"### ⚠️ System Error\n```\n{str(e)}\n```"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)