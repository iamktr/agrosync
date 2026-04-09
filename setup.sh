#!/bin/bash

# 1. Create the root directory and navigate into it
echo "Creating root directory 'agrosync'..."
mkdir -p agrosync
cd agrosync

# 2. Create the templates directory
echo "Creating 'templates' directory..."
mkdir -p templates

# 3. Generate all files using Heredocs
echo "Creating deploy.sh..."
cat << 'EOF_DEPLOY' > deploy.sh
#!/bin/bash

# Configuration
SERVICE_NAME="agrosync"
REGION="us-central1"
PROJECT_ID="cohort-1-hackathon"
NETWORK=$(gcloud compute networks subnets describe agrosync-subnet --region=us-central1 --format="value(network.basename())")
SUBNET="agrosync-subnet"

# Environment Variables (Ensure these match your GCP Console values)
DB_USER="postgres"
DB_PASS=""
DB_NAME="postgres"
DB_HOST=""
MAPS_API_KEY=""
GOOGLE_CLIENT_ID=""
GOOGLE_CLIENT_SECRET=""

# The key you just updated
FLASK_SECRET_KEY="flasksecretkeyforagrosync"
echo "🚀 Deploying $SERVICE_NAME to Cloud Run..."

# Enable Required APIs
gcloud services enable \
    aiplatform.googleapis.com \
    calendar-json.googleapis.com \
    tasks.googleapis.com \
    maps-embed-backend.googleapis.com \
    run.googleapis.com

# Deploy to Cloud Run (With Split-Routing Egress)
gcloud run deploy $SERVICE_NAME \
  --source . \
  --region $REGION \
  --project $PROJECT_ID \
  --network=$NETWORK \
  --subnet=$SUBNET \
  --vpc-egress=private-ranges-only \
  --memory=1024Mi \
  --allow-unauthenticated \
  --set-env-vars FLASK_SECRET_KEY="$FLASK_SECRET_KEY",DB_USER="$DB_USER",DB_PASS="$DB_PASS",DB_NAME="$DB_NAME",DB_HOST="$DB_HOST",MAPS_API_KEY="$MAPS_API_KEY",GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID",GOOGLE_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET"
EOF_DEPLOY

echo "Creating app.py..."
cat << 'EOF_APP' > app.py
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
EOF_APP

echo "Creating Dockerfile..."
cat << 'EOF_DOCKER' > Dockerfile
FROM python:3.11-slim
WORKDIR /app

# 1. Create a virtual environment inside the container
RUN python -m venv /opt/venv
# 2. Tell the container to use the virtual environment's path
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
# 3. Pip install now runs safely inside the venv, silencing the warning
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 app:app
EOF_DOCKER

echo "Creating mcp_server.py..."
cat << 'EOF_MCP' > mcp_server.py
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
EOF_MCP

echo "Creating requirements.txt..."
cat << 'EOF_REQS' > requirements.txt
sqlalchemy
sqlalchemy[asyncio]
asyncpg
pg8000
flask
python-dotenv
pandas
gunicorn
vertexai
mcp
httpx
google-auth
google-cloud-aiplatform
google-api-python-client
google-auth-httplib2
google-auth-oauthlib
EOF_REQS

echo "Creating setup-infra.sh..."
cat << 'EOF_INFRA' > setup-infra.sh
#!/bin/bash

# Infrastructure Variables
export PROJECT_ID="cohort-1-hackathon"
export REGION="us-central1"
export NETWORK="agrosync-vpc"
export SUBNET="agrosync-subnet"
export CLUSTER="agrosync-cluster"
export INSTANCE="agrosync-cluster-primary"
export DB_PASS="Cohort1HackPass!"

echo "Starting Clean Infrastructure Provisioning for $PROJECT_ID..."

echo "1. Enabling required Google Cloud APIs..."
gcloud services enable compute.googleapis.com \
    alloydb.googleapis.com \
    servicenetworking.googleapis.com \
    --project=$PROJECT_ID

echo "2. Creating Custom VPC Network..."
gcloud compute networks create $NETWORK \
    --subnet-mode=custom \
    --project=$PROJECT_ID || echo "✓ VPC already exists, moving on..."

echo "3. Creating Hackathon-Ready Firewall Rules..."
echo "  -> Allowing internal traffic within the subnet..."
gcloud compute firewall-rules create agrosync-allow-internal \
    --network=$NETWORK \
    --allow tcp,udp,icmp \
    --source-ranges=10.0.0.0/24 \
    --project=$PROJECT_ID || echo "✓ Internal firewall rule already exists, moving on..."

echo "  -> Allowing Web, DB, SSH, RDP, and Ping from anywhere (For Judges)..."
gcloud compute firewall-rules create agrosync-allow-external \
    --network=$NETWORK \
    --allow tcp:22,tcp:80,tcp:443,tcp:3389,tcp:5432,tcp:8080,icmp \
    --source-ranges=0.0.0.0/0 \
    --project=$PROJECT_ID || echo "✓ External firewall rule already exists, moving on..."

echo "4. Creating Subnet..."
gcloud compute networks subnets create $SUBNET \
    --network=$NETWORK \
    --region=$REGION \
    --range=10.0.0.0/24 \
    --project=$PROJECT_ID || echo "✓ Subnet already exists, moving on..."

echo "5. Allocating IP Range for Google Private Services Access..."
gcloud compute addresses create google-managed-services-$NETWORK \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length=24 \
    --description="Peering range for Google Services" \
    --network=$NETWORK \
    --project=$PROJECT_ID || echo "✓ IP Range already allocated, moving on..."

echo "6. Establishing VPC Peering Connection (Fixes NETWORK_NOT_PEERED error)..."
gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges=google-managed-services-$NETWORK \
    --network=$NETWORK \
    --project=$PROJECT_ID || echo "✓ VPC Peering already exists, moving on..."

echo "7. Creating AlloyDB Cluster..."
gcloud alloydb clusters create $CLUSTER \
    --password=$DB_PASS \
    --region=$REGION \
    --network=$NETWORK \
    --project=$PROJECT_ID || echo "✓ Cluster already exists, moving on..."

echo "8. Creating Primary Instance (Private First to bypass Catch-22)..."
echo "(Grab a coffee ☕ - This takes 10 to 15 minutes to provision)"
gcloud alloydb instances create $INSTANCE \
    --cluster=$CLUSTER \
    --instance-type=PRIMARY \
    --cpu-count=2 \
    --region=$REGION \
    --project=$PROJECT_ID || echo "✓ Instance already built, moving on..."

echo "9. Enforcing Secure Password on the Default User..."
gcloud alloydb users set-password postgres \
    --cluster=$CLUSTER \
    --region=$REGION \
    --password=$DB_PASS \
    --project=$PROJECT_ID

echo "10. Opening the Gates: Enabling Public IP & Complexity Rules..."
gcloud alloydb instances update $INSTANCE \
    --cluster=$CLUSTER \
    --region=$REGION \
    --assign-inbound-public-ip=ASSIGN_IPV4 \
    --authorized-external-networks=0.0.0.0/0 \
    --database-flags="password.enforce_complexity=on" \
    --project=$PROJECT_ID

echo "===================================================="
echo "Infrastructure Provisioning 100% Complete!"
echo "Your Database is now built, peered, public, and secure."
echo "===================================================="
EOF_INFRA

