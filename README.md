# 🌱 AgroSync Intelligence

[![Built with Gemini 2.5 Flash](https://img.shields.io/badge/Powered%20by-Gemini%202.5%20Flash-8A2BE2?style=for-the-badge)](https://deepmind.google/technologies/gemini/)
[![MCP Ready](https://img.shields.io/badge/Protocol-MCP%20v2024--11--05-4CAF50?style=for-the-badge)](https://modelcontextprotocol.io/)
[![Database](https://img.shields.io/badge/Database-AlloyDB%20(PostgreSQL)-4285F4?style=for-the-badge)](https://cloud.google.com/alloydb)
[![Deployment](https://img.shields.io/badge/Deployed%20on-Google%20Cloud%20Run-FF9900?style=for-the-badge)](https://cloud.google.com/run)

**AgroSync Intelligence** is an advanced, multi-agent AI system designed to coordinate agricultural operations, manage farmer data, and track regional crop inventories across the APAC region. 

Built as a robust, zero-hallucination platform, it leverages a hierarchical agent architecture where a Primary Coordinator delegates specialized tasks to sub-agents. All tool executions are strictly routed through a standalone **Model Context Protocol (MCP)** server, ensuring secure, deterministic interactions with Google Workspace APIs and a Google Cloud AlloyDB backend.

---

## 🧠 Multi-Agent Architecture

AgroSync moves beyond simple single-prompt chat interfaces by implementing a strict **Coordinator-Worker** multi-agent topology. 

1. **The Primary Coordinator:** Analyzes user intent and routes requests locally to save API calls or delegates complex, multi-domain requests to the sub-agents.
2. **Database Specialist Agent (`ask_db_agent`):** Manages all stateful agricultural data. Capable of complex schema navigation, generating markdown tables, and triggering 21+ distinct analytical metrics.
3. **Google Workspace Specialist (`ask_google_agent`):** Computes relative dates (ISO 8601) and manages scheduling. Has full CRUD access to Google Calendar, Google Tasks, and embedded Google Maps data.
4. **Notes & Knowledge Specialist (`ask_notes_agent`):** Handles unstructured data, qualitative observations, and farmer-specific logging.

### The MCP Bridge (Model Context Protocol)
To enforce security and separation of concerns, the Gemini agents **never** execute code directly. Instead, the Flask application acts as an MCP Client, communicating via `stdio` with `mcp_server.py`. 

The MCP Server exposes 9 highly structured tools:
* `google_calendar`, `google_tasks`, `Maps`
* `alloydb_query`, `alloydb_analytics`, `alloydb_manage_task`, `alloydb_manage_farmer`, `alloydb_manage_inventory`, `alloydb_notes`

---

## 🏗️ Technical Stack

* **AI & LLM:** Google Vertex AI, Gemini 2.5 Flash
* **Protocol:** Model Context Protocol (MCP) SDK
* **Backend:** Python 3.11, Flask, Gunicorn
* **Database:** Google Cloud AlloyDB (PostgreSQL 15 compatible) 
* **ORM & Pooling:** SQLAlchemy, pg8000
* **Frontend:** Vanilla JS, Server-Sent Events (SSE) for live agent status streaming, Google Identity Services (OAuth2)
* **Infrastructure:** Docker, Google Cloud Run, Custom VPC Networks

---

## 📊 AlloyDB Engine & Analytics

The system relies on a highly optimized AlloyDB instance managed via SQLAlchemy connection pooling. The schema is normalized into four primary tables: `farmers`, `inventory`, `tasks`, and `notes`, connected via cascading foreign keys.

The Database Specialist Agent has access to a dedicated Analytics Engine capable of executing **21 distinct aggregation metrics**, including:
* Crop diversity by region/country
* Harvest timelines (upcoming/overdue tracking)
* Global task load distribution (by farmer/country)
* Stock extremes and inventory status breakdowns

*Note: The agent is instructed to always execute an `alloydb_query` to resolve internal relational IDs before attempting any `CREATE`, `UPDATE`, or `DELETE` mutations.*

---

## 🚀 Features

* **Intent Routing:** Fast-path local regex routing skips the Primary Coordinator for single-intent queries, drastically reducing latency and token usage.
* **Live SSE Status Stream:** As the multi-agent system processes complex queries (e.g., querying the DB *and* scheduling a meeting simultaneously), the UI receives real-time updates via EventSource.
* **Contextual Data Forms:** If a user requests a database mutation but omits required fields, the agents dynamically generate Markdown tables prompting the user for exactly what is missing.
* **Maps Generation:** The workspace agent can dynamically retrieve and inject secure Google Maps iframes directly into the chat flow based on conversational context.

---

## 🛠️ Getting Started

### Prerequisites
* Google Cloud CLI (`gcloud`) installed and authenticated.
* A Google Cloud Project with billing enabled.
* API Keys: Google Maps API Key, Google OAuth2 Client ID.

### 1. Infrastructure Provisioning
We provide a dedicated bash script to build the required GCP infrastructure (VPC, Subnets, Peering, and AlloyDB clusters) to avoid Catch-22 networking issues.

```bash
chmod +x setup-infra.sh
./setup-infra.sh
