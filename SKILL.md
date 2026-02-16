---
name: servicenow
emoji: 🔧
description: "Connect your AI agent to ServiceNow — query, create, update, and manage records across any table using the Table API and Stats API. Full CRUD operations, aggregate analytics (COUNT/AVG/MIN/MAX/SUM), schema introspection, and attachment management. Purpose-built for ITSM, ITOM, and CMDB workflows including incidents, changes, problems, configuration items, knowledge articles, and more."
author: "OnlyFlows (onlyflowstech)"
homepage: "https://onlyflows.tech"
license: MIT
tags:
  - servicenow
  - itsm
  - itom
  - cmdb
  - snow
  - table-api
  - incidents
  - changes
  - problems
  - configuration-items
  - knowledge-base
  - service-management
metadata:
  {
    "openclaw":
      {
        "emoji": "🔧",
        "requires": { "bins": ["curl", "jq"], "env": ["SN_INSTANCE", "SN_USER", "SN_PASSWORD"] }
      }
  }
---

# ServiceNow Skill

Query and manage records on any ServiceNow instance via the REST Table API.

## Setup

Set environment variables for your ServiceNow instance:

```bash
export SN_INSTANCE="https://yourinstance.service-now.com"
export SN_USER="your_username"
export SN_PASSWORD="your_password"
```

All tools below use `scripts/sn.sh` which reads these env vars.

## Tools

### sn_query — Query any table

```bash
bash scripts/sn.sh query <table> [options]
```

Options:
- `--query "<encoded_query>"` — ServiceNow encoded query (e.g. `active=true^priority=1`)
- `--fields "<field1,field2>"` — Comma-separated fields to return
- `--limit <n>` — Max records (default 20)
- `--offset <n>` — Pagination offset
- `--orderby "<field>"` — Sort field (prefix with `-` for descending)
- `--display <true|false|all>` — Display values mode

Examples:

```bash
# List open P1 incidents
bash scripts/sn.sh query incident --query "active=true^priority=1" --fields "number,short_description,state,assigned_to" --limit 10

# All users in IT department
bash scripts/sn.sh query sys_user --query "department=IT" --fields "user_name,email,name"

# Recent change requests
bash scripts/sn.sh query change_request --query "sys_created_on>=2024-01-01" --orderby "-sys_created_on" --limit 5
```

### sn_get — Get a single record by sys_id

```bash
bash scripts/sn.sh get <table> <sys_id> [options]
```

Options:
- `--fields "<field1,field2>"` — Fields to return
- `--display <true|false|all>` — Display values mode

Example:

```bash
bash scripts/sn.sh get incident abc123def456 --fields "number,short_description,state,assigned_to" --display true
```

### sn_create — Create a record

```bash
bash scripts/sn.sh create <table> '<json_fields>'
```

Example:

```bash
bash scripts/sn.sh create incident '{"short_description":"Server down","urgency":"1","impact":"1","assignment_group":"Service Desk"}'
```

### sn_update — Update a record

```bash
bash scripts/sn.sh update <table> <sys_id> '<json_fields>'
```

Example:

```bash
bash scripts/sn.sh update incident abc123def456 '{"state":"6","close_code":"Solved (Permanently)","close_notes":"Restarted service"}'
```

### sn_delete — Delete a record

```bash
bash scripts/sn.sh delete <table> <sys_id> --confirm
```

The `--confirm` flag is **required** to prevent accidental deletions.

### sn_aggregate — Aggregate queries

```bash
bash scripts/sn.sh aggregate <table> --type <TYPE> [options]
```

Types: `COUNT`, `AVG`, `MIN`, `MAX`, `SUM`

Options:
- `--type <TYPE>` — Aggregation type (required)
- `--query "<encoded_query>"` — Filter records
- `--field "<field>"` — Field to aggregate on (required for AVG/MIN/MAX/SUM)
- `--group-by "<field>"` — Group results by field
- `--display <true|false|all>` — Display values mode

Examples:

```bash
# Count open incidents by priority
bash scripts/sn.sh aggregate incident --type COUNT --query "active=true" --group-by "priority"

# Average reassignment count
bash scripts/sn.sh aggregate incident --type AVG --field "reassignment_count" --query "active=true"
```

### sn_schema — Get table schema

```bash
bash scripts/sn.sh schema <table> [--fields-only]
```