echo "Creating index.html..."
cat << 'EOF_INDEX' > templates/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
    <title>AgroSync</title>

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Syne:wght@600;700;800&family=Outfit:wght@300;400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">

    <script src="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/js/all.min.js" defer></script>

    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/dompurify/3.0.3/purify.min.js"></script>

    <script src="https://accounts.google.com/gsi/client" async defer></script>

    <script>window.__mapsLoaded = false;</script>

    <style>
    /* ═══════════════════════════════════════════════════════
        TOKENS
    ═══════════════════════════════════════════════════════ */
    :root {
        --bg-void:          #0f1419;
        --bg-surface:       #161b22;
        --bg-raised:        #1c2128;
        --bg-glass:         rgba(22, 27, 34, 0.9);
        --border:           rgba(255,255,255,0.06);
        --border-strong:    rgba(255,255,255,0.1);
        --accent:           #8de4ad;
        --accent-dim:       rgba(141,228,173,0.08);
        --accent-glow:      rgba(141,228,173,0.15);
        --google-blue:      #4285f4;
        --google-blue-dim:  rgba(66, 133, 244, 0.1);
        --text-primary:     #d1d5db;
        --text-secondary:   #8b949e;
        --text-muted:       #484f58;
        --red:              #f85149;
        --sidebar-w:        270px;
        --intel-w:          340px;
        --header-h:         60px;
        --radius:           10px;
        --radius-lg:        14px;
        --shadow-card:      0 2px 12px rgba(0,0,0,0.3);
        --shadow-modal:     0 16px 48px rgba(0,0,0,0.5);
        --font-ui:          'Outfit', sans-serif;
        --font-display:     'Syne', sans-serif;
        --font-mono:        'JetBrains Mono', monospace;
        --transition:       all 0.18s ease;
    }

    /* Light mode — auto OS theme */
    @media (prefers-color-scheme: light) {
        :root {
            --bg-void:         #f6f8fa;
            --bg-surface:      #ffffff;
            --bg-raised:       #f0f2f5;
            --bg-glass:        rgba(255,255,255,0.92);
            --border:          rgba(0,0,0,0.06);
            --border-strong:   rgba(0,0,0,0.1);
            --accent:          #16a34a;
            --accent-dim:      rgba(22,163,74,0.06);
            --accent-glow:     rgba(22,163,74,0.1);
            --google-blue:     #1a73e8;
            --google-blue-dim: rgba(26,115,232,0.06);
            --text-primary:    #1f2328;
            --text-secondary:  #57606a;
            --text-muted:      #8b949e;
            --red:             #cf222e;
            --shadow-card:     0 1px 4px rgba(0,0,0,0.06);
            --shadow-modal:    0 8px 30px rgba(0,0,0,0.12);
        }
    }

    /* ═══════════════════════════════════════════════════════
        RESET & BASE
    ═══════════════════════════════════════════════════════ */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    html { scroll-behavior: smooth; }

    body {
        font-family: var(--font-ui);
        background: var(--bg-void);
        color: var(--text-primary);
        height: 100dvh;
        display: flex;
        overflow: hidden;
        font-size: 15px;
    }

    /* Clean background — no texture */

    ::-webkit-scrollbar { width: 4px; height: 4px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: var(--border-strong); border-radius: 99px; }

    /* ═══════════════════════════════════════════════════════
        SIDEBAR OVERLAY (mobile backdrop)
    ═══════════════════════════════════════════════════════ */
    #sidebar-overlay {
        display: none;
        position: fixed; inset: 0;
        background: rgba(0,0,0,0.65);
        backdrop-filter: blur(4px);
        z-index: 49;
        animation: fadeIn 0.2s ease;
    }
    #sidebar-overlay.active { display: block; }

    /* ═══════════════════════════════════════════════════════
        SIDEBAR
    ═══════════════════════════════════════════════════════ */
    aside {
        width: var(--sidebar-w);
        min-width: var(--sidebar-w);
        background: var(--bg-surface);
        border-right: 1px solid var(--border);
        display: flex;
        flex-direction: column;
        padding: 0;
        z-index: 50;
        position: relative;
        transition: transform 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        flex-shrink: 0;
    }

    .sidebar-header {
        padding: 1.25rem 1.5rem;
        border-bottom: 1px solid var(--border);
        display: flex;
        align-items: center;
        justify-content: space-between;
    }

    .logo {
        font-family: var(--font-display);
        font-size: 1.1rem;
        font-weight: 800;
        color: var(--accent);
        display: flex;
        align-items: center;
        gap: 10px;
        letter-spacing: -0.02em;
    }

    .logo-icon {
        width: 32px; height: 32px;
        background: var(--accent-dim);
        border: 1px solid rgba(141,228,173,0.25);
        border-radius: 8px;
        display: flex; align-items: center; justify-content: center;
        font-size: 0.85rem;
        color: var(--accent);
        flex-shrink: 0;
    }

    #sidebar-close {
        display: none;
        background: none; border: none;
        color: var(--text-muted); cursor: pointer;
        font-size: 1.1rem; padding: 4px;
        transition: var(--transition);
    }
    #sidebar-close:hover { color: var(--text-primary); }

    .sidebar-body {
        flex: 1;
        overflow-y: auto;
        padding: 1.25rem 1.25rem 0.75rem;
        display: flex;
        flex-direction: column;
        gap: 1rem;
    }

    /* Google user card */
    #google-user-card {
        display: none;
        background: var(--google-blue-dim);
        border: 1px solid rgba(66,133,244,0.2);
        border-radius: var(--radius);
        padding: 0.75rem;
        animation: slideInLeft 0.3s ease;
    }

    #google-user-card.visible { display: flex; align-items: center; gap: 10px; }

    .g-avatar {
        width: 34px; height: 34px;
        border-radius: 50%;
        background: var(--google-blue-dim);
        border: 2px solid rgba(66,133,244,0.3);
        object-fit: cover;
        flex-shrink: 0;
    }

    .g-avatar-placeholder {
        width: 34px; height: 34px;
        border-radius: 50%;
        background: var(--google-blue-dim);
        border: 2px solid rgba(66,133,244,0.3);
        display: flex; align-items: center; justify-content: center;
        font-size: 0.8rem; color: var(--google-blue);
        flex-shrink: 0;
    }

    .g-user-info { flex: 1; min-width: 0; }
    .g-user-name { font-size: 0.8rem; font-weight: 600; color: var(--text-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .g-user-sub  { font-size: 0.7rem; color: var(--google-blue); }

    #g-signout-btn {
        background: none; border: none; cursor: pointer;
        color: var(--text-muted); font-size: 0.75rem;
        padding: 2px 6px; border-radius: 4px;
        transition: var(--transition);
    }
    #g-signout-btn:hover { color: var(--red); background: rgba(239,68,68,0.08); }

    /* Sign-in prompt in sidebar */
    #sidebar-signin-prompt {
        background: var(--accent-dim);
        border: 1px solid rgba(141,228,173,0.15);
        border-radius: var(--radius);
        padding: 0.875rem;
        text-align: center;
    }

    #sidebar-signin-prompt p {
        font-size: 0.75rem;
        color: var(--text-secondary);
        margin-bottom: 0.6rem;
        line-height: 1.4;
    }

    #sidebar-signin-prompt p strong { color: var(--accent); }

    .btn-signin-small {
        display: flex; align-items: center; justify-content: center; gap: 7px;
        width: 100%;
        background: var(--google-blue);
        color: white;
        border: none;
        border-radius: 8px;
        padding: 7px 12px;
        font-size: 0.78rem;
        font-weight: 600;
        cursor: pointer;
        transition: var(--transition);
        font-family: var(--font-ui);
    }
    .btn-signin-small:hover { background: #3367d6; transform: translateY(-1px); }

    /* Summary card */
    .section-label {
        font-size: 0.65rem;
        font-family: var(--font-mono);
        text-transform: uppercase;
        letter-spacing: 0.1em;
        color: var(--text-muted);
        margin-bottom: 0.6rem;
        display: flex; align-items: center; gap: 6px;
    }

    .section-label::after {
        content: ''; flex: 1;
        height: 1px; background: var(--border);
    }

    .live-dot {
        width: 6px; height: 6px;
        background: var(--accent);
        border-radius: 50%;
        animation: pulse-dot 2s ease-in-out infinite;
        flex-shrink: 0;
    }

    @keyframes pulse-dot {
        0%, 100% { opacity: 1; transform: scale(1); }
        50% { opacity: 0.5; transform: scale(0.8); }
    }

    #summary-content {
        max-height: 220px;
        overflow-y: auto;
        font-size: 0.82rem;
    }

    .summary-item {
        padding: 8px 10px;
        border-radius: 8px;
        border: 1px solid var(--border);
        background: var(--bg-raised);
        margin-bottom: 6px;
        transition: var(--transition);
        animation: fadeIn 0.3s ease both;
    }

    .summary-item:hover { border-color: var(--border-strong); }

    .summary-country {
        font-size: 0.78rem;
        font-weight: 600;
        color: var(--accent);
        margin-bottom: 2px;
    }

    .summary-crops {
        font-size: 0.72rem;
        color: var(--text-secondary);
        line-height: 1.4;
    }

    /* Abbreviation box */
    .abbr-box {
        background: var(--bg-raised);
        border: 1px solid var(--border);
        border-radius: var(--radius);
        padding: 0.75rem;
        font-size: 0.75rem;
        color: var(--text-secondary);
        line-height: 1.7;
    }

    .abbr-box .abbr-row { display: flex; gap: 6px; }
    .abbr-box .abbr-key { color: var(--accent); font-weight: 600; font-family: var(--font-mono); font-size: 0.7rem; min-width: 38px; }

    /* Refresh button */
    .sidebar-footer {
        padding: 0.75rem 1.25rem 1rem;
        border-top: 1px solid var(--border);
        margin-top: auto;
    }

    .btn-refresh {
        width: 100%;
        background: var(--bg-raised);
        border: 1px solid var(--border);
        color: var(--text-secondary);
        border-radius: var(--radius);
        padding: 9px;
        font-size: 0.8rem;
        font-weight: 500;
        cursor: pointer;
        display: flex; align-items: center; justify-content: center; gap: 7px;
        transition: var(--transition);
        font-family: var(--font-ui);
    }

    .btn-refresh:hover {
        border-color: var(--accent);
        color: var(--accent);
        background: var(--accent-dim);
    }

    /* ═══════════════════════════════════════════════════════
        MAIN CONTENT
    ═══════════════════════════════════════════════════════ */
    main {
        flex: 1;
        min-width: 0;
        display: flex;
        flex-direction: column;
        background: var(--bg-void);
        position: relative;
        z-index: 1;
    }

    /* ─── Header ─── */
    header {
        height: var(--header-h);
        padding: 0 1.5rem;
        border-bottom: 1px solid var(--border);
        background: var(--bg-surface);
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        flex-shrink: 0;
        position: relative;
        z-index: 20;
    }

    .header-left {
        display: flex; align-items: center; gap: 10px;
    }

    #hamburger {
        display: none;
        background: none; border: none;
        color: var(--text-secondary); cursor: pointer;
        font-size: 1.1rem; padding: 6px;
        border-radius: 6px;
        transition: var(--transition);
    }
    #hamburger:hover { color: var(--text-primary); background: var(--bg-raised); }

    .header-title {
        font-family: var(--font-display);
        font-size: 0.9rem;
        font-weight: 700;
        letter-spacing: -0.01em;
        color: var(--text-primary);
    }

    #db-status {
        font-size: 0.72rem;
        font-family: var(--font-mono);
        color: var(--accent);
        background: var(--accent-dim);
        border: 1px solid rgba(141,228,173,0.2);
        border-radius: 99px;
        padding: 2px 10px;
        display: flex; align-items: center; gap: 5px;
    }

    .header-actions {
        display: flex; align-items: center; gap: 8px;
    }

    .action-btn {
        display: flex; align-items: center; gap: 6px;
        background: var(--bg-raised);
        border: 1px solid var(--border);
        color: var(--text-secondary);
        border-radius: 8px;
        padding: 6px 12px;
        font-size: 0.8rem;
        font-weight: 500;
        cursor: pointer;
        transition: var(--transition);
        font-family: var(--font-ui);
        white-space: nowrap;
    }

    .action-btn:hover {
        border-color: var(--border-strong);
        color: var(--text-primary);
    }

    .action-btn.calendar-btn {
        display: none;
        border-color: rgba(66,133,244,0.25);
        color: var(--google-blue);
    }

    .action-btn.calendar-btn:hover {
        background: var(--google-blue-dim);
        border-color: rgba(66,133,244,0.4);
    }

    .action-btn.calendar-btn.visible { display: flex; }

    .action-btn.map-btn.active {
        border-color: rgba(141,228,173,0.3);
        color: var(--accent);
        background: var(--accent-dim);
    }

    .header-avatar {
        width: 32px; height: 32px;
        border-radius: 50%;
        background: var(--bg-raised);
        border: 1px solid var(--border);
        display: flex; align-items: center; justify-content: center;
        color: var(--text-muted);
        cursor: pointer;
        overflow: hidden;
        transition: var(--transition);
    }

    .header-avatar img { width: 100%; height: 100%; object-fit: cover; }
    .header-avatar:hover { border-color: var(--border-strong); }

    /* ─── Chat Window ─── */
    #chat-window {
        flex: 1;
        padding: 1.5rem;
        overflow-y: auto;
        display: flex;
        flex-direction: column;
        gap: 1.25rem;
    }

    .message {
        max-width: 82%;
        padding: 0.875rem 1.125rem;
        border-radius: var(--radius-lg);
        line-height: 1.6;
        font-size: 0.9rem;
        animation: msgIn 0.25s cubic-bezier(0.34, 1.2, 0.64, 1) both;
    }

    @keyframes msgIn {
        from { opacity: 0; transform: translateY(10px) scale(0.97); }
        to   { opacity: 1; transform: translateY(0)    scale(1); }
    }

    .user-message {
        align-self: flex-end;
        background: #166534;
        color: #fff;
        border-bottom-right-radius: 4px;
    }

    .bot-message {
        align-self: flex-start;
        background: var(--bg-surface);
        border: 1px solid var(--border);
        color: var(--text-primary);
        border-bottom-left-radius: 4px;
    }

    /* Tables inside bot messages */
    .bot-message table {
        width: 100%;
        border-collapse: collapse;
        margin: 0.875rem 0;
        background: var(--bg-raised);
        border-radius: 10px;
        overflow: hidden;
        border: 1px solid var(--border);
        font-size: 0.83rem;
    }

    .bot-message th {
        background: var(--bg-raised);
        color: var(--accent);
        padding: 9px 12px;
        text-align: left;
        font-family: var(--font-mono);
        font-size: 0.7rem;
        text-transform: uppercase;
        letter-spacing: 0.06em;
        border-bottom: 1px solid var(--border-strong);
    }

    .bot-message td {
        padding: 8px 12px;
        border-bottom: 1px solid var(--border);
        color: var(--text-secondary);
    }

    .bot-message tr:last-child td { border-bottom: none; }
    .bot-message tr:hover td { background: rgba(255,255,255,0.02); }

    .bot-message strong { color: var(--text-primary); }
    .bot-message code {
        background: var(--bg-raised);
        border: 1px solid var(--border);
        border-radius: 4px;
        padding: 1px 5px;
        font-family: var(--font-mono);
        font-size: 0.82em;
        color: var(--accent);
    }

    .bot-message ul, .bot-message ol {
        padding-left: 1.25rem;
        margin: 0.4rem 0;
    }

    .bot-message li { margin-bottom: 3px; }

    .bot-message h3 {
        font-family: var(--font-display);
        font-size: 1rem;
        color: var(--text-primary);
        margin-bottom: 0.5rem;
    }

    /* ─── Input Area ─── */
    .prompt-container {
        padding: 0.875rem 1.5rem 1.25rem;
        background: var(--bg-surface);
        border-top: 1px solid var(--border);
        flex-shrink: 0;
    }

    .typing-indicator {
        font-size: 0.78rem;
        color: var(--accent);
        margin-bottom: 8px;
        display: none;
        align-items: center;
        gap: 7px;
        font-family: var(--font-mono);
    }

    /* Live status — appears in chat flow after user message */
    .live-status {
        align-self: flex-start;
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 6px 14px;
        font-size: 0.78rem;
        font-family: var(--font-mono);
        color: var(--accent);
        background: var(--accent-dim);
        border: 1px solid rgba(141,228,173,0.1);
        border-radius: 20px;
        animation: statusFadeIn 0.2s ease both;
        max-width: 80%;
    }
    .live-status .status-dot {
        width: 6px; height: 6px;
        background: var(--accent);
        border-radius: 50%;
        flex-shrink: 0;
        animation: statusBlink 1.2s ease-in-out infinite;
    }
    @keyframes statusBlink {
        0%, 100% { opacity: 1; }
        50% { opacity: 0.3; }
    }
    @keyframes statusFadeIn {
        from { opacity: 0; transform: translateY(4px); }
        to   { opacity: 1; transform: translateY(0); }
    }

    .typing-indicator .dot-row { display: flex; gap: 3px; }

    .typing-indicator .dot {
        width: 5px; height: 5px;
        background: var(--accent);
        border-radius: 50%;
        animation: typingDot 1.4s ease-in-out infinite;
    }

    .typing-indicator .dot:nth-child(2) { animation-delay: 0.2s; }
    .typing-indicator .dot:nth-child(3) { animation-delay: 0.4s; }

    @keyframes typingDot {
        0%, 60%, 100% { transform: translateY(0); opacity: 0.4; }
        30% { transform: translateY(-5px); opacity: 1; }
    }

    .input-wrapper {
        display: flex;
        gap: 10px;
        align-items: center;
    }

    #user-input {
        flex: 1;
        padding: 12px 16px;
        background: var(--bg-surface);
        border: 1px solid var(--border);
        border-radius: var(--radius);
        color: var(--text-primary);
        outline: none;
        font-size: 0.9rem;
        font-family: var(--font-ui);
        transition: var(--transition);
        min-width: 0;
    }

    #user-input::placeholder { color: var(--text-muted); }

    #user-input:focus {
        border-color: rgba(141,228,173,0.4);
        background: var(--bg-raised);
        box-shadow: 0 0 0 3px var(--accent-dim);
    }

    .send-btn {
        width: 44px; height: 44px;
        background: var(--accent);
        border: none;
        border-radius: var(--radius);
        color: white;
        cursor: pointer;
        display: flex; align-items: center; justify-content: center;
        font-size: 0.9rem;
        transition: var(--transition);
        flex-shrink: 0;
    }

    .send-btn:hover {
        filter: brightness(1.15);
        transform: translateY(-1px);
    }

    .send-btn:active { transform: translateY(0); }

    /* ═══════════════════════════════════════════════════════
        INTEL PANEL (Maps + Calendar)
    ═══════════════════════════════════════════════════════ */
    #intel-panel {
        width: var(--intel-w);
        min-width: var(--intel-w);
        background: var(--bg-surface);
        border-left: 1px solid var(--border);
        display: flex;
        flex-direction: column;
        transform: translateX(100%);
        transition: transform 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        position: fixed;
        right: 0; top: 0; bottom: 0;
        z-index: 40;
    }

    #intel-panel.open {
        transform: translateX(0);
    }

    .intel-header {
        height: var(--header-h);
        padding: 0 1.25rem;
        border-bottom: 1px solid var(--border);
        display: flex; align-items: center; justify-content: space-between;
        flex-shrink: 0;
    }

    .intel-title {
        font-family: var(--font-display);
        font-size: 0.85rem;
        font-weight: 700;
        color: var(--text-primary);
        display: flex; align-items: center; gap: 8px;
    }

    .intel-close {
        background: none; border: none;
        color: var(--text-muted); cursor: pointer;
        font-size: 1rem; padding: 4px;
        border-radius: 5px; transition: var(--transition);
    }
    .intel-close:hover { color: var(--text-primary); background: var(--bg-raised); }

    .intel-tabs {
        display: flex;
        border-bottom: 1px solid var(--border);
        padding: 0 1rem;
        gap: 4px;
        flex-shrink: 0;
    }

    .intel-tab {
        background: none; border: none;
        color: var(--text-muted); cursor: pointer;
        font-size: 0.8rem; font-weight: 500;
        padding: 10px 12px;
        border-bottom: 2px solid transparent;
        transition: var(--transition);
        font-family: var(--font-ui);
        display: flex; align-items: center; gap: 5px;
        margin-bottom: -1px;
    }

    .intel-tab.active {
        color: var(--accent);
        border-bottom-color: var(--accent);
    }

    .intel-tab:hover:not(.active) { color: var(--text-secondary); }

    .intel-pane {
        flex: 1;
        display: none;
        flex-direction: column;
        overflow: hidden;
    }

    .intel-pane.active { display: flex; }

    #google-map {
        flex: 1;
        background: var(--bg-raised);
    }

    .map-placeholder {
        flex: 1;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 12px;
        color: var(--text-muted);
        font-size: 0.82rem;
        text-align: center;
        padding: 2rem;
    }

    .map-placeholder i { font-size: 2rem; opacity: 0.3; }
    .map-placeholder code {
        font-family: var(--font-mono);
        font-size: 0.72rem;
        background: var(--bg-raised);
        border: 1px solid var(--border);
        padding: 3px 8px; border-radius: 4px;
        color: var(--accent);
    }

    /* Calendar events pane */
    .calendar-pane-body {
        flex: 1; overflow-y: auto;
        padding: 1rem;
    }

    .cal-event-card {
        background: var(--bg-raised);
        border: 1px solid var(--border);
        border-radius: var(--radius);
        padding: 0.875rem;
        margin-bottom: 8px;
        transition: var(--transition);
        animation: fadeIn 0.3s ease both;
    }

    .cal-event-card:hover { border-color: var(--border-strong); }

    .cal-event-title {
        font-size: 0.83rem; font-weight: 600;
        color: var(--text-primary); margin-bottom: 4px;
    }

    .cal-event-time {
        font-size: 0.74rem; font-family: var(--font-mono);
        color: var(--google-blue);
    }

    .cal-event-empty {
        text-align: center;
        padding: 2rem;
        color: var(--text-muted);
        font-size: 0.82rem;
    }

    .cal-event-empty i { font-size: 1.8rem; opacity: 0.2; display: block; margin-bottom: 10px; }

    .btn-create-event {
        display: flex; align-items: center; justify-content: center; gap: 7px;
        width: calc(100% - 2rem);
        margin: 0.75rem 1rem;
        background: var(--google-blue);
        color: white; border: none;
        border-radius: var(--radius); padding: 10px;
        font-size: 0.83rem; font-weight: 600;
        cursor: pointer; transition: var(--transition);
        font-family: var(--font-ui);
        flex-shrink: 0;
    }
    .btn-create-event:hover { background: #3367d6; transform: translateY(-1px); }

    /* ═══════════════════════════════════════════════════════
        AUTH MODAL
    ═══════════════════════════════════════════════════════ */
    #auth-modal {
        position: fixed; inset: 0;
        background: rgba(4, 7, 16, 0.85);
        backdrop-filter: blur(16px);
        z-index: 100;
        display: flex; align-items: center; justify-content: center;
        padding: 1rem;
        animation: backdropIn 0.3s ease;
    }

    @keyframes backdropIn {
        from { opacity: 0; }
        to   { opacity: 1; }
    }

    #auth-modal.hidden {
        animation: backdropOut 0.25s ease forwards;
        pointer-events: none;
    }

    @keyframes backdropOut {
        to { opacity: 0; }
    }

    .auth-card {
        background: var(--bg-surface);
        border: 1px solid var(--border-strong);
        border-radius: 20px;
        padding: 2.5rem 2rem 2rem;
        max-width: 380px;
        width: 100%;
        box-shadow: var(--shadow-modal);
        text-align: center;
        animation: cardIn 0.35s cubic-bezier(0.34, 1.4, 0.64, 1) both;
        animation-delay: 0.1s;
        position: relative;
    }

    @keyframes cardIn {
        from { opacity: 0; transform: scale(0.9) translateY(20px); }
        to   { opacity: 1; transform: scale(1)   translateY(0); }
    }

    .auth-logo {
        font-family: var(--font-display);
        font-size: 1.5rem; font-weight: 800;
        color: var(--accent);
        margin-bottom: 0.25rem;
        display: flex; align-items: center; justify-content: center; gap: 10px;
    }

    .auth-logo-icon {
        width: 40px; height: 40px;
        background: var(--accent-dim);
        border: 1px solid rgba(141,228,173,0.3);
        border-radius: 10px;
        display: flex; align-items: center; justify-content: center;
        font-size: 1rem; color: var(--accent);
    }

    .auth-subtitle {
        font-size: 0.82rem;
        color: var(--text-muted);
        margin-bottom: 1.75rem;
        font-family: var(--font-mono);
        letter-spacing: 0.04em;
    }

    .auth-feature-list {
        background: var(--bg-raised);
        border: 1px solid var(--border);
        border-radius: var(--radius);
        padding: 1rem;
        margin-bottom: 1.75rem;
        text-align: left;
    }

    .auth-feature {
        display: flex; align-items: flex-start; gap: 10px;
        font-size: 0.82rem; color: var(--text-secondary);
        padding: 5px 0;
    }

    .auth-feature i {
        color: var(--accent); width: 14px;
        margin-top: 1px; flex-shrink: 0;
        font-size: 0.75rem;
    }

    .auth-feature.google i { color: var(--google-blue); }

    .btn-google-signin {
        display: flex; align-items: center; justify-content: center; gap: 10px;
        width: 100%;
        background: #fff;
        color: #3c4043;
        border: 1px solid #dadce0;
        border-radius: 10px;
        padding: 11px 16px;
        font-size: 0.88rem;
        font-weight: 600;
        cursor: pointer;
        transition: var(--transition);
        font-family: var(--font-ui);
        margin-bottom: 10px;
        box-shadow: 0 2px 8px rgba(0,0,0,0.15);
    }

    .btn-google-signin:hover {
        background: #f8f9fa;
        box-shadow: 0 4px 14px rgba(0,0,0,0.2);
        transform: translateY(-1px);
    }

    .google-g {
        width: 20px; height: 20px;
        background: url('https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg') center/contain no-repeat;
        flex-shrink: 0;
    }

    .btn-skip {
        background: var(--bg-raised);
        border: 1px solid var(--border-strong);
        color: var(--text-secondary);
        width: 100%;
        border-radius: 10px;
        padding: 10px;
        font-size: 0.82rem;
        cursor: pointer;
        transition: var(--transition);
        font-family: var(--font-ui);
    }

    .btn-skip:hover { border-color: var(--accent); color: var(--text-primary); background: var(--accent-dim); }

    .auth-disclaimer {
        font-size: 0.72rem;
        color: var(--text-secondary);
        margin-top: 1rem;
        line-height: 1.5;
    }

    /* ═══════════════════════════════════════════════════════
        SCHEDULE MODAL
    ═══════════════════════════════════════════════════════ */
    #schedule-modal {
        position: fixed; inset: 0;
        background: rgba(4, 7, 16, 0.8);
        backdrop-filter: blur(12px);
        z-index: 90;
        display: none; align-items: center; justify-content: center;
        padding: 1rem;
    }

    #schedule-modal.open { display: flex; }

    .schedule-card {
        background: var(--bg-surface);
        border: 1px solid var(--border-strong);
        border-radius: 18px;
        width: 100%;
        max-width: 460px;
        max-height: 90dvh;
        overflow-y: auto;
        box-shadow: var(--shadow-modal);
        animation: cardIn 0.3s cubic-bezier(0.34, 1.3, 0.64, 1);
    }

    .schedule-header {
        padding: 1.5rem 1.5rem 1rem;
        border-bottom: 1px solid var(--border);
        display: flex; align-items: center; justify-content: space-between;
    }

    .schedule-title {
        font-family: var(--font-display);
        font-size: 1rem; font-weight: 700;
        color: var(--text-primary);
        display: flex; align-items: center; gap: 8px;
    }

    .schedule-title i { color: var(--google-blue); }

    .modal-close {
        background: none; border: none;
        color: var(--text-muted); cursor: pointer;
        font-size: 1rem; padding: 4px;
        border-radius: 5px; transition: var(--transition);
    }
    .modal-close:hover { color: var(--text-primary); background: var(--bg-raised); }

    .schedule-body { padding: 1.25rem 1.5rem 1.5rem; }

    .form-group { margin-bottom: 1rem; }

    .form-label {
        display: block;
        font-size: 0.75rem; font-weight: 600;
        color: var(--text-secondary);
        margin-bottom: 5px;
        text-transform: uppercase; letter-spacing: 0.05em;
        font-family: var(--font-mono);
    }

    .form-input, .form-select, .form-textarea {
        width: 100%;
        background: var(--bg-raised);
        border: 1px solid var(--border);
        border-radius: var(--radius);
        color: var(--text-primary);
        padding: 10px 13px;
        font-size: 0.88rem;
        font-family: var(--font-ui);
        outline: none;
        transition: var(--transition);
    }

    .form-input:focus, .form-select:focus, .form-textarea:focus {
        border-color: rgba(66,133,244,0.4);
        box-shadow: 0 0 0 3px var(--google-blue-dim);
    }

    .form-select { appearance: none; cursor: pointer; }

    .form-textarea {
        resize: vertical;
        min-height: 80px;
    }

    .form-row { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }

    .form-check {
        display: flex; align-items: center; gap: 8px;
        font-size: 0.85rem; color: var(--text-secondary);
        cursor: pointer;
    }

    .form-check input[type="checkbox"] {
        width: 16px; height: 16px; cursor: pointer;
        accent-color: var(--google-blue);
    }

    .schedule-footer {
        display: flex; gap: 10px;
        margin-top: 1.25rem;
        padding-top: 1rem;
        border-top: 1px solid var(--border);
    }

    .btn-cancel {
        flex: 1;
        background: var(--bg-raised);
        border: 1px solid var(--border);
        color: var(--text-secondary);
        border-radius: var(--radius); padding: 10px;
        font-size: 0.85rem; font-weight: 500;
        cursor: pointer; transition: var(--transition);
        font-family: var(--font-ui);
    }

    .btn-cancel:hover { border-color: var(--border-strong); color: var(--text-primary); }

    .btn-create {
        flex: 2;
        background: var(--google-blue);
        border: none; color: white;
        border-radius: var(--radius); padding: 10px;
        font-size: 0.85rem; font-weight: 600;
        cursor: pointer; transition: var(--transition);
        font-family: var(--font-ui);
        display: flex; align-items: center; justify-content: center; gap: 7px;
    }

    .btn-create:hover { background: #3367d6; transform: translateY(-1px); }
    .btn-create:disabled { opacity: 0.5; pointer-events: none; }

    /* Toast */
    #toast {
        position: fixed;
        bottom: 5rem; left: 50%;
        transform: translateX(-50%) translateY(20px);
        background: var(--bg-raised);
        border: 1px solid var(--border-strong);
        color: var(--text-primary);
        border-radius: 10px;
        padding: 10px 18px;
        font-size: 0.83rem;
        box-shadow: var(--shadow-card);
        opacity: 0;
        transition: all 0.3s ease;
        z-index: 200;
        white-space: nowrap;
        pointer-events: none;
    }

    #toast.show {
        opacity: 1;
        transform: translateX(-50%) translateY(0);
    }

    #toast.success { border-color: rgba(141,228,173,0.3); color: var(--accent); }
    #toast.error   { border-color: rgba(239,68,68,0.3);  color: var(--red); }

    /* ═══════════════════════════════════════════════════════
        ANIMATIONS
    ═══════════════════════════════════════════════════════ */
    @keyframes fadeIn {
        from { opacity: 0; } to { opacity: 1; }
    }

    @keyframes slideInLeft {
        from { opacity: 0; transform: translateX(-12px); }
        to   { opacity: 1; transform: translateX(0); }
    }

    /* Staggered sidebar sections */
    .sidebar-body > * {
        animation: slideInLeft 0.35s ease both;
    }
    .sidebar-body > *:nth-child(1) { animation-delay: 0.05s; }
    .sidebar-body > *:nth-child(2) { animation-delay: 0.1s; }
    .sidebar-body > *:nth-child(3) { animation-delay: 0.15s; }
    .sidebar-body > *:nth-child(4) { animation-delay: 0.2s; }
    .sidebar-body > *:nth-child(5) { animation-delay: 0.25s; }

    /* ═══════════════════════════════════════════════════════
        RESPONSIVE — TABLET (768–1023px)
    ═══════════════════════════════════════════════════════ */
    @media (max-width: 1023px) {
        :root { --sidebar-w: 250px; --intel-w: 300px; }

        aside {
            position: fixed;
            left: 0; top: 0; bottom: 0;
            transform: translateX(-100%);
            box-shadow: 4px 0 30px rgba(0,0,0,0.5);
        }

        aside.open { transform: translateX(0); }

        #hamburger { display: flex; }
        #sidebar-close { display: block; }

        .action-btn span { display: none; }
        .action-btn { padding: 6px 10px; }
    }

    /* ═══════════════════════════════════════════════════════
        RESPONSIVE — MOBILE (< 640px)
    ═══════════════════════════════════════════════════════ */
    @media (max-width: 639px) {
        :root { --header-h: 54px; }

        body { font-size: 14px; }

        #chat-window { padding: 1rem; gap: 1rem; }

        .message { max-width: 92%; font-size: 0.875rem; }

        .prompt-container { padding: 0.75rem 1rem 0.875rem; }

        #user-input { font-size: 0.875rem; padding: 11px 13px; }

        .bot-message table { font-size: 0.75rem; display: block; overflow-x: auto; }
        .bot-message th, .bot-message td { padding: 7px 9px; white-space: nowrap; }

        .header-title { font-size: 0.85rem; }
        #db-status { font-size: 0.68rem; padding: 2px 7px; }

        .auth-card { padding: 2rem 1.5rem 1.5rem; }

        .form-row { grid-template-columns: 1fr; }

        #intel-panel {
            width: 100%;
            min-width: 0;
        }
    }

    /* ═══════════════════════════════════════════════════════
        RESPONSIVE — LARGE DESKTOP (1400px+)
    ═══════════════════════════════════════════════════════ */
    @media (min-width: 1400px) {
        :root { --sidebar-w: 290px; --intel-w: 360px; }

        aside {
            position: relative;
            transform: none !important;
        }

        #intel-panel {
            position: relative;
            transform: translateX(0);
            display: none;
        }

        #intel-panel.open {
            display: flex;
        }

        #hamburger { display: none !important; }
        #sidebar-close { display: none !important; }
        #sidebar-overlay { display: none !important; }
    }

    @media (min-width: 1024px) and (max-width: 1399px) {
        aside {
            position: relative;
            transform: none !important;
        }
        #hamburger { display: none !important; }
        #sidebar-close { display: none !important; }
        #sidebar-overlay { display: none !important; }
    }

    /* ═══════════════════════════════════════════════════════
        GOOGLE MAPS EMBED (MCP injected iframes)
    ═══════════════════════════════════════════════════════ */
    .maps-embed-wrapper {
        margin: 0.75rem 0;
        border-radius: var(--radius);
        overflow: hidden;
        border: 1px solid var(--border-strong);
        background: var(--bg-raised);
    }

    .maps-embed-wrapper iframe {
        display: block;
        border: none;
        border-radius: 0;
    }

    .maps-embed-caption {
        padding: 6px 12px;
        font-size: 0.75rem;
        color: var(--text-secondary);
        font-family: var(--font-mono);
        border-top: 1px solid var(--border);
        background: var(--bg-surface);
    }

    /* ═══════════════════════════════════════════════════════
        GOOGLE TASKS PANEL (intel tab)
    ═══════════════════════════════════════════════════════ */
    .gtask-card {
        background: var(--bg-raised);
        border: 1px solid var(--border);
        border-radius: var(--radius);
        padding: 0.75rem 1rem;
        margin-bottom: 7px;
        transition: var(--transition);
        animation: fadeIn 0.25s ease both;
        display: flex;
        align-items: flex-start;
        gap: 10px;
    }

    .gtask-card:hover { border-color: var(--border-strong); }

    .gtask-check {
        width: 16px; height: 16px;
        border: 1.5px solid var(--border-strong);
        border-radius: 50%;
        flex-shrink: 0;
        margin-top: 2px;
    }

    .gtask-body { flex: 1; min-width: 0; }
    .gtask-title { font-size: 0.83rem; font-weight: 500; color: var(--text-primary); margin-bottom: 2px; }
    .gtask-notes { font-size: 0.74rem; color: var(--text-secondary); line-height: 1.4; }
    .gtask-due {
        font-size: 0.7rem;
        font-family: var(--font-mono);
        color: var(--accent);
        margin-top: 4px;
    }

    .gtask-del-btn {
        background: none; border: none;
        color: var(--text-muted); cursor: pointer;
        font-size: 0.75rem; padding: 2px 5px;
        border-radius: 4px; transition: var(--transition);
        flex-shrink: 0;
    }
    .gtask-del-btn:hover { color: var(--red); background: rgba(248,113,113,0.08); }

    .tasks-pane-header {
        padding: 0.75rem 1rem;
        display: flex; align-items: center; justify-content: space-between;
        border-bottom: 1px solid var(--border);
        flex-shrink: 0;
    }

    .tasks-pane-header span {
        font-size: 0.72rem;
        font-family: var(--font-mono);
        color: var(--text-muted);
        text-transform: uppercase;
        letter-spacing: 0.06em;
    }

    .btn-add-gtask {
        display: flex; align-items: center; gap: 5px;
        background: var(--accent-dim);
        border: 1px solid rgba(52,211,153,0.2);
        color: var(--accent);
        border-radius: 6px;
        padding: 5px 10px;
        font-size: 0.75rem; font-weight: 600;
        cursor: pointer; transition: var(--transition);
        font-family: var(--font-ui);
    }
    .btn-add-gtask:hover { background: var(--accent-glow); }

    .tasks-pane-body {
        flex: 1; overflow-y: auto;
        padding: 0.875rem;
    }

    /* Inline add-task form */
    #gtask-inline-form {
        display: none;
        background: var(--bg-raised);
        border: 1px solid var(--border-strong);
        border-radius: var(--radius);
        padding: 0.875rem;
        margin-bottom: 10px;
        animation: fadeIn 0.2s ease;
    }

    #gtask-inline-form.visible { display: block; }

    #note-inline-form {
        display: none;
        background: var(--bg-raised);
        border: 1px solid var(--border-strong);
        border-radius: var(--radius);
        padding: 0.875rem;
        margin-bottom: 10px;
        animation: fadeIn 0.2s ease;
    }
    #note-inline-form.visible { display: block; }
    #note-inline-form input,
    #note-inline-form textarea {
        width: 100%;
        background: var(--bg-surface);
        border: 1px solid var(--border);
        border-radius: 7px;
        color: var(--text-primary);
        padding: 8px 11px;
        font-size: 0.83rem;
        font-family: var(--font-ui);
        outline: none;
        transition: var(--transition);
        margin-bottom: 7px;
    }
    #note-inline-form input:focus,
    #note-inline-form textarea:focus {
        border-color: rgba(52,211,153,0.35);
        box-shadow: 0 0 0 2px var(--accent-dim);
    }
    #note-inline-form textarea { resize: none; height: 70px; }

    #gtask-inline-form input,
    #gtask-inline-form textarea {
        width: 100%;
        background: var(--bg-surface);
        border: 1px solid var(--border);
        border-radius: 7px;
        color: var(--text-primary);
        padding: 8px 11px;
        font-size: 0.83rem;
        font-family: var(--font-ui);
        outline: none;
        transition: var(--transition);
        margin-bottom: 7px;
    }

    #gtask-inline-form input:focus,
    #gtask-inline-form textarea:focus {
        border-color: rgba(52,211,153,0.35);
        box-shadow: 0 0 0 2px var(--accent-dim);
    }

    #gtask-inline-form textarea { resize: none; height: 56px; }

    .gtask-form-row {
        display: flex; gap: 7px;
    }

    .btn-gtask-save {
        flex: 1;
        background: var(--accent-dim);
        border: 1px solid rgba(52,211,153,0.25);
        color: var(--accent);
        border-radius: 7px; padding: 7px;
        font-size: 0.8rem; font-weight: 600;
        cursor: pointer; transition: var(--transition);
        font-family: var(--font-ui);
    }
    .btn-gtask-save:hover { background: var(--accent-glow); }

    .btn-gtask-cancel {
        background: var(--bg-surface);
        border: 1px solid var(--border);
        color: var(--text-muted);
        border-radius: 7px; padding: 7px 12px;
        font-size: 0.8rem; cursor: pointer;
        transition: var(--transition); font-family: var(--font-ui);
    }
    .btn-gtask-cancel:hover { color: var(--text-primary); }

    /* ═══════════════════════════════════════════════════════
        SUBTLE UI ADJUSTMENTS
    ═══════════════════════════════════════════════════════ */

    /* Remove the grid texture — too decorative for a project */
    body::before { display: none; }

    /* Header panel-tab buttons — Maps, Calendar, Tasks */
    .panel-tab-btn {
        display: flex; align-items: center; gap: 6px;
        background: var(--bg-raised);
        border: 1px solid var(--border);
        color: var(--text-secondary);
        border-radius: 8px;
        padding: 6px 12px;
        font-size: 0.8rem;
        font-weight: 500;
        cursor: pointer;
        transition: var(--transition);
        font-family: var(--font-ui);
        white-space: nowrap;
    }

    .panel-tab-btn:hover {
        border-color: var(--border-strong);
        color: var(--text-primary);
    }

    .panel-tab-btn.active {
        background: var(--accent-dim);
        border-color: rgba(141,228,173,0.3);
        color: var(--accent);
    }

    .panel-tab-btn.cal-active {
        background: var(--google-blue-dim);
        border-color: rgba(66,133,244,0.3);
        color: var(--google-blue);
    }

    /* Hide on mobile (spans only) */
    @media (max-width: 1023px) {
        .panel-tab-btn span { display: none; }
        .panel-tab-btn { padding: 6px 10px; }
    }

    /* Light mode — auto OS theme (unchanged tokens, just re-mapped) */
    @media (prefers-color-scheme: light) {
        header, .prompt-container {
            background: var(--bg-surface);
        }
        #auth-modal {
            background: rgba(180, 190, 200, 0.55);
        }
    }
    </style>
</head>
<body>

<div id="auth-modal">
    <div class="auth-card">
        <div class="auth-logo">
            <div class="auth-logo-icon"><i class="fas fa-leaf"></i></div>
            AgroSync
        </div>
        <div class="auth-subtitle">APAC AGRO INTELLIGENCE PLATFORM</div>

        <div class="auth-feature-list">
            <div class="auth-feature">
                <i class="fas fa-database"></i>
                <span>Query live tables — farmers, inventory, tasks</span>
            </div>
            <div class="auth-feature google">
                <i class="fab fa-google"></i>
                <span>Schedule farmer meetings via Google Calendar</span>
            </div>
            <div class="auth-feature google">
                <i class="fas fa-map-marked-alt"></i>
                <span>View APAC farmer locations on Google Maps</span>
            </div>
            <div class="auth-feature">
                <i class="fas fa-chart-bar"></i>
                <span>Stock, crop and task analytics across regions</span>
            </div>
        </div>

        <button class="btn-google-signin" onclick="signInWithGoogle()">
            <div class="google-g"></div>
            Sign in with Google
        </button>

        <button class="btn-skip" onclick="skipAuth()">
            Continue without Google Calendar
        </button>

        <p class="auth-disclaimer">
            Signing in enables Google Calendar, Tasks and Maps features.<br>
            Your credentials are never stored on our servers.
        </p>
    </div>