Returns field names, types, max lengths, mandatory flags, reference targets, and choice values.

Use `--fields-only` for a compact field list.

### sn_batch — Bulk update or delete records

```bash
bash scripts/sn.sh batch <table> --query "<encoded_query>" --action <update|delete> [--fields '{"field":"value"}'] [--limit 200] [--confirm]
```

Performs bulk update or delete operations on all records matching a query. Runs in **dry-run mode by default** — shows how many records match without making changes. Pass `--confirm` to execute.

Options:
- `--query "<encoded_query>"` — Filter records to operate on (required)
- `--action <update|delete>` — Operation to perform (required)
- `--fields '<json>'` — JSON fields to set on each record (required for update)
- `--limit <n>` — Max records to affect per run (default 200, safety cap at 10000)
- `--dry-run` — Show match count only, no changes (default behavior)
- `--confirm` — Actually execute the operation (disables dry-run)

Examples:

```bash
# Dry run: see how many resolved incidents older than 90 days would be affected
bash scripts/sn.sh batch incident --query "state=6^sys_updated_on<javascript:gs.daysAgo(90)" --action update

# Bulk close resolved incidents (actually execute)
bash scripts/sn.sh batch incident --query "state=6^sys_updated_on<javascript:gs.daysAgo(90)" --action update --fields '{"state":"7","close_code":"Solved (Permanently)","close_notes":"Auto-closed by batch"}' --confirm

# Dry run: count orphaned test records
bash scripts/sn.sh batch u_test_table --query "u_status=abandoned" --action delete

# Delete orphaned records (actually execute)
bash scripts/sn.sh batch u_test_table --query "u_status=abandoned" --action delete --limit 50 --confirm
```

Output (JSON summary):
```json
{"action":"update","table":"incident","matched":47,"processed":47,"failed":0}
```

### sn_health — Instance health check

```bash
bash scripts/sn.sh health [--check <all|version|nodes|jobs|semaphores|stats>]
```

Checks ServiceNow instance health across multiple dimensions. Default is `--check all` which runs every check.

Checks:
- **version** — Instance build version, date, and tag from sys_properties
- **nodes** — Cluster node status (online/offline) from sys_cluster_state
- **jobs** — Stuck/overdue scheduled jobs from sys_trigger (state=ready, next_action > 30 min past)
- **semaphores** — Active semaphores (potential locks) from sys_semaphore
- **stats** — Quick dashboard: active incidents, open P1s, active changes, open problems

Examples:

```bash
# Full health check
bash scripts/sn.sh health

# Just check version
bash scripts/sn.sh health --check version

# Check for stuck jobs
bash scripts/sn.sh health --check jobs

# Quick incident/change/problem dashboard
bash scripts/sn.sh health --check stats
```

Output (JSON):
```json
{
  "instance": "https://yourinstance.service-now.com",
  "timestamp": "2026-02-16T13:30:00Z",
  "version": {"build": "...", "build_date": "...", "build_tag": "..."},
  "nodes": [{"node_id": "...", "status": "online", "system_id": "..."}],
  "jobs": {"stuck": 0, "overdue": []},
  "semaphores": {"active": 2, "list": []},
  "stats": {"incidents_active": 54, "p1_open": 3, "changes_active": 12, "problems_open": 8}
}
```

### sn_nl — Natural Language Interface

```bash
bash scripts/sn.sh nl "<natural language text>" [--execute] [--confirm] [--force]
```

Translates natural language into the appropriate ServiceNow API call. Acts as a routing layer that parses intent, resolves table and field aliases, builds encoded queries, and either displays the planned command (dry-run) or executes it.

**How it works:**
1. Parses input text for table references, field values, operators, sort orders
2. Resolves 100+ table aliases (e.g., "incidents" → `incident`, "servers" → `cmdb_ci_server`)
3. Maps field aliases (P1 → `priority=1`, "open" → `active=true`, etc.)
4. Detects intent: QUERY, AGGREGATE, CREATE, UPDATE, DELETE, BATCH, SCHEMA
5. Builds the encoded query and outputs the exact `sn.sh` command
6. Read operations execute immediately; write operations require `--execute`

**Parameters:**
- First argument: Natural language text (quoted)
- `--execute` — Execute write operations (reads always execute)
- `--confirm` — Required for batch/bulk operations
- `--force` — Required for bulk deletes (in addition to `--confirm`)