</div>

<div id="schedule-modal">
    <div class="schedule-card">
        <div class="schedule-header">
            <div class="schedule-title">
                <i class="fas fa-calendar-plus"></i> Schedule Farmer Meeting
            </div>
            <button class="modal-close" onclick="closeScheduleModal()"><i class="fas fa-times"></i></button>
        </div>
        <div class="schedule-body">
            <div class="form-group">
                <label class="form-label">Meeting Title</label>
                <input type="text" class="form-input" id="evt-title" value="AgroSync: Farmer Meeting" placeholder="Meeting title">
            </div>
            <div class="form-group">
                <label class="form-label">Farmer Name</label>
                <input type="text" class="form-input" id="evt-farmer" placeholder="e.g. Amit Patel">
            </div>
            <div class="form-row">
                <div class="form-group">
                    <label class="form-label">Date</label>
                    <input type="date" class="form-input" id="evt-date">
                </div>
                <div class="form-group">
                    <label class="form-label">Start Time</label>
                    <input type="time" class="form-input" id="evt-time" value="10:00">
                </div>
            </div>
            <div class="form-group">
                <label class="form-label">Duration</label>
                <select class="form-select form-input" id="evt-duration">
                    <option value="30">30 minutes</option>
                    <option value="60" selected>1 hour</option>
                    <option value="90">1.5 hours</option>
                    <option value="120">2 hours</option>
                </select>
            </div>
            <div class="form-group">
                <label class="form-label">Description</label>
                <textarea class="form-textarea form-input" id="evt-desc" placeholder="Meeting agenda, crops to discuss, field locations…"></textarea>
            </div>
            <label class="form-check">
                <input type="checkbox" id="evt-meet" checked>
                Add Google Meet video link
            </label>
            <div class="schedule-footer">
                <button class="btn-cancel" onclick="closeScheduleModal()">Cancel</button>
                <button class="btn-create" id="create-event-btn" onclick="createCalendarEvent()">
                    <i class="fas fa-calendar-check"></i> Create Event
                </button>
            </div>
        </div>
    </div>
</div>

<div id="sidebar-overlay" onclick="closeSidebar()"></div>

<div id="toast"></div>

<aside id="sidebar">
    <div class="sidebar-header">
        <div class="logo">
            <div class="logo-icon"><i class="fas fa-leaf"></i></div>
            AgroSync Hub
        </div>
        <button id="sidebar-close" onclick="closeSidebar()"><i class="fas fa-times"></i></button>
    </div>

    <div class="sidebar-body">

        <div id="google-user-card">
            <div class="g-avatar-placeholder" id="g-avatar-wrap">
                <i class="fas fa-user"></i>
            </div>
            <div class="g-user-info">
                <div class="g-user-name" id="g-user-name">—</div>
                <div class="g-user-sub">Google Calendar Active</div>
            </div>
            <button id="g-signout-btn" onclick="signOut()" title="Sign out">
                <i class="fas fa-sign-out-alt"></i>
            </button>
        </div>

        <div id="sidebar-signin-prompt">
            <p>Sign in to enable <strong>Google Calendar</strong> and schedule farmer meetings directly.</p>
            <button class="btn-signin-small" onclick="signInWithGoogle()">
                <div class="google-g" style="width:16px;height:16px;"></div>
                Sign in with Google
            </button>
        </div>

        <div>
            <div class="section-label">
                <div class="live-dot"></div>
                Live Insights
            </div>
            <div id="summary-content" class="summary-list">
                <div style="color:var(--text-muted);font-size:0.8rem;padding:8px;">Synchronizing AlloyDB…</div>
            </div>
        </div>
        <div>
            <div class="section-label">Sub-Region Guide</div>
            <div class="abbr-box">
                <div class="abbr-row"><span class="abbr-key">SSWA</span><span>South & South West Asia</span></div>
                <div class="abbr-row"><span class="abbr-key">SEA</span><span>South East Asia</span></div>
                <div class="abbr-row"><span class="abbr-key">EAS</span><span>East Asia</span></div>
                <div class="abbr-row"><span class="abbr-key">PAC</span><span>Pacific Islands</span></div>
            </div>
        </div>

    </div>

    <div class="sidebar-footer">
        <button class="btn-refresh" onclick="fetchSummary()">
            <i class="fas fa-sync-alt"></i> Force Refresh
        </button>
    </div>
</aside>

<main>
    <header>
        <div class="header-left">
            <button id="hamburger" onclick="openSidebar()"><i class="fas fa-bars"></i></button>
            <div class="header-title">APAC Coordinator</div>
            <div id="db-status"><span style="color:var(--accent)">●</span>&nbsp;Online</div>
        </div>
        <div class="header-actions">
            <button class="panel-tab-btn" id="hdr-btn-map"      onclick="openPanel('map')">
                <i class="fas fa-map-marked-alt"></i>
                <span>Maps</span>
            </button>
            <button class="panel-tab-btn" id="hdr-btn-calendar" onclick="openPanel('calendar')">
                <i class="fas fa-calendar-alt"></i>
                <span>Calendar</span>
            </button>
            <button class="panel-tab-btn" id="hdr-btn-tasks"    onclick="openPanel('tasks')">
                <i class="fas fa-check-circle"></i>
                <span>Tasks</span>
            </button>
            <button class="panel-tab-btn" id="hdr-btn-notes"    onclick="openPanel('notes')">
                <i class="fas fa-sticky-note"></i>
                <span>Notes</span>
            </button>
            <div class="header-avatar" id="header-avatar">
                <i class="fas fa-user-circle" style="font-size:1.1rem;color:var(--text-muted);"></i>
            </div>
        </div>
    </header>

    <div id="chat-window"></div>

    <div class="prompt-container">
        <div class="input-wrapper">
            <input type="text" id="user-input"
                   placeholder="Ask about farmers, tasks, inventory, analytics…"
                   onkeypress="handleKey(event)">
            <button class="send-btn" onclick="sendMessage()">
                <i class="fas fa-paper-plane"></i>
            </button>
        </div>
    </div>
</main>