**Safety:**
- ✅ Read operations (QUERY, AGGREGATE, SCHEMA) execute immediately
- ⚠️ Write operations (CREATE, UPDATE) show dry-run by default, require `--execute`
- ⚠️ Bulk writes (BATCH) require `--execute --confirm`
- 🛑 Bulk deletes require `--execute --confirm --force`

**Supported table aliases (30+):**
- ITSM: incidents, changes, problems, tasks, requests, ritms
- Users: users, people, groups, teams
- CMDB: servers, computers, databases, applications, services, cis, network gear
- Knowledge: articles, kb, knowledge
- Catalog: catalog items, sc tasks
- Admin: update sets, flows, business rules, notifications, properties

**Examples:**

```bash
# 1. Query — list open P1 incidents
bash scripts/sn.sh nl "show all P1 incidents"

# 2. Query — incidents assigned to a specific group
bash scripts/sn.sh nl "show incidents assigned to Network team"

# 3. Aggregate — count open changes
bash scripts/sn.sh nl "how many open changes are there"

# 4. Aggregate — count by priority
bash scripts/sn.sh nl "how many incidents grouped by priority"

# 5. Schema — get table fields
bash scripts/sn.sh nl "what fields are on the incident table"

# 6. Query — list CMDB servers
bash scripts/sn.sh nl "list servers in the CMDB"

# 7. Query — recent records with sorting
bash scripts/sn.sh nl "show tasks sorted by created date"

# 8. Create — new incident (dry-run by default)
bash scripts/sn.sh nl "create incident for email service down, P2, assign to Email Support"

# 9. Create — execute write operation
bash scripts/sn.sh nl "create incident for VPN outage, P1" --execute

# 10. Query — find specific record
bash scripts/sn.sh nl "show tasks for INC0000001"

# 11. Batch — bulk close (dry-run)
bash scripts/sn.sh nl "close all resolved incidents"

# 12. Batch — execute bulk update
bash scripts/sn.sh nl "close all resolved incidents" --execute --confirm

# 13. Query — users and groups
bash scripts/sn.sh nl "list all active users"

# 14. Query — time-based filter
bash scripts/sn.sh nl "show incidents from last week"

# 15. Query — knowledge articles
bash scripts/sn.sh nl "find knowledge articles about password reset"
```

**Output format:**
```
Intent:  QUERY
Table:   incident
Query:   priority=1^active=true
Limit:   20
Command: bash scripts/sn.sh query incident --query "priority=1^active=true" --fields number,short_description,state,priority,assigned_to,assignment_group,opened_at --limit 20 --display true

Executing...
[results]
```

### sn_attach — Manage attachments

```bash
# List attachments on a record
bash scripts/sn.sh attach list <table> <sys_id>

# Download an attachment
bash scripts/sn.sh attach download <attachment_sys_id> <output_path>

# Upload an attachment
bash scripts/sn.sh attach upload <table> <sys_id> <file_path> [content_type]
```

## Common Tables

| Table | Description |
|-------|-------------|
| `incident` | Incidents |
| `change_request` | Change Requests |
| `problem` | Problems |
| `sc_req_item` | Requested Items (RITMs) |
| `sc_request` | Requests |
| `sys_user` | Users |
| `sys_user_group` | Groups |
| `cmdb_ci` | Configuration Items |
| `cmdb_ci_server` | Servers |
| `kb_knowledge` | Knowledge Articles |
| `task` | Tasks (parent of incident/change/problem) |
| `sys_choice` | Choice list values |

## Encoded Query Syntax

ServiceNow encoded queries use `^` as AND, `^OR` as OR:

- `active=true^priority=1` — Active AND P1
- `active=true^ORactive=false` — Active OR inactive
- `short_descriptionLIKEserver` — Contains "server"
- `sys_created_on>=2024-01-01` — Created after date
- `assigned_toISEMPTY` — Unassigned
- `stateIN1,2,3` — State is 1, 2, or 3
- `caller_id.name=John Smith` — Dot-walk through references

## Notes

- All API calls use Basic Auth via `SN_USER` / `SN_PASSWORD`
- Default result limit is 20 records; use `--limit` to adjust
- Use `--display true` to get human-readable values instead of sys_ids for reference fields
- The script auto-detects whether `SN_INSTANCE` includes the protocol prefix