<div id="intel-panel">
    <div class="intel-header">
        <div class="intel-title">
            <i class="fas fa-satellite-dish" style="color:var(--accent);font-size:0.85rem;"></i>
            APAC Intel
        </div>
        <button class="intel-close" onclick="toggleIntelPanel()"><i class="fas fa-times"></i></button>
    </div>

    <div class="intel-tabs">
        <button class="intel-tab active" id="tab-map" onclick="switchIntelTab('map')">
            <i class="fas fa-map"></i> Map
        </button>
        <button class="intel-tab" id="tab-calendar" onclick="switchIntelTab('calendar')">
            <i class="fas fa-calendar-alt"></i> Calendar
        </button>
        <button class="intel-tab" id="tab-tasks" onclick="switchIntelTab('tasks')">
            <i class="fas fa-check-circle"></i> Tasks
        </button>
        <button class="intel-tab" id="tab-notes" onclick="switchIntelTab('notes')">
            <i class="fas fa-sticky-note"></i> Notes
        </button>
    </div>

    <div class="intel-pane active" id="pane-map">
        <div id="google-map">
            <div class="map-placeholder" id="map-placeholder">
                <i class="fas fa-map-marked-alt"></i>
                <div>Google Maps will appear here</div>
                <div style="margin-top:4px;">Set the <code>MAPS_API_KEY</code> environment variable on the server to activate</div>
            </div>
        </div>
    </div>

    <div class="intel-pane" id="pane-calendar">
        <button class="btn-create-event" onclick="openScheduleModal()">
            <i class="fas fa-calendar-plus"></i> Schedule New Meeting
        </button>
        <div class="calendar-pane-body" id="cal-events-body">
            <div class="cal-event-empty">
                <i class="fas fa-calendar-alt"></i>
                Sign in with Google to view upcoming meetings
            </div>
        </div>
    </div>

    <div class="intel-pane" id="pane-tasks">
        <div class="tasks-pane-header">
            <span>Google Tasks</span>
            <button class="btn-add-gtask" id="btn-show-gtask-form" onclick="toggleGTaskForm()">
                <i class="fas fa-plus"></i> Add Task
            </button>
        </div>
        <div class="tasks-pane-body">
            <div id="gtask-inline-form">
                <input type="text" id="gtask-title-input" placeholder="Task title" maxlength="200">
                <textarea id="gtask-notes-input" placeholder="Notes (optional)"></textarea>
                <input type="date" id="gtask-due-input">
                <div class="gtask-form-row">
                    <button class="btn-gtask-save" onclick="createGTask()"><i class="fas fa-check"></i> Save</button>
                    <button class="btn-gtask-cancel" onclick="toggleGTaskForm()">Cancel</button>
                </div>
            </div>
            <div id="gtasks-list-body">
                <div class="cal-event-empty">
                    <i class="fas fa-check-circle"></i>
                    Sign in with Google to view tasks
                </div>
            </div>
        </div>
    </div>

    <div class="intel-pane" id="pane-notes">
        <div class="tasks-pane-header">
            <span>Notes & Knowledge</span>
            <button class="btn-add-gtask" id="btn-show-note-form" onclick="toggleNoteForm()">
                <i class="fas fa-plus"></i> Add Note
            </button>
        </div>
        <div class="tasks-pane-body">
            <div id="note-inline-form">
                <input type="text" id="note-title-input" placeholder="Note title" maxlength="200">
                <textarea id="note-content-input" placeholder="Note content" rows="3"></textarea>
                <input type="text" id="note-tags-input" placeholder="Tags (comma-separated, optional)">
                <div class="gtask-form-row">
                    <button class="btn-gtask-save" onclick="createNote()"><i class="fas fa-check"></i> Save</button>
                    <button class="btn-gtask-cancel" onclick="toggleNoteForm()">Cancel</button>
                </div>
            </div>
            <div style="padding:8px 0;">
                <input type="text" id="note-search-input" placeholder="Search notes…" style="width:100%;padding:6px 10px;background:var(--bg-surface);border:1px solid var(--border);border-radius:8px;color:var(--text-primary);font-size:0.8rem;" onkeyup="if(event.key==='Enter')searchNotes()">
            </div>
            <div id="notes-list-body">
                <div class="cal-event-empty">
                    <i class="fas fa-sticky-note"></i>
                    Ask AgroSync to create notes, or add one here
                </div>
            </div>
        </div>
    </div>
</div>

<script>
// ─── CONFIGURATION ────────────────────────────────────────────────────────────
// Credentials are loaded from /config endpoint on page load (see loadAppConfig)
let GOOGLE_CLIENT_ID = '';
const CALENDAR_SCOPE   = [
    'https://www.googleapis.com/auth/calendar.events',
    'https://www.googleapis.com/auth/calendar.readonly',
    'https://www.googleapis.com/auth/tasks',
    'https://www.googleapis.com/auth/userinfo.profile',
    'https://www.googleapis.com/auth/userinfo.email'
].join(' ');

// Known APAC country coordinates for map markers
const COUNTRY_COORDS = {
    'India':       { lat: 20.59, lng: 78.96 },
    'Nepal':       { lat: 28.39, lng: 84.12 },
    'Vietnam':     { lat: 14.06, lng: 108.28 },
    'Thailand':    { lat: 15.87, lng: 100.99 },
    'China':       { lat: 35.86, lng: 104.19 },
    'Japan':       { lat: 36.20, lng: 138.25 },
    'Philippines': { lat: 12.87, lng: 121.77 },
    'Indonesia':   { lat: -0.79, lng: 113.92 },
    'Malaysia':    { lat: 4.21,  lng: 108.96 },
    'Myanmar':     { lat: 21.91, lng: 95.96  },
    'Bangladesh':  { lat: 23.68, lng: 90.36  },
    'Sri Lanka':   { lat: 7.87,  lng: 80.77  },
    'Pakistan':    { lat: 30.38, lng: 69.35  },
    'Cambodia':    { lat: 12.57, lng: 104.99 },
    'Laos':        { lat: 19.86, lng: 102.50 },'Malaysia':    { lat: 4.21,   lng: 101.97 },
    'Cambodia':    { lat: 12.56,  lng: 104.99 },
    'Laos':        { lat: 19.85,  lng: 102.49 },
    'Myanmar':     { lat: 21.91,  lng: 95.95 },
    'Mongolia':    { lat: 46.86,  lng: 103.84 },
    'New Zealand': { lat: -40.90, lng: 174.88 },
    'Papua New Guinea': { lat: -6.31, lng: 143.95 }
};

// ─── STATE ────────────────────────────────────────────────────────────────────
let gTokenClient  = null;
let gAccessToken  = null;
let gMap          = null;
let gMapMarkers   = [];
let gSummaryData  = [];
let isIntelOpen   = false;
let currentIntelTab = 'map';

// ─── DOM REFS ─────────────────────────────────────────────────────────────────
const chatWindow = document.getElementById('chat-window');
const userInput  = document.getElementById('user-input');

// ═══════════════════════════════════════════════════════════════════════════════
// EXISTING LOGIC — PRESERVED EXACTLY
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
// CONFIG LOADER — fetches /config and initialises Google services
// ═══════════════════════════════════════════════════════════════════════════════

async function loadAppConfig() {
    try {
        const res  = await fetch('/config');
        const cfg  = await res.json();

        // Set OAuth client ID
        if (cfg.google_client_id) {
            GOOGLE_CLIENT_ID = cfg.google_client_id;
        }

        // Dynamically load Google Maps JS if key is available
        if (cfg.maps_api_key && !window.__mapsLoaded) {
            window.__mapsLoaded = true;
            const s   = document.createElement('script');
            s.src     = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(cfg.maps_api_key)}&callback=initMap`;
            s.async   = true;
            s.defer   = true;
            document.head.appendChild(s);
        }
    } catch (e) {
        console.warn('Config fetch failed — Google services may be limited.', e);
    }
}

window.onload = () => {
    fetchSummary();
    setTimeout(loadSidebarNotes, 2000); // Load sidebar notes after a short delay
    appendMessage('bot', `### 👋 Welcome to AgroSync Intelligence.
I am your APAC agricultural coordinator — powered by **Gemini 2.5 Flash** with tools served via **MCP**.

**AlloyDB (via MCP):**
* 🔍 **Query** farmers, inventory, and tasks (any column, any filter)
* 📊 **Analytics** — stock, crop diversity, harvest tracking, task load (21+ metrics)
* ✅ **Task Management** — create, **update**, delete tasks; overdue alerts
* 👨‍🌾 **Farmer & Inventory** — create, update profiles and inventory items

**Google Services (via MCP, sign in required):**
* 📅 **Google Calendar** — schedule or delete farmer meetings; auto-embeds a map
* ✅ **Google Tasks** — create or delete reminders; synced to AlloyDB
* 🗺️ **Google Maps** — embed an interactive map for any location

**Notes & Knowledge (via MCP):**
* 📝 **Notes** — create, search, list, or delete notes linked to farmers or general knowledge. Use the Notes panel or just ask me.

What would you like to know?`);

    // Load config first (sets GOOGLE_CLIENT_ID + loads Maps), then init Google auth
    loadAppConfig().then(() => {
        setTimeout(initGoogleServices, 800);
    });
    // Set default date on schedule form to today
    const today = new Date().toISOString().split('T')[0];
    document.getElementById('evt-date').value = today;
};

async function fetchSummary() {
    try {
        const response = await fetch('/summary');
        const data = await response.json();
        gSummaryData = data.details || [];
        let html = '';
        data.details.forEach(item => {
            html += `
                <div class="summary-item">
                    <div class="summary-country">${item.country} <span style="color:var(--text-muted);font-weight:400;font-size:0.7rem;">(${item.sub_region})</span></div>
                    <div class="summary-crops">${item.crops}</div>
                </div>
            `;
        });
        document.getElementById('summary-content').innerHTML = html || '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px;">No data found.</div>';
        // Update map markers if map is ready
        if (gMap) updateMapMarkers();
    } catch (e) {
        document.getElementById('summary-content').innerHTML = '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px;">Sync failed.</div>';
    }
}

async function sendMessage() {
    const query = userInput.value.trim();
    if (!query) return;

    appendMessage('user', query);
    userInput.value = '';

    // Disable input while processing
    userInput.disabled = true;
    document.querySelector('.send-btn').disabled = true;

    const requestId = 'r_' + Date.now() + '_' + Math.random().toString(36).substr(2, 6);

    // Insert live status element in chat (right after user message)
    const statusEl = document.createElement('div');
    statusEl.className = 'live-status';
    statusEl.id = 'live-status-' + requestId;
    statusEl.innerHTML = '<div class="status-dot"></div><span>Analyzing your request…</span>';
    chatWindow.appendChild(statusEl);
    chatWindow.scrollTop = chatWindow.scrollHeight;

    // Open SSE stream for live status updates
    let es = null;
    try {
        es = new EventSource('/status/' + requestId);
        es.onmessage = function(e) {
            try {
                const d = JSON.parse(e.data);
                if (d.done) { es.close(); return; }
                if (d.status && statusEl) {
                    statusEl.querySelector('span').textContent = d.status;
                    chatWindow.scrollTop = chatWindow.scrollHeight;
                }
            } catch(err) {}
        };
        es.onerror = function() { es.close(); };
    } catch(err) {
        // SSE is optional enhancement — don't block
    }

    try {
        const response = await fetch('/ask', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: query, access_token: gAccessToken || '', request_id: requestId })
        });
        const data = await response.json();

        // Remove live status, show bot response
        if (statusEl && statusEl.parentNode) statusEl.remove();
        appendMessage('bot', data.agent_response);

        if (query.toLowerCase().match(/create|delete|add|remove/)) fetchSummary();
        if (query.toLowerCase().match(/note|notes/)) setTimeout(loadSidebarNotes, 1000);

        const farmerMatch = data.agent_response.match(/\*\*([A-Z][a-z]+ [A-Z][a-z]+)\*\*/);
        if (farmerMatch) document.getElementById('evt-farmer').value = farmerMatch[1];

    } catch (err) {
        if (statusEl && statusEl.parentNode) statusEl.remove();
        appendMessage('bot', '### ⚠️ Connection Lost\nBackend is unreachable.');
    } finally {
        if (es) try { es.close(); } catch(e) {}
        userInput.disabled = false;
        document.querySelector('.send-btn').disabled = false;
        userInput.focus();
    }
}

function appendMessage(role, text) {
    const div = document.createElement('div');
    div.className = `message ${role}-message`;

    // Allow maps embed HTML from bot responses (trusted backend output)
    if (role === 'bot' && text.includes('maps-embed-wrapper')) {
        // Sanitize but allow iframe with specific safe attrs
        const clean = DOMPurify.sanitize(marked.parse(text), {
            ADD_TAGS: ['iframe'],
            ADD_ATTR: ['src', 'width', 'height', 'allowfullscreen', 'loading', 'referrerpolicy', 'frameborder', 'style']
        });
        div.innerHTML = clean;
    } else {
        div.innerHTML = DOMPurify.sanitize(marked.parse(text));
    }
    chatWindow.appendChild(div);
    chatWindow.scrollTop = chatWindow.scrollHeight;
}

function handleKey(e) { if (e.key === 'Enter') sendMessage(); }

// ═══════════════════════════════════════════════════════════════════════════════
// GOOGLE IDENTITY SERVICES (OAuth2)
// ═══════════════════════════════════════════════════════════════════════════════

function initGoogleServices() {
    // Init GIS token client
    if (typeof google !== 'undefined' && google.accounts) {
        gTokenClient = google.accounts.oauth2.initTokenClient({
            client_id: GOOGLE_CLIENT_ID,
            scope: CALENDAR_SCOPE,
            callback: handleTokenResponse,
        });
    } else {
        // Retry if library hasn't loaded yet
        setTimeout(initGoogleServices, 600);
        return;
    }

    // Show auth modal after a polished delay
    setTimeout(showAuthModal, 600);
}

function handleTokenResponse(tokenResponse) {
    if (tokenResponse.error) {
        showToast('Google sign-in failed: ' + tokenResponse.error, 'error');
        return;
    }
    gAccessToken = tokenResponse.access_token;
    fetchGoogleUserInfo();
    closeAuthModal();
    enableCalendarFeatures();
    loadUpcomingEvents();
}

async function fetchGoogleUserInfo() {
    try {
        const res = await fetch('https://www.googleapis.com/oauth2/v3/userinfo', {
            headers: { Authorization: `Bearer ${gAccessToken}` }
        });
        const user = await res.json();

        // Update sidebar user card
        document.getElementById('g-user-name').textContent = user.name || user.email;
        const avatarWrap = document.getElementById('g-avatar-wrap');
        if (user.picture) {
            avatarWrap.innerHTML = `<img class="g-avatar" src="${user.picture}" alt="${user.name}">`;
        }
        document.getElementById('google-user-card').classList.add('visible');
        document.getElementById('sidebar-signin-prompt').style.display = 'none';

        // Update header avatar
        if (user.picture) {
            document.getElementById('header-avatar').innerHTML = `<img src="${user.picture}" alt="${user.name}" style="width:100%;height:100%;object-fit:cover;border-radius:50%;">`;
        }

        showToast('✓ Google Calendar connected', 'success');
    } catch (e) {
        console.error('Failed to fetch user info:', e);
    }
}

function enableCalendarFeatures() {
    // Calendar and Tasks are always visible in the header — no toggle needed
    // Auto-load tasks when signed in
    setTimeout(loadGTasks, 400);
}

function signInWithGoogle() {
    if (gTokenClient) {
        gTokenClient.requestAccessToken({ prompt: 'consent' });
    } else {
        // Fallback: reinit and retry
        initGoogleServices();
        setTimeout(() => {
            if (gTokenClient) gTokenClient.requestAccessToken({ prompt: 'consent' });
            else showToast('Google services not loaded yet. Try again.', 'error');
        }, 1200);
    }
}

function signOut() {
    if (gAccessToken) {
        google.accounts.oauth2.revoke(gAccessToken, () => {});
    }
    gAccessToken = null;
    document.getElementById('google-user-card').classList.remove('visible');
    document.getElementById('sidebar-signin-prompt').style.display = '';
    document.getElementById('header-avatar').innerHTML = '<i class="fas fa-user-circle" style="font-size:1.1rem;color:var(--text-muted);"></i>';
    document.getElementById('cal-events-body').innerHTML = `
        <div class="cal-event-empty">
            <i class="fas fa-calendar-alt"></i>
            Sign in with Google to view upcoming meetings
        </div>`;
    showToast('Signed out from Google', 'success');
}

// ═══════════════════════════════════════════════════════════════════════════════
// GOOGLE CALENDAR
// ═══════════════════════════════════════════════════════════════════════════════

async function loadUpcomingEvents() {
    if (!gAccessToken) return;
    try {
        const res = await fetch('/mcp/calendar', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'list_events', access_token: gAccessToken, max_results: 10 })
        });
        const data = await res.json();
        if (data.events) {
            renderCalendarEvents(data.events.map(e => ({
                summary: e.title, start: { dateTime: e.start }, id: e.event_id, location: e.location
            })));
        }
    } catch (e) {
        console.error('Failed to load calendar events:', e);
    }
}

function renderCalendarEvents(events) {
    const body = document.getElementById('cal-events-body');
    if (!events.length) {
        body.innerHTML = `
            <div class="cal-event-empty">
                <i class="fas fa-calendar-check"></i>
                No upcoming meetings in the next 30 days
            </div>`;
        return;
    }
    body.innerHTML = events.map(evt => {
        const startRaw = evt.start?.dateTime || evt.start?.date || '';
        const start = startRaw ? new Date(startRaw) : null;
        const timeStr = start
            ? start.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }) + ' · ' +
              start.toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })
            : 'All day';
        return `
            <div class="cal-event-card">
                <div class="cal-event-title">${DOMPurify.sanitize(evt.summary || 'Untitled')}</div>
                <div class="cal-event-time">${timeStr}</div>
            </div>`;
    }).join('');
}

async function createCalendarEvent() {
    if (!gAccessToken) {
        showToast('Please sign in with Google first', 'error');
        return;
    }

    const title    = document.getElementById('evt-title').value.trim();
    const farmer   = document.getElementById('evt-farmer').value.trim();
    const date     = document.getElementById('evt-date').value;
    const time     = document.getElementById('evt-time').value;
    const duration = parseInt(document.getElementById('evt-duration').value);
    const desc     = document.getElementById('evt-desc').value.trim();
    const addMeet  = document.getElementById('evt-meet').checked;

    if (!title || !date || !time) {
        showToast('Title, date and time are required', 'error');
        return;
    }

    const startDT = new Date(`${date}T${time}:00`);
    const endDT   = new Date(startDT.getTime() + duration * 60 * 1000);

    const eventBody = {
        summary: farmer ? `${title} — ${farmer}` : title,
        description: desc || `AgroSync farmer meeting${farmer ? ` with ${farmer}` : ''}.`,
        start: { dateTime: startDT.toISOString(), timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone },
        end:   { dateTime: endDT.toISOString(),   timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone },
    };

    if (addMeet) {
        eventBody.conferenceData = {
            createRequest: {
                requestId: `agrosync-${Date.now()}`,
                conferenceSolutionKey: { type: 'hangoutsMeet' }
            }
        };
    }

    const createBtn = document.getElementById('create-event-btn');
    createBtn.disabled = true;
    createBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Creating…';

    try {
        const res = await fetch('/mcp/calendar', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action: 'create_event',
                access_token: gAccessToken,
                title: farmer ? `${title} — ${farmer}` : title,
                description: desc || `AgroSync farmer meeting${farmer ? ` with ${farmer}` : ''}.`,
                start_datetime: startDT.toISOString(),
                end_datetime: endDT.toISOString(),
                add_meet_link: addMeet
            })
        });

        const evt = await res.json();
        if (evt.error) throw new Error(evt.error);

        closeScheduleModal();
        showToast('✓ Meeting created via MCP → Google Calendar', 'success');
        loadUpcomingEvents();

        // Append confirmation to chat
        const meetLink = evt.meet_link ? `\n📹 **Google Meet:** ${evt.meet_link}` : '';
        appendMessage('bot',
            `📅 **Meeting Scheduled**\n\n` +
            `| Field | Detail |\n|---|---|\n` +
            `| **Title** | ${evt.title || title} |\n` +
            `| **Date** | ${startDT.toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'long', year: 'numeric' })} |\n` +
            `| **Time** | ${startDT.toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })} — ${endDT.toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })} |\n` +
            (farmer ? `| **Farmer** | ${farmer} |\n` : '') +
            `| **Status** | ✅ Confirmed |` +
            meetLink
        );
    } catch (e) {
        showToast('Failed to create event: ' + e.message, 'error');
    } finally {
        createBtn.disabled = false;
        createBtn.innerHTML = '<i class="fas fa-calendar-check"></i> Create Event';
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// GOOGLE MAPS
// ═══════════════════════════════════════════════════════════════════════════════

// Called by the Maps API script (callback=initMap in script src)
window.initMap = function () {
    const mapEl = document.getElementById('google-map');
    const placeholder = document.getElementById('map-placeholder');
    if (placeholder) placeholder.remove();

    const DARK_STYLE = [
        { elementType: 'geometry',            stylers: [{ color: '#0a0f1e' }] },
        { elementType: 'labels.text.stroke',  stylers: [{ color: '#0a0f1e' }] },
        { elementType: 'labels.text.fill',    stylers: [{ color: '#4b5563' }] },
        { featureType: 'water',               elementType: 'geometry', stylers: [{ color: '#060e1c' }] },
        { featureType: 'road',                stylers: [{ visibility: 'off' }] },
        { featureType: 'transit',             stylers: [{ visibility: 'off' }] },
        { featureType: 'poi',                 stylers: [{ visibility: 'off' }] },
        { featureType: 'administrative.country', elementType: 'geometry.stroke', stylers: [{ color: '#1e3355' }, { weight: 1 }] },
        { featureType: 'administrative.country', elementType: 'labels.text.fill', stylers: [{ color: '#475569' }] },
        { featureType: 'landscape.natural',   elementType: 'geometry', stylers: [{ color: '#0d1a2d' }] },
    ];

    gMap = new google.maps.Map(mapEl, {
        center: { lat: 15, lng: 100 },
        zoom: 3,
        disableDefaultUI: true,
        zoomControl: true,
        zoomControlOptions: { position: google.maps.ControlPosition.RIGHT_BOTTOM },
        styles: DARK_STYLE,
        backgroundColor: '#070c18',
    });

    // Add markers from already-loaded summary data
    if (gSummaryData.length) updateMapMarkers();
};

function updateMapMarkers() {
    if (!gMap) return;

    // Clear existing markers
    gMapMarkers.forEach(m => m.setMap(null));
    gMapMarkers = [];

    // Group by country
    const countryMap = {};
    gSummaryData.forEach(item => {
        if (!countryMap[item.country]) {
            countryMap[item.country] = { crops: '', region: item.sub_region };
        }
        countryMap[item.country].crops += (countryMap[item.country].crops ? ', ' : '') + item.crops;
    });

    Object.entries(countryMap).forEach(([country, info]) => {
        const coords = COUNTRY_COORDS[country];
        if (!coords) return;

        // Custom marker SVG (green pin)
        const svgMarker = {
            path: 'M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z',
            fillColor: '#22c55e',
            fillOpacity: 1,
            strokeColor: '#166534',
            strokeWeight: 1.5,
            scale: 1.5,
            anchor: new google.maps.Point(12, 22),
        };

        const marker = new google.maps.Marker({
            position: coords,
            map: gMap,
            title: country,
            icon: svgMarker,
            animation: google.maps.Animation.DROP,
        });

        const infoWindow = new google.maps.InfoWindow({
            content: `
                <div style="font-family:Outfit,sans-serif;background:#0d1525;color:#e2e8f0;padding:10px 12px;border-radius:8px;min-width:160px;border:1px solid rgba(99,179,255,0.1);">
                    <div style="font-weight:700;color:#22c55e;margin-bottom:4px;font-size:0.9rem;">${country}</div>
                    <div style="font-size:0.75rem;color:#94a3b8;line-height:1.5;">${info.crops || 'No crop data'}</div>
                    <div style="font-size:0.7rem;color:#475569;margin-top:4px;">${info.region}</div>
                </div>`,
            disableAutoPan: false,
        });

        marker.addListener('click', () => {
            infoWindow.open({ anchor: marker, map: gMap });
        });

        gMapMarkers.push(marker);
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// UI CONTROLS
// ═══════════════════════════════════════════════════════════════════════════════

function showAuthModal() {
    const modal = document.getElementById('auth-modal');
    modal.classList.remove('hidden');
}

function closeAuthModal() {
    const modal = document.getElementById('auth-modal');
    modal.classList.add('hidden');
    setTimeout(() => { modal.style.display = 'none'; }, 280);
}

function skipAuth() {
    closeAuthModal();
    showToast('Continuing without Google Calendar', 'success');
}

function openSidebar() {
    document.getElementById('sidebar').classList.add('open');
    document.getElementById('sidebar-overlay').classList.add('active');
    document.body.style.overflow = 'hidden';
}

function closeSidebar() {
    document.getElementById('sidebar').classList.remove('open');
    document.getElementById('sidebar-overlay').classList.remove('active');
    document.body.style.overflow = '';
}

function toggleIntelPanel() {
    isIntelOpen = !isIntelOpen;
    const panel = document.getElementById('intel-panel');
    panel.classList.toggle('open', isIntelOpen);
    _syncHeaderBtns();

    // Trigger map resize after panel animates open
    if (isIntelOpen && gMap) {
        setTimeout(() => {
            google.maps.event.trigger(gMap, 'resize');
        }, 320);
    }
}

// Open the intel panel directly on a specific tab
function openPanel(tab) {
    const panel = document.getElementById('intel-panel');
    if (!isIntelOpen) {
        isIntelOpen = true;
        panel.classList.add('open');
    }
    switchIntelTab(tab);
    _syncHeaderBtns();
}

// Keep header button active states in sync with panel state
function _syncHeaderBtns() {
    const btns = ['map', 'calendar', 'tasks', 'notes'];
    btns.forEach(t => {
        const btn = document.getElementById(`hdr-btn-${t}`);
        if (!btn) return;
        btn.classList.remove('active', 'cal-active');
        if (isIntelOpen && currentIntelTab === t) {
            btn.classList.add(t === 'calendar' ? 'cal-active' : 'active');
        }
    });
}

function switchIntelTab(tab) {
    currentIntelTab = tab;
    document.querySelectorAll('.intel-tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.intel-pane').forEach(p => p.classList.remove('active'));
    document.getElementById(`tab-${tab}`).classList.add('active');
    document.getElementById(`pane-${tab}`).classList.add('active');

    if (tab === 'map' && gMap) {
        setTimeout(() => google.maps.event.trigger(gMap, 'resize'), 50);
    }
    if (tab === 'calendar' && gAccessToken) {
        loadUpcomingEvents();
    }
    if (tab === 'tasks' && gAccessToken) {
        loadGTasks();
    }
    if (tab === 'notes') {
        loadNotes();
    }
    _syncHeaderBtns();
}

function openScheduleModal() {
    if (!gAccessToken) {
        showAuthModal();
        return;
    }
    document.getElementById('schedule-modal').classList.add('open');
}

function closeScheduleModal() {
    document.getElementById('schedule-modal').classList.remove('open');
}

// Close schedule modal on backdrop click
document.getElementById('schedule-modal').addEventListener('click', function(e) {
    if (e.target === this) closeScheduleModal();
});

function showToast(msg, type = 'success') {
    const toast = document.getElementById('toast');
    toast.textContent = msg;
    toast.className = `show ${type}`;
    setTimeout(() => { toast.className = ''; }, 3200);
}

// Close sidebar on Escape
document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
        closeSidebar();
        closeScheduleModal();
    }
});

// ═══════════════════════════════════════════════════════════════════════════════
// GOOGLE TASKS — routed through Flask → MCP Server → Google Tasks API
// ═══════════════════════════════════════════════════════════════════════════════

async function loadGTasks() {
    if (!gAccessToken) return;
    const body = document.getElementById('gtasks-list-body');
    body.innerHTML = '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px 0;">Loading…</div>';
    try {
        const res = await fetch('/mcp/tasks', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'list_tasks', access_token: gAccessToken })
        });
        const data = await res.json();
        if (data.tasks) {
            renderGTasks(data.tasks.map(t => ({
                id: t.task_id, title: t.title, notes: t.notes, due: t.due, status: t.status
            })));
        } else {
            body.innerHTML = '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px 0;">No tasks found.</div>';
        }
    } catch (e) {
        body.innerHTML = '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px 0;">Failed to load tasks.</div>';
    }
}

function renderGTasks(tasks) {
    const body = document.getElementById('gtasks-list-body');
    if (!tasks.length) {
        body.innerHTML = `
            <div class="cal-event-empty">
                <i class="fas fa-check-circle"></i>
                No tasks yet
            </div>`;
        return;
    }
    body.innerHTML = tasks.map(t => {
        const due = t.due ? t.due.substring(0, 10) : '';
        const notes = t.notes ? `<div class="gtask-notes">${DOMPurify.sanitize(t.notes)}</div>` : '';
        const dueHtml = due ? `<div class="gtask-due">Due ${due}</div>` : '';
        return `
            <div class="gtask-card" id="gtask-${t.id}">
                <div class="gtask-check"></div>
                <div class="gtask-body">
                    <div class="gtask-title">${DOMPurify.sanitize(t.title || 'Untitled')}</div>
                    ${notes}${dueHtml}
                </div>
                <button class="gtask-del-btn" onclick="deleteGTask('${t.id}')" title="Delete task">
                    <i class="fas fa-times"></i>
                </button>
            </div>`;
    }).join('');
}

function toggleGTaskForm() {
    const form = document.getElementById('gtask-inline-form');
    form.classList.toggle('visible');
    if (form.classList.contains('visible')) {
        document.getElementById('gtask-title-input').focus();
    }
}

async function createGTask() {
    if (!gAccessToken) { showToast('Sign in with Google first', 'error'); return; }
    const title   = document.getElementById('gtask-title-input').value.trim();
    const notes   = document.getElementById('gtask-notes-input').value.trim();
    const dueDate = document.getElementById('gtask-due-input').value;
    if (!title) { showToast('Task title is required', 'error'); return; }

    const reqBody = { action: 'create_task', access_token: gAccessToken, title };
    if (notes)   reqBody.notes = notes;
    if (dueDate) reqBody.due_date = new Date(dueDate).toISOString();

    try {
        const res = await fetch('/mcp/tasks', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(reqBody)
        });
        const data = await res.json();
        if (data.error) throw new Error(data.error);
        document.getElementById('gtask-title-input').value = '';
        document.getElementById('gtask-notes-input').value = '';
        document.getElementById('gtask-due-input').value   = '';
        toggleGTaskForm();
        showToast('✓ Task added via MCP → Google Tasks', 'success');
        loadGTasks();
    } catch (e) {
        showToast('Failed to create task: ' + e.message, 'error');
    }
}

async function deleteGTask(taskId) {
    if (!gAccessToken) return;
    try {
        const res = await fetch('/mcp/tasks', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'delete_task', access_token: gAccessToken, task_id: taskId })
        });
        const data = await res.json();
        if (data.status === 'SUCCESS') {
            document.getElementById(`gtask-${taskId}`)?.remove();
            showToast('✓ Task deleted via MCP', 'success');
            loadGTasks();
        } else {
            throw new Error(data.error || 'Delete failed');
        }
    } catch (e) {
        showToast('Failed to delete task: ' + e.message, 'error');
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MCP — GOOGLE MAPS (request snippet from backend for use in chat or manual embed)
// ═══════════════════════════════════════════════════════════════════════════════

async function requestMapsSnippet(location) {
    try {
        const res = await fetch('/mcp/maps_snippet', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ location })
        });
        const data = await res.json();
        if (data.maps_snippet) {
            appendMessage('bot', `📍 **Map: ${location}**\n\n${data.maps_snippet}`);
        }
    } catch (e) {
        showToast('Maps request failed', 'error');
    }
}

// Auto-scan bot messages for location keywords and offer a map
function maybeOfferMap(text) {
    // Only trigger if message mentions "location:", "venue:", or "at <Place>" near a calendar action
    const locationMatch = text.match(/(?:location|venue|at|held at)[:\s]+([A-Z][^,\n.]{4,60})/i);
    if (locationMatch && gAccessToken) {
        const loc = locationMatch[1].trim();
        // Only auto-embed if not already present
        if (!text.includes('maps-embed-wrapper')) {
            requestMapsSnippet(loc);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// NOTES — AlloyDB-backed knowledge management
// ═══════════════════════════════════════════════════════════════════════════════

function toggleNoteForm() {
    const form = document.getElementById('note-inline-form');
    form.classList.toggle('visible');
    if (form.classList.contains('visible')) {
        document.getElementById('note-title-input').focus();
    }
}

async function loadNotes() {
    const body = document.getElementById('notes-list-body');
    body.innerHTML = '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px 0;">Loading…</div>';
    try {
        const res = await fetch('/ask', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: 'List all my notes', access_token: gAccessToken || '' })
        });
        const data = await res.json();
        body.innerHTML = `<div style="font-size:0.8rem;color:var(--text-secondary);padding:4px 0;">${DOMPurify.sanitize(marked.parse(data.agent_response))}</div>`;
    } catch (e) {
        body.innerHTML = '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px 0;">Failed to load notes.</div>';
    }
}

async function createNote() {
    const title   = document.getElementById('note-title-input').value.trim();
    const content = document.getElementById('note-content-input').value.trim();
    const tags    = document.getElementById('note-tags-input').value.trim();
    if (!title || !content) { showToast('Title and content are required', 'error'); return; }

    const query = `Create a note titled "${title}" with content: ${content}` + (tags ? ` Tags: ${tags}` : '');
    try {
        const res = await fetch('/ask', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query, access_token: gAccessToken || '' })
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        document.getElementById('note-title-input').value = '';
        document.getElementById('note-content-input').value = '';
        document.getElementById('note-tags-input').value = '';
        toggleNoteForm();
        showToast('✓ Note saved', 'success');
        loadNotes();
        loadSidebarNotes();
    } catch (e) {
        showToast('Failed to create note: ' + e.message, 'error');
    }
}

async function searchNotes() {
    const q = document.getElementById('note-search-input').value.trim();
    if (!q) { loadNotes(); return; }
    const body = document.getElementById('notes-list-body');
    body.innerHTML = '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px 0;">Searching…</div>';
    try {
        const res = await fetch('/ask', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: `Search my notes for: ${q}`, access_token: gAccessToken || '' })
        });
        const data = await res.json();
        body.innerHTML = `<div style="font-size:0.8rem;color:var(--text-secondary);padding:4px 0;">${DOMPurify.sanitize(marked.parse(data.agent_response))}</div>`;
    } catch (e) {
        body.innerHTML = '<div style="color:var(--text-muted);font-size:0.8rem;padding:8px 0;">Search failed.</div>';
    }
}

async function loadSidebarNotes() {
    const el = document.getElementById('sidebar-notes');
    if (!el) return;
    try {
        const res = await fetch('/ask', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: 'List my 5 most recent notes briefly', access_token: gAccessToken || '' })
        });
        const data = await res.json();
        const html = DOMPurify.sanitize(marked.parse(data.agent_response));
        if (html && !html.includes('NOT_FOUND') && !html.includes('No notes')) {
            el.innerHTML = `<div style="font-size:0.75rem;color:var(--text-secondary);line-height:1.5;padding:4px 0;">${html}</div>`;
        }
    } catch (e) { /* silent fail — sidebar notes are optional */ }
}

</script>
</body>
</html>
EOF_INDEX

echo "Make all generated scripts executable..."
chmod +x *.sh

echo "All files have been successfully created inside the 'agrosync' directory!"