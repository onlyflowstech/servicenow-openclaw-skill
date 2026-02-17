#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# ServiceNow Table API CLI — sn.sh
# The first ServiceNow skill for OpenClaw
#
# Author:  Brandon Wilson — ServiceNow Certified Technical Architect (CTA)
# Company: OnlyFlows (https://onlyflows.tech)
# GitHub:  https://github.com/onlyflowstech/servicenow-openclaw-skill
# License: MIT
# ──────────────────────────────────────────────────────────────────────
# Usage: bash sn.sh <command> [args...]
# Commands: query, get, create, update, delete, aggregate, schema, attach, batch, health, nl, script, relationships
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────
: "${SN_INSTANCE:?SN_INSTANCE env var required (e.g. https://instance.service-now.com)}"
: "${SN_USER:?SN_USER env var required}"
: "${SN_PASSWORD:?SN_PASSWORD env var required}"

# Ensure instance URL has no trailing slash and has https://
SN_INSTANCE="${SN_INSTANCE%/}"
[[ "$SN_INSTANCE" != http* ]] && SN_INSTANCE="https://$SN_INSTANCE"

AUTH="$SN_USER:$SN_PASSWORD"

# ── Helpers ────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "→ $*" >&2; }

sn_curl() {
  local method="$1" url="$2"
  shift 2
  curl -sf -X "$method" "$url" \
    -u "$AUTH" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@"
}

# ── query ──────────────────────────────────────────────────────────────
cmd_query() {
  local table="" query="" fields="" limit="20" offset="" orderby="" display=""
  table="${1:?Usage: sn.sh query <table> [options]}"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --query)   query="$2";   shift 2 ;;
      --fields)  fields="$2";  shift 2 ;;
      --limit)   limit="$2";   shift 2 ;;
      --offset)  offset="$2";  shift 2 ;;
      --orderby) orderby="$2"; shift 2 ;;
      --display) display="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  local url="${SN_INSTANCE}/api/now/table/${table}?sysparm_limit=${limit}"
  [[ -n "$query" ]]   && url+="&sysparm_query=$(jq -rn --arg v "$query" '$v | @uri')"
  [[ -n "$fields" ]]  && url+="&sysparm_fields=${fields}"
  [[ -n "$offset" ]]  && url+="&sysparm_offset=${offset}"
  [[ -n "$orderby" ]] && url+="&sysparm_orderby=${orderby}"
  [[ -n "$display" ]] && url+="&sysparm_display_value=${display}"

  info "GET $table (limit=$limit)"
  local resp
  resp=$(sn_curl GET "$url") || die "API request failed"

  local count
  count=$(echo "$resp" | jq '.result | length')
  echo "$resp" | jq '{record_count: (.result | length), results: .result}'
  info "Returned $count record(s)"
}

# ── get ────────────────────────────────────────────────────────────────
cmd_get() {
  local table="${1:?Usage: sn.sh get <table> <sys_id> [options]}"
  local sys_id="${2:?Usage: sn.sh get <table> <sys_id> [options]}"
  shift 2

  local fields="" display=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fields)  fields="$2";  shift 2 ;;
      --display) display="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  local url="${SN_INSTANCE}/api/now/table/${table}/${sys_id}"
  local sep="?"
  [[ -n "$fields" ]]  && url+="${sep}sysparm_fields=${fields}" && sep="&"
  [[ -n "$display" ]] && url+="${sep}sysparm_display_value=${display}"

  info "GET $table/$sys_id"
  sn_curl GET "$url" | jq '.result'
}

# ── create ─────────────────────────────────────────────────────────────
cmd_create() {
  local table="${1:?Usage: sn.sh create <table> '<json>'}"
  local json="${2:?Usage: sn.sh create <table> '<json>'}"
  shift 2

  # Validate JSON
  echo "$json" | jq . >/dev/null 2>&1 || die "Invalid JSON: $json"

  local url="${SN_INSTANCE}/api/now/table/${table}"
  info "POST $table"
  local resp
  resp=$(sn_curl POST "$url" -d "$json") || die "Create failed"
  echo "$resp" | jq '{sys_id: .result.sys_id, number: .result.number, result: .result}'
  info "Created record: $(echo "$resp" | jq -r '.result.sys_id')"
}

# ── update ─────────────────────────────────────────────────────────────
cmd_update() {
  local table="${1:?Usage: sn.sh update <table> <sys_id> '<json>'}"
  local sys_id="${2:?Usage: sn.sh update <table> <sys_id> '<json>'}"
  local json="${3:?Usage: sn.sh update <table> <sys_id> '<json>'}"
  shift 3

  echo "$json" | jq . >/dev/null 2>&1 || die "Invalid JSON: $json"

  local url="${SN_INSTANCE}/api/now/table/${table}/${sys_id}"
  info "PATCH $table/$sys_id"
  local resp
  resp=$(sn_curl PATCH "$url" -d "$json") || die "Update failed"
  echo "$resp" | jq '.result'
  info "Updated record: $sys_id"
}

# ── delete ─────────────────────────────────────────────────────────────
cmd_delete() {
  local table="${1:?Usage: sn.sh delete <table> <sys_id> --confirm}"
  local sys_id="${2:?Usage: sn.sh delete <table> <sys_id> --confirm}"
  shift 2

  local confirmed=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --confirm) confirmed=true; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ "$confirmed" != "true" ]] && die "Must pass --confirm to delete records. This is a safety measure."

  local url="${SN_INSTANCE}/api/now/table/${table}/${sys_id}"
  info "DELETE $table/$sys_id"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$url" \
    -u "$AUTH" \
    -H "Accept: application/json")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    echo '{"status":"deleted","sys_id":"'"$sys_id"'","table":"'"$table"'"}'
    info "Deleted $table/$sys_id"
  elif [[ "$http_code" == "404" ]]; then
    die "Record not found: $table/$sys_id"
  else
    die "Delete failed with HTTP $http_code"
  fi
}

# ── aggregate ──────────────────────────────────────────────────────────
cmd_aggregate() {
  local table="${1:?Usage: sn.sh aggregate <table> --type <TYPE> [options]}"
  shift

  local agg_type="" query="" field="" group_by="" display=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)     agg_type="$2"; shift 2 ;;
      --query)    query="$2";    shift 2 ;;
      --field)    field="$2";    shift 2 ;;
      --group-by) group_by="$2"; shift 2 ;;
      --display)  display="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -z "$agg_type" ]] && die "Usage: sn.sh aggregate <table> --type <COUNT|AVG|MIN|MAX|SUM> [options]"
  agg_type=$(echo "$agg_type" | tr '[:lower:]' '[:upper:]')

  # Validate: AVG/MIN/MAX/SUM need --field
  if [[ "$agg_type" != "COUNT" && -z "$field" ]]; then
    die "$agg_type requires --field <fieldname>"
  fi

  local url="${SN_INSTANCE}/api/now/stats/${table}"
  local sep="?"

  if [[ "$agg_type" == "COUNT" ]]; then
    url+="${sep}sysparm_count=true"
  else
    url+="${sep}sysparm_${agg_type,,}_fields=${field}"
  fi
  sep="&"

  [[ -n "$query" ]]    && url+="${sep}sysparm_query=$(jq -rn --arg v "$query" '$v | @uri')"
  [[ -n "$group_by" ]] && url+="${sep}sysparm_group_by=${group_by}"
  [[ -n "$display" ]]  && url+="${sep}sysparm_display_value=${display}"

  info "STATS $agg_type on $table"
  local resp
  resp=$(sn_curl GET "$url") || die "Aggregate request failed"
  echo "$resp" | jq '.result'
}

# ── schema ─────────────────────────────────────────────────────────────
cmd_schema() {
  local table="${1:?Usage: sn.sh schema <table> [--fields-only]}"
  shift
  local fields_only=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fields-only) fields_only=true; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  info "SCHEMA $table (via sys_dictionary)"

  local url="${SN_INSTANCE}/api/now/table/sys_dictionary?sysparm_query=name=${table}^internal_type!=collection&sysparm_fields=element,column_label,internal_type,max_length,mandatory,reference&sysparm_limit=500&sysparm_display_value=true"

  local resp
  resp=$(sn_curl GET "$url") || die "Schema request failed"

  if [[ "$fields_only" == "true" ]]; then
    echo "$resp" | jq '[.result[] | select(.element != "") | .element] | sort'
  else
    echo "$resp" | jq '[.result[] | select(.element != "") | {
      field: .element,
      label: .column_label,
      type: .internal_type,
      max_length: .max_length,
      mandatory: .mandatory,
      reference: (if .reference != "" then .reference else null end)
    }] | sort_by(.field)'
  fi
}

# ── attach ─────────────────────────────────────────────────────────────
cmd_attach() {
  local subcmd="${1:?Usage: sn.sh attach <list|download|upload> ...}"
  shift

  case "$subcmd" in
    list)
      local table="${1:?Usage: sn.sh attach list <table> <sys_id>}"
      local sys_id="${2:?Usage: sn.sh attach list <table> <sys_id>}"
      local url="${SN_INSTANCE}/api/now/attachment?sysparm_query=table_name=${table}^table_sys_id=${sys_id}"
      info "LIST attachments on $table/$sys_id"
      sn_curl GET "$url" | jq '[.result[] | {sys_id: .sys_id, file_name: .file_name, size_bytes: .size_bytes, content_type: .content_type, download_link: .download_link}]'
      ;;
    download)
      local att_id="${1:?Usage: sn.sh attach download <attachment_sys_id> <output_path>}"
      local output="${2:?Usage: sn.sh attach download <attachment_sys_id> <output_path>}"
      local url="${SN_INSTANCE}/api/now/attachment/${att_id}/file"
      info "DOWNLOAD attachment $att_id → $output"
      curl -sf -o "$output" "$url" -u "$AUTH" || die "Download failed"
      echo '{"status":"downloaded","path":"'"$output"'"}'
      ;;
    upload)
      local table="${1:?Usage: sn.sh attach upload <table> <sys_id> <file_path> [content_type]}"
      local sys_id="${2:?Usage: sn.sh attach upload <table> <sys_id> <file_path> [content_type]}"
      local filepath="${3:?Usage: sn.sh attach upload <table> <sys_id> <file_path> [content_type]}"
      local ctype="${4:-application/octet-stream}"
      local filename
      filename=$(basename "$filepath")
      local url="${SN_INSTANCE}/api/now/attachment/file?table_name=${table}&table_sys_id=${sys_id}&file_name=${filename}"
      info "UPLOAD $filename to $table/$sys_id"
      curl -sf -X POST "$url" \
        -u "$AUTH" \
        -H "Accept: application/json" \
        -H "Content-Type: ${ctype}" \
        --data-binary "@${filepath}" | jq '.result | {sys_id, file_name, size_bytes, table_name, table_sys_id}'
      ;;
    *) die "Unknown attach subcommand: $subcmd (use list, download, upload)" ;;
  esac
}

# ── batch ──────────────────────────────────────────────────────────────
cmd_batch() {
  local table="${1:?Usage: sn.sh batch <table> --query \"<query>\" --action <update|delete> [--fields '{...}'] [--dry-run] [--limit 200] [--confirm]}"
  shift

  local query="" action="" fields="" dry_run=true limit=200 confirmed=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --query)   query="$2";   shift 2 ;;
      --action)  action="$2";  shift 2 ;;
      --fields)  fields="$2";  shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --limit)   limit="$2";   shift 2 ;;
      --confirm) confirmed=true; dry_run=false; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -z "$action" ]] && die "Missing --action <update|delete>"
  [[ "$action" != "update" && "$action" != "delete" ]] && die "--action must be 'update' or 'delete'"
  [[ -z "$query" ]] && die "Missing --query (required for batch operations — refusing to operate on all records)"
  [[ "$action" == "update" && -z "$fields" ]] && die "--fields required for update action"

  # Validate fields JSON if provided
  if [[ -n "$fields" ]]; then
    echo "$fields" | jq . >/dev/null 2>&1 || die "Invalid JSON in --fields: $fields"
  fi

  # Safety cap on limit
  if (( limit > 10000 )); then
    info "WARNING: Capping limit from $limit to 10000 for safety"
    limit=10000
  fi

  # Step 1: Query matching records (sys_id only for efficiency)
  local url="${SN_INSTANCE}/api/now/table/${table}?sysparm_fields=sys_id&sysparm_limit=${limit}"
  url+="&sysparm_query=$(jq -rn --arg v "$query" '$v | @uri')"

  info "Querying $table for matching records..."
  local resp
  resp=$(sn_curl GET "$url") || die "Failed to query matching records"

  local matched
  matched=$(echo "$resp" | jq '.result | length')
  info "Found $matched record(s) matching query on $table"

  # Step 2: Dry-run check
  if [[ "$dry_run" == "true" ]]; then
    echo "{\"action\":\"$action\",\"table\":\"$table\",\"matched\":$matched,\"dry_run\":true,\"message\":\"Dry run — no changes made. Use --confirm to execute.\"}"
    return 0
  fi

  # Step 3: Safety confirmation
  if [[ "$confirmed" != "true" ]]; then
    die "Must pass --confirm to execute batch $action. Found $matched records. This is a safety measure."
  fi

  if [[ "$matched" -eq 0 ]]; then
    echo "{\"action\":\"$action\",\"table\":\"$table\",\"matched\":0,\"processed\":0,\"failed\":0}"
    return 0
  fi

  # Step 4: Extract sys_ids and iterate
  local sys_ids
  sys_ids=$(echo "$resp" | jq -r '.result[].sys_id')

  local processed=0 failed=0 total="$matched"

  while IFS= read -r sys_id; do
    [[ -z "$sys_id" ]] && continue

    if [[ "$action" == "update" ]]; then
      local patch_url="${SN_INSTANCE}/api/now/table/${table}/${sys_id}"
      if sn_curl PATCH "$patch_url" -d "$fields" >/dev/null 2>&1; then
        processed=$((processed + 1))
      else
        failed=$((failed + 1))
        info "FAILED to update $sys_id"
      fi
    elif [[ "$action" == "delete" ]]; then
      local del_url="${SN_INSTANCE}/api/now/table/${table}/${sys_id}"
      local http_code
      http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$del_url" \
        -u "$AUTH" \
        -H "Accept: application/json")
      if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        processed=$((processed + 1))
      else
        failed=$((failed + 1))
        info "FAILED to delete $sys_id (HTTP $http_code)"
      fi
    fi

    # Progress every 10 records or at the end
    if (( processed % 10 == 0 )) || (( processed + failed == total )); then
      info "${action^}d $((processed + failed)) of $total records ($failed failed)"
    fi
  done <<< "$sys_ids"

  echo "{\"action\":\"$action\",\"table\":\"$table\",\"matched\":$matched,\"processed\":$processed,\"failed\":$failed}"
  info "Batch $action complete: $processed succeeded, $failed failed out of $matched"
}

# ── health ─────────────────────────────────────────────────────────────
cmd_health() {
  local check="all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) check="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  local valid_checks="all version nodes jobs semaphores stats"
  if [[ ! " $valid_checks " =~ " $check " ]]; then
    die "Invalid check: $check (valid: $valid_checks)"
  fi

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Start building JSON output
  local output
  output=$(jq -n --arg inst "$SN_INSTANCE" --arg ts "$timestamp" \
    '{instance: $inst, timestamp: $ts}')

  # ── version check ──
  if [[ "$check" == "all" || "$check" == "version" ]]; then
    info "Checking instance version..."
    local ver_output='{}'

    # Get glide.war (build version)
    local ver_url="${SN_INSTANCE}/api/now/table/sys_properties?sysparm_query=name=glide.war&sysparm_fields=value&sysparm_limit=1"
    local ver_resp
    if ver_resp=$(sn_curl GET "$ver_url" 2>/dev/null); then
      local build_val
      build_val=$(echo "$ver_resp" | jq -r '.result[0].value // "unknown"')
      ver_output=$(echo "$ver_output" | jq --arg b "$build_val" '. + {build: $b}')
    else
      ver_output=$(echo "$ver_output" | jq '. + {build: "unavailable"}')
    fi

    # Get build date
    local date_url="${SN_INSTANCE}/api/now/table/sys_properties?sysparm_query=name=glide.build.date&sysparm_fields=value&sysparm_limit=1"
    if ver_resp=$(sn_curl GET "$date_url" 2>/dev/null); then
      local build_date
      build_date=$(echo "$ver_resp" | jq -r '.result[0].value // "unknown"')
      ver_output=$(echo "$ver_output" | jq --arg d "$build_date" '. + {build_date: $d}')
    fi

    # Get build tag
    local tag_url="${SN_INSTANCE}/api/now/table/sys_properties?sysparm_query=name=glide.build.tag&sysparm_fields=value&sysparm_limit=1"
    if ver_resp=$(sn_curl GET "$tag_url" 2>/dev/null); then
      local build_tag
      build_tag=$(echo "$ver_resp" | jq -r '.result[0].value // "unknown"')
      ver_output=$(echo "$ver_output" | jq --arg t "$build_tag" '. + {build_tag: $t}')
    fi

    output=$(echo "$output" | jq --argjson v "$ver_output" '. + {version: $v}')
    info "Version check complete"
  fi

  # ── nodes check ──
  if [[ "$check" == "all" || "$check" == "nodes" ]]; then
    info "Checking cluster nodes..."
    local nodes_url="${SN_INSTANCE}/api/now/table/sys_cluster_state?sysparm_fields=node_id,status,system_id,most_recent_message&sysparm_limit=50"
    local nodes_resp
    if nodes_resp=$(sn_curl GET "$nodes_url" 2>/dev/null); then
      local nodes_arr
      nodes_arr=$(echo "$nodes_resp" | jq '[.result[] | {
        node_id: .node_id,
        status: .status,
        system_id: .system_id,
        most_recent_message: .most_recent_message
      }]')
      output=$(echo "$output" | jq --argjson n "$nodes_arr" '. + {nodes: $n}')
    else
      output=$(echo "$output" | jq '. + {nodes: {"error": "Unable to query sys_cluster_state — check ACLs"}}')
    fi
    info "Nodes check complete"
  fi

  # ── jobs check ──
  if [[ "$check" == "all" || "$check" == "jobs" ]]; then
    info "Checking scheduled jobs..."
    local jobs_query="state=0^next_action<javascript:gs.minutesAgo(30)"
    local jobs_url="${SN_INSTANCE}/api/now/table/sys_trigger?sysparm_fields=name,next_action,state,trigger_type&sysparm_limit=20"
    jobs_url+="&sysparm_query=$(jq -rn --arg v "$jobs_query" '$v | @uri')"
    local jobs_resp
    if jobs_resp=$(sn_curl GET "$jobs_url" 2>/dev/null); then
      local stuck_count overdue_list
      stuck_count=$(echo "$jobs_resp" | jq '.result | length')
      overdue_list=$(echo "$jobs_resp" | jq '[.result[] | {
        name: .name,
        next_action: .next_action,
        state: .state,
        trigger_type: .trigger_type
      }]')
      output=$(echo "$output" | jq --argjson sc "$stuck_count" --argjson ol "$overdue_list" \
        '. + {jobs: {stuck: $sc, overdue: $ol}}')
    else
      output=$(echo "$output" | jq '. + {jobs: {"error": "Unable to query sys_trigger — check ACLs"}}')
    fi
    info "Jobs check complete"
  fi

  # ── semaphores check ──
  if [[ "$check" == "all" || "$check" == "semaphores" ]]; then
    info "Checking semaphores..."
    local sem_url="${SN_INSTANCE}/api/now/table/sys_semaphore?sysparm_query=state=active&sysparm_fields=name,state,holder&sysparm_limit=20"
    local sem_resp
    if sem_resp=$(sn_curl GET "$sem_url" 2>/dev/null); then
      local sem_count sem_list
      sem_count=$(echo "$sem_resp" | jq '.result | length')
      sem_list=$(echo "$sem_resp" | jq '[.result[] | {
        name: .name,
        state: .state,
        holder: .holder
      }]')
      output=$(echo "$output" | jq --argjson ac "$sem_count" --argjson sl "$sem_list" \
        '. + {semaphores: {active: $ac, list: $sl}}')
    else
      output=$(echo "$output" | jq '. + {semaphores: {"error": "Unable to query sys_semaphore — check ACLs"}}')
    fi
    info "Semaphores check complete"
  fi

  # ── stats check ──
  if [[ "$check" == "all" || "$check" == "stats" ]]; then
    info "Gathering instance stats..."
    local stats_output='{}'

    # Active incidents (state != 7 = Closed)
    local inc_url="${SN_INSTANCE}/api/now/stats/incident?sysparm_count=true&sysparm_query=$(jq -rn --arg v 'state!=7' '$v | @uri')"
    local inc_resp
    if inc_resp=$(sn_curl GET "$inc_url" 2>/dev/null); then
      local inc_count
      inc_count=$(echo "$inc_resp" | jq -r '.result.stats.count // "0"')
      stats_output=$(echo "$stats_output" | jq --arg c "$inc_count" '. + {incidents_active: ($c | tonumber)}')
    fi

    # Open P1 incidents
    local p1_url="${SN_INSTANCE}/api/now/stats/incident?sysparm_count=true&sysparm_query=$(jq -rn --arg v 'active=true^priority=1' '$v | @uri')"
    local p1_resp
    if p1_resp=$(sn_curl GET "$p1_url" 2>/dev/null); then
      local p1_count
      p1_count=$(echo "$p1_resp" | jq -r '.result.stats.count // "0"')
      stats_output=$(echo "$stats_output" | jq --arg c "$p1_count" '. + {p1_open: ($c | tonumber)}')
    fi

    # Active changes
    local chg_url="${SN_INSTANCE}/api/now/stats/change_request?sysparm_count=true&sysparm_query=$(jq -rn --arg v 'active=true' '$v | @uri')"
    local chg_resp
    if chg_resp=$(sn_curl GET "$chg_url" 2>/dev/null); then
      local chg_count
      chg_count=$(echo "$chg_resp" | jq -r '.result.stats.count // "0"')
      stats_output=$(echo "$stats_output" | jq --arg c "$chg_count" '. + {changes_active: ($c | tonumber)}')
    fi

    # Open problems
    local prb_url="${SN_INSTANCE}/api/now/stats/problem?sysparm_count=true&sysparm_query=$(jq -rn --arg v 'active=true' '$v | @uri')"
    local prb_resp
    if prb_resp=$(sn_curl GET "$prb_url" 2>/dev/null); then
      local prb_count
      prb_count=$(echo "$prb_resp" | jq -r '.result.stats.count // "0"')
      stats_output=$(echo "$stats_output" | jq --arg c "$prb_count" '. + {problems_open: ($c | tonumber)}')
    fi

    output=$(echo "$output" | jq --argjson s "$stats_output" '. + {stats: $s}')
    info "Stats check complete"
  fi

  echo "$output" | jq .
}

# ── nl (natural language) ───────────────────────────────────────────────
cmd_nl() {
  local input="" execute=false confirm=false force=false
  # Gather all positional args as input text, plus flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute) execute=true; shift ;;
      --confirm) confirm=true; shift ;;
      --force)   force=true;   shift ;;
      *)
        if [[ -z "$input" ]]; then
          input="$1"
        else
          input="$input $1"
        fi
        shift
        ;;
    esac
  done

  [[ -z "$input" ]] && die "Usage: sn.sh nl \"<natural language text>\" [--execute] [--confirm] [--force]"

  # Lowercase the input for matching
  local lower
  lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')

  # ── TABLE ALIASES (30+ mappings) ──────────────────────────────────
  declare -A TABLE_ALIASES=(
    # ITSM core
    ["incident"]="incident"
    ["incidents"]="incident"
    ["inc"]="incident"
    ["ticket"]="incident"
    ["tickets"]="incident"
    ["change"]="change_request"
    ["changes"]="change_request"
    ["change request"]="change_request"
    ["change requests"]="change_request"
    ["chg"]="change_request"
    ["problem"]="problem"
    ["problems"]="problem"
    ["prb"]="problem"
    ["task"]="task"
    ["tasks"]="task"
    # User / group
    ["user"]="sys_user"
    ["users"]="sys_user"
    ["people"]="sys_user"
    ["person"]="sys_user"
    ["group"]="sys_user_group"
    ["groups"]="sys_user_group"
    ["team"]="sys_user_group"
    ["teams"]="sys_user_group"
    # CMDB
    ["server"]="cmdb_ci_server"
    ["servers"]="cmdb_ci_server"
    ["ci"]="cmdb_ci"
    ["cis"]="cmdb_ci"
    ["configuration item"]="cmdb_ci"
    ["configuration items"]="cmdb_ci"
    ["cmdb"]="cmdb_ci"
    ["computer"]="cmdb_ci_computer"
    ["computers"]="cmdb_ci_computer"
    ["laptop"]="cmdb_ci_computer"
    ["laptops"]="cmdb_ci_computer"
    ["desktop"]="cmdb_ci_computer"
    ["desktops"]="cmdb_ci_computer"
    ["network"]="cmdb_ci_netgear"
    ["network gear"]="cmdb_ci_netgear"
    ["router"]="cmdb_ci_netgear"
    ["routers"]="cmdb_ci_netgear"
    ["switch"]="cmdb_ci_netgear"
    ["switches"]="cmdb_ci_netgear"
    ["database"]="cmdb_ci_database"
    ["databases"]="cmdb_ci_database"
    ["db"]="cmdb_ci_database"
    ["application"]="cmdb_ci_appl"
    ["applications"]="cmdb_ci_appl"
    ["app"]="cmdb_ci_appl"
    ["apps"]="cmdb_ci_appl"
    ["service"]="cmdb_ci_service"
    ["services"]="cmdb_ci_service"
    ["business service"]="cmdb_ci_service"
    ["business services"]="cmdb_ci_service"
    # Knowledge
    ["knowledge"]="kb_knowledge"
    ["knowledge article"]="kb_knowledge"
    ["knowledge articles"]="kb_knowledge"
    ["article"]="kb_knowledge"
    ["articles"]="kb_knowledge"
    ["kb"]="kb_knowledge"
    # Service Catalog
    ["catalog item"]="sc_cat_item"
    ["catalog items"]="sc_cat_item"
    ["catalogue item"]="sc_cat_item"
    ["catalogue items"]="sc_cat_item"
    ["request"]="sc_request"
    ["requests"]="sc_request"
    ["req"]="sc_request"
    ["requested item"]="sc_req_item"
    ["requested items"]="sc_req_item"
    ["ritm"]="sc_req_item"
    ["ritms"]="sc_req_item"
    ["sc task"]="sc_task"
    ["catalog task"]="sc_task"
    ["catalog tasks"]="sc_task"
    # ITOM / Events
    ["event"]="sysevent"
    ["events"]="sysevent"
    ["alert"]="em_alert"
    ["alerts"]="em_alert"
    # Other common
    ["sla"]="task_sla"
    ["slas"]="task_sla"
    ["attachment"]="sys_attachment"
    ["attachments"]="sys_attachment"
    ["journal"]="sys_journal_field"
    ["comments"]="sys_journal_field"
    ["work note"]="sys_journal_field"
    ["work notes"]="sys_journal_field"
    ["audit"]="sys_audit"
    ["audit log"]="sys_audit"
    ["property"]="sys_properties"
    ["properties"]="sys_properties"
    ["scheduled job"]="sysauto"
    ["scheduled jobs"]="sysauto"
    ["script"]="sys_script"
    ["business rule"]="sys_script"
    ["business rules"]="sys_script"
    ["ui policy"]="sys_ui_policy"
    ["ui policies"]="sys_ui_policy"
    ["client script"]="sys_script_client"
    ["client scripts"]="sys_script_client"
    ["update set"]="sys_update_set"
    ["update sets"]="sys_update_set"
    ["flow"]="sys_hub_flow"
    ["flows"]="sys_hub_flow"
    ["notification"]="sysevent_email_action"
    ["notifications"]="sysevent_email_action"
    ["email"]="sys_email"
    ["emails"]="sys_email"
    ["relationship"]="cmdb_rel_ci"
    ["relationships"]="cmdb_rel_ci"
    ["ci relationship"]="cmdb_rel_ci"
    ["ci relationships"]="cmdb_rel_ci"
  )

  # ── Resolve table from input ──────────────────────────────────────
  local resolved_table=""

  # Try longest match first (multi-word aliases)
  # Sort aliases by length descending so "change requests" matches before "change"
  local sorted_aliases
  sorted_aliases=$(for key in "${!TABLE_ALIASES[@]}"; do echo "$key"; done | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

  while IFS= read -r alias; do
    [[ -z "$alias" ]] && continue
    if [[ "$lower" == *"$alias"* ]]; then
      resolved_table="${TABLE_ALIASES[$alias]}"
      break
    fi
  done <<< "$sorted_aliases"

  # If no alias matched, try to find a raw table name pattern (e.g. sys_user, cmdb_ci_*)
  if [[ -z "$resolved_table" ]]; then
    local raw_table
    raw_table=$(echo "$lower" | grep -oP '[a-z][a-z_]+_[a-z_]+' | head -1)
    if [[ -n "$raw_table" ]]; then
      resolved_table="$raw_table"
    fi
  fi

  # ── Detect intent ─────────────────────────────────────────────────
  local intent=""

  # Check for schema/fields intent first
  if echo "$lower" | grep -qP '(schema|fields|columns|structure|what fields|describe table|table definition|field list)'; then
    intent="SCHEMA"
  # Check for aggregate/count
  elif echo "$lower" | grep -qP '(how many|count of|total number|number of|count all|tally|sum of|average|avg of|minimum|maximum)'; then
    intent="AGGREGATE"
  # Check for create intent
  elif echo "$lower" | grep -qP '(^create|^new|^add|^open|^log|^raise|^submit|^register)'; then
    intent="CREATE"
  # Check for update intent
  elif echo "$lower" | grep -qP '(^update|^change|^set|^modify|^edit|^patch|^reassign|^escalate)'; then
    intent="UPDATE"
  # Check for batch intent
  elif echo "$lower" | grep -qP '(close all|update all|delete all|bulk|mass update|mass close|batch)'; then
    intent="BATCH"
  # Check for delete intent
  elif echo "$lower" | grep -qP '(^delete|^remove|^destroy|^purge)'; then
    intent="DELETE"
  # Default: QUERY (show, list, get, find, etc.)
  else
    intent="QUERY"
  fi

  # ── Parse priority ────────────────────────────────────────────────
  local query_parts=()

  # P1/P2/P3/P4 or "priority 1" etc.
  if echo "$lower" | grep -qP '\bp1\b|priority\s*1|critical priority'; then
    query_parts+=("priority=1")
  elif echo "$lower" | grep -qP '\bp2\b|priority\s*2|high priority'; then
    query_parts+=("priority=2")
  elif echo "$lower" | grep -qP '\bp3\b|priority\s*3|moderate priority|medium priority'; then
    query_parts+=("priority=3")
  elif echo "$lower" | grep -qP '\bp4\b|priority\s*4|low priority'; then
    query_parts+=("priority=4")
  elif echo "$lower" | grep -qP '\bp5\b|priority\s*5|planning'; then
    query_parts+=("priority=5")
  fi

  # ── Parse state ───────────────────────────────────────────────────
  if echo "$lower" | grep -qP '\bopen\b|\bnew\b'; then
    query_parts+=("active=true")
  elif echo "$lower" | grep -qP '\bclosed\b|\bcomplete\b|\bcompleted\b'; then
    query_parts+=("state=7")
  elif echo "$lower" | grep -qP '\bresolved\b|\bfixed\b'; then
    query_parts+=("state=6")
  elif echo "$lower" | grep -qP '\bin progress\b|\bwork in progress\b|\bwip\b'; then
    query_parts+=("state=2")
  elif echo "$lower" | grep -qP '\bon hold\b|\bpending\b|\bwaiting\b'; then
    query_parts+=("state=3")
  elif echo "$lower" | grep -qP '\bactive\b'; then
    query_parts+=("active=true")
  elif echo "$lower" | grep -qP '\binactive\b|\barchived\b'; then
    query_parts+=("active=false")
  fi

  # ── Parse assignment ──────────────────────────────────────────────
  local assigned_to="" assignment_group=""

  # "assigned to <person>" — use original input for proper case
  if [[ "$input" =~ [Aa]ssigned[[:space:]]+[Tt]o[[:space:]]+([a-zA-Z][a-zA-Z[:space:]]+) ]]; then
    assigned_to="${BASH_REMATCH[1]}"
    # Trim trailing known keywords
    assigned_to=$(echo "$assigned_to" | sed -E 's/\s+(sorted|order|limit|since|from|with|and|or|in|on|by|the)(\s.*)?$//')
    assigned_to=$(echo "$assigned_to" | sed 's/[[:space:]]*$//')
    if [[ -n "$assigned_to" ]]; then
      query_parts+=("assigned_to.name=${assigned_to}")
    fi
  fi

  # "assignment group <group>" or "assign to <group> team/group"
  if [[ "$input" =~ ([Aa]ssignment[[:space:]]+[Gg]roup|[Aa]ssign[[:space:]]+[Tt]o[[:space:]]+[Gg]roup|[Tt]eam)[[:space:]]+([a-zA-Z][a-zA-Z[:space:]]+) ]]; then
    assignment_group="${BASH_REMATCH[2]}"
    assignment_group=$(echo "$assignment_group" | sed -E 's/\s+(sorted|order|limit|since|from|with|and|or|in|on|by|the)(\s.*)?$//')
    assignment_group=$(echo "$assignment_group" | sed 's/[[:space:]]*$//')
  fi

  # Check for patterns like "assigned to Network team" or "assigned to <X>"
  if [[ -z "$assignment_group" ]] && [[ "$input" =~ [Aa]ssigned[[:space:]]+[Tt]o[[:space:]]+(.+?)[[:space:]]+(team|group|Team|Group) ]]; then
    assignment_group="${BASH_REMATCH[1]}"
  fi

  # "assign to <Name>" (without team/group suffix — common in create requests)
  # Use original input (not lowered) to preserve case of group/person names
  if [[ -z "$assignment_group" ]] && [[ "$input" =~ [Aa]ssign[[:space:]]+[Tt]o[[:space:]]+([A-Za-z][A-Za-z[:space:]]+) ]]; then
    assignment_group="${BASH_REMATCH[1]}"
    assignment_group=$(echo "$assignment_group" | sed -E 's/\s+(sorted|order|limit|since|from|with|and|or|in|on|by|the)(\s.*)?$//')
    assignment_group=$(echo "$assignment_group" | sed 's/[[:space:]]*$//')
    # If we also parsed this as "assigned_to", prefer assignment_group
    local new_parts2=()
    for part in "${query_parts[@]}"; do
      if [[ "$part" != assigned_to.name=* ]]; then
        new_parts2+=("$part")
      fi
    done
    query_parts=("${new_parts2[@]}")
  fi

  # Simpler pattern: "<table> for <group>" might refer to assignment group
  if [[ -z "$assignment_group" ]] && echo "$lower" | grep -qP '\b(for|from)\s+\w+\s+(team|group)\b'; then
    assignment_group=$(echo "$lower" | grep -oP '(?:for|from)\s+\K\w[\w\s]+?(?=\s+(?:team|group))' | head -1)
  fi

  if [[ -n "$assignment_group" ]]; then
    # Remove "assigned_to" part if we also found an assignment_group
    local new_parts=()
    for part in "${query_parts[@]}"; do
      if [[ "$part" != assigned_to.name=* ]]; then
        new_parts+=("$part")
      fi
    done
    query_parts=("${new_parts[@]}")
    query_parts+=("assignment_group.name=${assignment_group}")
  fi

  # ── Parse category ────────────────────────────────────────────────
  if [[ "$lower" =~ category[[:space:]]+([\"\']?)([a-zA-Z][a-zA-Z[:space:]]+)\1 ]]; then
    local cat_val="${BASH_REMATCH[2]}"
    cat_val=$(echo "$cat_val" | sed -E 's/\s+(sorted|order|limit|since|from|with|and|or|in|on|by|the)(\s.*)?$//')
    query_parts+=("category=${cat_val}")
  fi

  # ── Parse short_description LIKE ──────────────────────────────────
  if [[ "$lower" =~ (about|containing|contains|like|matching|regarding|related[[:space:]]+to|for)[[:space:]]+([\"\']?)([a-zA-Z][a-zA-Z[:space:]]+)\2 ]]; then
    local desc_match="${BASH_REMATCH[3]}"
    desc_match=$(echo "$desc_match" | sed -E 's/\s+(sorted|order|limit|since|from|with|and|or|in|on|by|the)(\s.*)?$//')
    # Only add if it doesn't look like an already-parsed concept
    if [[ ! "$desc_match" =~ ^(group|team|network|p[1-5]|open|closed|resolved|active)$ ]]; then
      query_parts+=("short_descriptionLIKE${desc_match}")
    fi
  fi

  # ── Parse specific record reference ──────────────────────────────
  local ref_number=""
  if [[ "$lower" =~ (inc|chg|prb|ritm|req|task|kb)[0-9]{7,10} ]]; then
    ref_number=$(echo "$lower" | grep -oiP '(INC|CHG|PRB|RITM|REQ|TASK|KB)[0-9]{7,10}' | head -1 | tr '[:lower:]' '[:upper:]')
  fi

  # If we found a record number, add it to query
  if [[ -n "$ref_number" ]]; then
    query_parts+=("number=${ref_number}")
    # Also infer table from prefix if not already resolved
    if [[ -z "$resolved_table" ]]; then
      case "${ref_number:0:3}" in
        INC) resolved_table="incident" ;;
        CHG) resolved_table="change_request" ;;
        PRB) resolved_table="problem" ;;
        RIT) resolved_table="sc_req_item" ;;
        REQ) resolved_table="sc_request" ;;
        TAS) resolved_table="task" ;;
        KB0) resolved_table="kb_knowledge" ;;
      esac
    fi
  fi

  # ── Parse date/time filters ──────────────────────────────────────
  if echo "$lower" | grep -qP 'last\s+(24\s+hours?|day)'; then
    query_parts+=("sys_created_on>=javascript:gs.hoursAgo(24)")
  elif echo "$lower" | grep -qP 'last\s+week|past\s+week'; then
    query_parts+=("sys_created_on>=javascript:gs.daysAgo(7)")
  elif echo "$lower" | grep -qP 'last\s+month|past\s+month'; then
    query_parts+=("sys_created_on>=javascript:gs.daysAgo(30)")
  elif echo "$lower" | grep -qP 'today'; then
    query_parts+=("sys_created_on>=javascript:gs.daysAgo(0)")
  elif echo "$lower" | grep -qP 'yesterday'; then
    query_parts+=("sys_created_on>=javascript:gs.daysAgo(1)^sys_created_on<javascript:gs.daysAgo(0)")
  elif echo "$lower" | grep -qP 'this\s+year'; then
    query_parts+=("sys_created_on>=javascript:gs.beginningOfThisYear()")
  fi

  # ── Parse sort order ─────────────────────────────────────────────
  local orderby=""
  if echo "$lower" | grep -qP 'sort(ed)?\s+by\s+created|order\s+by\s+created|oldest\s+first'; then
    orderby="sys_created_on"
  elif echo "$lower" | grep -qP 'sort(ed)?\s+by\s+updated|order\s+by\s+updated|recently\s+updated'; then
    orderby="-sys_updated_on"
  elif echo "$lower" | grep -qP 'sort(ed)?\s+by\s+priority|order\s+by\s+priority|highest\s+priority'; then
    orderby="priority"
  elif echo "$lower" | grep -qP 'newest\s+first|most\s+recent|latest'; then
    orderby="-sys_created_on"
  elif echo "$lower" | grep -qP 'sort(ed)?\s+by\s+number|order\s+by\s+number'; then
    orderby="number"
  fi
  # Check for descending
  if echo "$lower" | grep -qP 'desc(ending)?'; then
    [[ -n "$orderby" && "$orderby" != -* ]] && orderby="-${orderby}"
  fi

  # ── Parse limit ──────────────────────────────────────────────────
  local limit="20"
  if [[ "$lower" =~ (top|first|limit|show)\s+([0-9]+) ]]; then
    limit="${BASH_REMATCH[2]}"
  elif echo "$lower" | grep -qP '\ball\b'; then
    limit="100"
  fi

  # ── Build the encoded query ──────────────────────────────────────
  local encoded_query=""
  if [[ ${#query_parts[@]} -gt 0 ]]; then
    encoded_query=$(IFS='^'; echo "${query_parts[*]}")
  fi

  # ── Default table if still unknown ────────────────────────────────
  if [[ -z "$resolved_table" ]]; then
    # Default to incident for common ITSM queries
    if echo "$lower" | grep -qP '(ticket|issue|outage|down|broke|fix|urgent|critical)'; then
      resolved_table="incident"
    else
      echo "⚠️  Could not determine target table from input."
      echo "Hint: Mention a table name like 'incidents', 'changes', 'users', 'servers', etc."
      echo ""
      echo "Available table aliases:"
      echo "  ITSM:    incidents, changes, problems, tasks, requests, ritms"
      echo "  Users:   users, groups, teams"
      echo "  CMDB:    servers, computers, databases, applications, services, cis"
      echo "  Other:   knowledge/articles, catalog items, alerts, slas, notifications"
      return 1
    fi
  fi

  # ── Build and output the command ──────────────────────────────────
  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  local cmd_str=""
  local is_write=false

  case "$intent" in
    SCHEMA)
      cmd_str="bash ${script_dir}/sn.sh schema ${resolved_table}"
      echo "Intent:  SCHEMA"
      echo "Table:   ${resolved_table}"
      echo "Command: ${cmd_str}"
      echo ""
      # Schema is read-only, always execute
      echo "Executing..."
      echo ""
      eval "$cmd_str"
      ;;

    AGGREGATE)
      local agg_type="COUNT"
      local agg_field=""
      # Detect specific agg types
      if echo "$lower" | grep -qP '\b(average|avg)\b'; then
        agg_type="AVG"
        agg_field=$(echo "$lower" | grep -oP '(?:average|avg)\s+(?:of\s+)?(\w+)' | awk '{print $NF}')
      elif echo "$lower" | grep -qP '\bsum\b'; then
        agg_type="SUM"
        agg_field=$(echo "$lower" | grep -oP '(?:sum)\s+(?:of\s+)?(\w+)' | awk '{print $NF}')
      elif echo "$lower" | grep -qP '\bmin(imum)?\b'; then
        agg_type="MIN"
        agg_field=$(echo "$lower" | grep -oP '(?:min(?:imum)?)\s+(?:of\s+)?(\w+)' | awk '{print $NF}')
      elif echo "$lower" | grep -qP '\bmax(imum)?\b'; then
        agg_type="MAX"
        agg_field=$(echo "$lower" | grep -oP '(?:max(?:imum)?)\s+(?:of\s+)?(\w+)' | awk '{print $NF}')
      fi

      # Detect group-by
      local group_by=""
      if [[ "$lower" =~ (group(ed)?|by)\s+(priority|state|category|assigned_to|assignment_group|urgency|impact) ]]; then
        group_by="${BASH_REMATCH[3]}"
      fi

      cmd_str="bash ${script_dir}/sn.sh aggregate ${resolved_table} --type ${agg_type}"
      [[ -n "$encoded_query" ]] && cmd_str+=" --query \"${encoded_query}\""
      [[ -n "$agg_field" ]]     && cmd_str+=" --field ${agg_field}"
      [[ -n "$group_by" ]]      && cmd_str+=" --group-by ${group_by}"

      echo "Intent:  AGGREGATE (${agg_type})"
      echo "Table:   ${resolved_table}"
      [[ -n "$encoded_query" ]] && echo "Query:   ${encoded_query}"
      [[ -n "$group_by" ]]      && echo "Group:   ${group_by}"
      echo "Command: ${cmd_str}"
      echo ""
      # Aggregates are read-only, always execute
      echo "Executing..."
      echo ""
      eval "$cmd_str"
      ;;

    QUERY)
      # Choose default fields based on table
      local default_fields=""
      case "$resolved_table" in
        incident)        default_fields="number,short_description,state,priority,assigned_to,assignment_group,opened_at" ;;
        change_request)  default_fields="number,short_description,state,priority,assigned_to,start_date,end_date" ;;
        problem)         default_fields="number,short_description,state,priority,assigned_to,opened_at" ;;
        sc_req_item)     default_fields="number,short_description,state,assigned_to,request,opened_at" ;;
        sc_request)      default_fields="number,short_description,state,requested_for,opened_at" ;;
        sys_user)        default_fields="user_name,name,email,department,active" ;;
        sys_user_group)  default_fields="name,description,manager,active" ;;
        cmdb_ci_server)  default_fields="name,ip_address,os,classification,operational_status" ;;
        cmdb_ci)         default_fields="name,sys_class_name,operational_status,owned_by" ;;
        kb_knowledge)    default_fields="number,short_description,workflow_state,author,published" ;;
        task)            default_fields="number,short_description,state,assigned_to,sys_class_name,opened_at" ;;
        *)               default_fields="" ;;
      esac

      cmd_str="bash ${script_dir}/sn.sh query ${resolved_table}"
      [[ -n "$encoded_query" ]] && cmd_str+=" --query \"${encoded_query}\""
      [[ -n "$default_fields" ]] && cmd_str+=" --fields ${default_fields}"
      cmd_str+=" --limit ${limit}"
      [[ -n "$orderby" ]] && cmd_str+=" --orderby ${orderby}"
      cmd_str+=" --display true"

      echo "Intent:  QUERY"
      echo "Table:   ${resolved_table}"
      [[ -n "$encoded_query" ]] && echo "Query:   ${encoded_query}"
      [[ -n "$orderby" ]]       && echo "Sort:    ${orderby}"
      echo "Limit:   ${limit}"
      echo "Command: ${cmd_str}"
      echo ""
      # Queries are read-only, always execute
      echo "Executing..."
      echo ""
      eval "$cmd_str"
      ;;

    CREATE)
      is_write=true
      # Parse fields from natural language for create
      local payload='{}'

      # Extract short description - text after "for" or main subject
      local short_desc=""
      if [[ "$lower" =~ (for|about|regarding)[[:space:]]+([^,]+) ]]; then
        short_desc="${BASH_REMATCH[2]}"
        short_desc=$(echo "$short_desc" | sed -E 's/\s*(,|assign|priority|p[1-5]|urgency|impact|category).*$//')
        short_desc=$(echo "$short_desc" | sed 's/[[:space:]]*$//')
      fi
      [[ -n "$short_desc" ]] && payload=$(echo "$payload" | jq --arg v "$short_desc" '. + {short_description: $v}')

      # Add priority from parsed query parts
      for part in "${query_parts[@]}"; do
        if [[ "$part" == priority=* ]]; then
          local pval="${part#priority=}"
          payload=$(echo "$payload" | jq --arg v "$pval" '. + {priority: $v}')
        fi
      done

      # Add urgency
      if echo "$lower" | grep -qP 'urgency\s+(1|2|3|high|medium|low)'; then
        local urg
        urg=$(echo "$lower" | grep -oP 'urgency\s+\K(1|2|3|high|medium|low)')
        case "$urg" in
          high) urg="1" ;; medium) urg="2" ;; low) urg="3" ;;
        esac
        payload=$(echo "$payload" | jq --arg v "$urg" '. + {urgency: $v}')
      fi

      # Add impact
      if echo "$lower" | grep -qP 'impact\s+(1|2|3|high|medium|low)'; then
        local imp
        imp=$(echo "$lower" | grep -oP 'impact\s+\K(1|2|3|high|medium|low)')
        case "$imp" in
          high) imp="1" ;; medium) imp="2" ;; low) imp="3" ;;
        esac
        payload=$(echo "$payload" | jq --arg v "$imp" '. + {impact: $v}')
      fi

      # Add assignment group if found
      [[ -n "$assignment_group" ]] && payload=$(echo "$payload" | jq --arg v "$assignment_group" '. + {assignment_group: $v}')

      local payload_str
      payload_str=$(echo "$payload" | jq -c .)

      cmd_str="bash ${script_dir}/sn.sh create ${resolved_table} '${payload_str}'"

      echo "Intent:  CREATE"
      echo "Table:   ${resolved_table}"
      echo "Payload: ${payload_str}"
      echo "Command: ${cmd_str}"
      echo ""

      if [[ "$execute" == "true" ]]; then
        echo "Executing..."
        echo ""
        bash "${script_dir}/sn.sh" create "${resolved_table}" "${payload_str}"
      else
        echo "⚠️  This is a WRITE operation. Add --execute to run it."
      fi
      ;;

    UPDATE)
      is_write=true
      local update_payload='{}'
      local target_id=""

      # Try to get sys_id or record number from input
      if [[ -n "$ref_number" ]]; then
        target_id="$ref_number"
      fi

      # Parse "set <field> to <value>" patterns
      if [[ "$lower" =~ set[[:space:]]+([a-z_]+)[[:space:]]+to[[:space:]]+([^,]+) ]]; then
        local uf="${BASH_REMATCH[1]}"
        local uv="${BASH_REMATCH[2]}"
        uv=$(echo "$uv" | sed 's/[[:space:]]*$//')
        update_payload=$(echo "$update_payload" | jq --arg k "$uf" --arg v "$uv" '. + {($k): $v}')
      fi

      # Parse state changes
      if echo "$lower" | grep -qP '\bclose\b|\bresolve\b'; then
        if echo "$lower" | grep -qP '\bresolve\b'; then
          update_payload=$(echo "$update_payload" | jq '. + {state: "6"}')
        else
          update_payload=$(echo "$update_payload" | jq '. + {state: "7"}')
        fi
      fi

      # Parse priority changes
      for part in "${query_parts[@]}"; do
        if [[ "$part" == priority=* ]]; then
          local pval="${part#priority=}"
          update_payload=$(echo "$update_payload" | jq --arg v "$pval" '. + {priority: $v}')
        fi
      done

      local update_str
      update_str=$(echo "$update_payload" | jq -c .)

      if [[ -n "$target_id" ]]; then
        cmd_str="bash ${script_dir}/sn.sh update ${resolved_table} <sys_id_of_${target_id}> '${update_str}'"
        echo "Intent:  UPDATE"
        echo "Table:   ${resolved_table}"
        echo "Target:  ${target_id} (resolve sys_id first with: bash ${script_dir}/sn.sh query ${resolved_table} --query \"number=${target_id}\" --fields sys_id)"
        echo "Payload: ${update_str}"
        echo "Command: ${cmd_str}"
      else
        cmd_str="bash ${script_dir}/sn.sh update ${resolved_table} <sys_id> '${update_str}'"
        echo "Intent:  UPDATE"
        echo "Table:   ${resolved_table}"
        echo "Payload: ${update_str}"
        echo "Command: ${cmd_str}"
        echo "Note:    Provide a record number or sys_id to target"
      fi
      echo ""

      if [[ "$execute" == "true" ]]; then
        echo "⚠️  Cannot auto-execute update without a resolved sys_id."
        echo "    Use sn.sh update <table> <sys_id> '<json>' directly."
      else
        echo "⚠️  This is a WRITE operation. Add --execute to run it."
      fi
      ;;

    BATCH)
      is_write=true
      local batch_action="update"
      echo "$lower" | grep -qP '\bdelete\b|\bremove\b' && batch_action="delete"

      local batch_fields=""
      if [[ "$batch_action" == "update" ]]; then
        # Look for close/resolve action
        if echo "$lower" | grep -qP '\bclose\b'; then
          batch_fields='{"state":"7","close_code":"Solved (Permanently)","close_notes":"Bulk closed via sn_nl"}'
        elif echo "$lower" | grep -qP '\bresolve\b'; then
          batch_fields='{"state":"6"}'
        fi
      fi

      cmd_str="bash ${script_dir}/sn.sh batch ${resolved_table} --action ${batch_action}"
      [[ -n "$encoded_query" ]] && cmd_str+=" --query \"${encoded_query}\""
      [[ -n "$batch_fields" ]]  && cmd_str+=" --fields '${batch_fields}'"
      cmd_str+=" --limit ${limit}"

      echo "Intent:  BATCH ${batch_action^^}"
      echo "Table:   ${resolved_table}"
      [[ -n "$encoded_query" ]] && echo "Query:   ${encoded_query}"
      [[ -n "$batch_fields" ]]  && echo "Fields:  ${batch_fields}"
      echo "Limit:   ${limit}"
      echo "Command: ${cmd_str}"
      echo ""

      if [[ "$execute" == "true" && "$confirm" == "true" ]]; then
        if [[ "$batch_action" == "delete" && "$force" != "true" ]]; then
          echo "⚠️  Bulk DELETE requires --confirm --force. This is a safety measure."
        else
          echo "Executing..."
          echo ""
          local exec_cmd="bash ${script_dir}/sn.sh batch ${resolved_table} --action ${batch_action}"
          [[ -n "$encoded_query" ]] && exec_cmd+=" --query \"${encoded_query}\""
          [[ -n "$batch_fields" ]]  && exec_cmd+=" --fields '${batch_fields}'"
          exec_cmd+=" --limit ${limit} --confirm"
          eval "$exec_cmd"
        fi
      else
        echo "⚠️  This is a BULK WRITE operation."
        echo "    Add --execute --confirm to run it."
        [[ "$batch_action" == "delete" ]] && echo "    Bulk deletes also require --force."
      fi
      ;;

    DELETE)
      is_write=true
      local del_target=""
      [[ -n "$ref_number" ]] && del_target="$ref_number"

      if [[ -n "$del_target" ]]; then
        cmd_str="bash ${script_dir}/sn.sh delete ${resolved_table} <sys_id_of_${del_target}> --confirm"
        echo "Intent:  DELETE"
        echo "Table:   ${resolved_table}"
        echo "Target:  ${del_target} (resolve sys_id first)"
        echo "Command: ${cmd_str}"
      else
        cmd_str="bash ${script_dir}/sn.sh delete ${resolved_table} <sys_id> --confirm"
        echo "Intent:  DELETE"
        echo "Table:   ${resolved_table}"
        echo "Command: ${cmd_str}"
        echo "Note:    Provide a record number or sys_id to target"
      fi
      echo ""
      echo "⚠️  This is a DELETE operation. Use sn.sh delete directly with --confirm."
      ;;
  esac
}

# ── relationships ───────────────────────────────────────────────────────
cmd_relationships() {
  local default_depth="${SN_REL_DEPTH:-3}"
  local ci_name="" opt_sys_id="" depth="$default_depth" rel_type="" ci_class="" direction="both"
  local impact=false json_output=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sys-id)    opt_sys_id="$2"; shift 2 ;;
      --depth)     depth="$2";      shift 2 ;;
      --type)      rel_type="$2";   shift 2 ;;
      --class)     ci_class="$2";   shift 2 ;;
      --direction) direction="$2";  shift 2 ;;
      --impact)    impact=true;     shift ;;
      --json)      json_output=true; shift ;;
      -*)          die "Unknown option: $1" ;;
      *)
        if [[ -z "$ci_name" ]]; then
          ci_name="$1"
        else
          die "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -z "$ci_name" && -z "$opt_sys_id" ]] && die "Usage: sn.sh relationships <ci_name> [--sys-id <id>] [--depth N] [--type <type>] [--class <class>] [--direction upstream|downstream|both] [--impact] [--json]"
  [[ "$depth" -lt 1 || "$depth" -gt 5 ]] && die "--depth must be between 1 and 5"

  if [[ "$impact" == "true" ]]; then
    direction="upstream"
    info "Impact analysis mode — walking upstream only"
  fi

  case "$direction" in
    upstream|downstream|both) ;;
    *) die "--direction must be upstream, downstream, or both" ;;
  esac

  # ── Step 1: Resolve root CI ──────────────────────────────────────
  local root_id root_name root_class

  if [[ -n "$opt_sys_id" ]]; then
    info "Resolving CI by sys_id: $opt_sys_id"
    local ci_resp
    ci_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/cmdb_ci/${opt_sys_id}?sysparm_fields=sys_id,name,sys_class_name&sysparm_display_value=true") \
      || die "Failed to resolve CI with sys_id: $opt_sys_id"
    root_id="$opt_sys_id"
    root_name=$(echo "$ci_resp" | jq -r '.result.name // empty')
    root_class=$(echo "$ci_resp" | jq -r '.result.sys_class_name // empty')
    [[ -z "$root_name" ]] && die "CI not found with sys_id: $opt_sys_id"
  else
    info "Resolving CI: $ci_name"
    local encoded_name
    encoded_name=$(jq -rn --arg v "$ci_name" '$v | @uri')
    local ci_resp
    ci_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/cmdb_ci?sysparm_query=name=${encoded_name}&sysparm_fields=sys_id,name,sys_class_name&sysparm_display_value=true&sysparm_limit=5") \
      || die "Failed to search for CI: $ci_name"

    local match_count
    match_count=$(echo "$ci_resp" | jq '.result | length')
    [[ "$match_count" -eq 0 ]] && die "CI not found: $ci_name"
    [[ "$match_count" -gt 1 ]] && info "Found $match_count CIs matching '$ci_name', using first match"

    root_id=$(echo "$ci_resp" | jq -r '.result[0].sys_id')
    root_name=$(echo "$ci_resp" | jq -r '.result[0].name')
    root_class=$(echo "$ci_resp" | jq -r '.result[0].sys_class_name')
  fi

  info "Root CI: $root_name ($root_class) [$root_id]"

  # ── Caches ───────────────────────────────────────────────────────
  declare -A _rel_visited        # cycle detection
  declare -A _rel_class_cache    # CI class cache
  _rel_visited["$root_id"]=1
  _rel_class_cache["$root_id"]="$root_class"

  # JSON accumulator
  local _rel_json_result='[]'

  # Display dedup for class-filtered results
  declare -A _rel_displayed

  # ── Helper: get CI class with caching ────────────────────────────
  _rel_get_class() {
    local cid="$1"
    if [[ -n "${_rel_class_cache[$cid]+x}" ]]; then
      echo "${_rel_class_cache[$cid]}"
      return
    fi
    local resp cls
    resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/cmdb_ci/${cid}?sysparm_fields=sys_class_name&sysparm_display_value=true" 2>/dev/null) || true
    cls=$(echo "$resp" | jq -r '.result.sys_class_name // "unknown"' 2>/dev/null)
    [[ -z "$cls" ]] && cls="unknown"
    _rel_class_cache["$cid"]="$cls"
    echo "$cls"
  }

  # ── Helper: extract value/display from a field (handles both formats) ─
  # With sysparm_display_value=all, reference fields return:
  #   {"display_value":"Name","value":"sys_id","link":"https://..."}
  # With sysparm_display_value=true, they may return just a string.
  _rel_field_value() {
    local field_json="$1" key="$2"
    local val
    val=$(echo "$field_json" | jq -r ".$key.value // empty" 2>/dev/null)
    if [[ -z "$val" ]]; then
      # Might be a plain string
      val=$(echo "$field_json" | jq -r ".$key // empty" 2>/dev/null)
      # If it looks like a sys_id (32 hex chars), use it
      if [[ ! "$val" =~ ^[a-f0-9]{32}$ ]]; then
        val=""
      fi
    fi
    echo "$val"
  }

  _rel_field_display() {
    local field_json="$1" key="$2"
    local disp
    disp=$(echo "$field_json" | jq -r ".$key.display_value // empty" 2>/dev/null)
    if [[ -z "$disp" ]]; then
      disp=$(echo "$field_json" | jq -r ".$key // empty" 2>/dev/null)
      # If it's a sys_id, it's not a display value
      if [[ "$disp" =~ ^[a-f0-9]{32}$ ]]; then
        disp=""
      fi
    fi
    echo "$disp"
  }

  _rel_field_id_from_link() {
    local field_json="$1" key="$2"
    local link
    link=$(echo "$field_json" | jq -r ".$key.link // empty" 2>/dev/null)
    if [[ -n "$link" ]]; then
      echo "${link##*/}"
    fi
  }

  # ── Recursive traversal ─────────────────────────────────────────
  _rel_traverse() {
    local current_id="$1" current_depth="$2" max_depth="$3" prefix="$4"

    [[ "$current_depth" -gt "$max_depth" ]] && return 0

    # Query relationships for this CI
    local query="parent=${current_id}^ORchild=${current_id}"
    local encoded_q
    encoded_q=$(jq -rn --arg v "$query" '$v | @uri')
    local url="${SN_INSTANCE}/api/now/table/cmdb_rel_ci?sysparm_query=${encoded_q}&sysparm_fields=parent,child,type&sysparm_display_value=all&sysparm_limit=100"

    local rel_resp
    rel_resp=$(sn_curl GET "$url" 2>/dev/null) || {
      info "Warning: Failed to query relationships for $current_id"
      return 0
    }

    local rel_count
    rel_count=$(echo "$rel_resp" | jq '.result | length')
    [[ "$rel_count" -eq 0 ]] && return 0

    # ── Parse and filter relationships ─────────────────────────────
    # Build a list of: other_id, other_name, rel_type_name, rel_direction
    local items='[]'
    local seen_pairs=""  # dedup "id:direction" combos at this level

    local i=0
    while (( i < rel_count )); do
      local rec
      rec=$(echo "$rel_resp" | jq -c ".result[$i]")

      # Extract parent info
      local p_id p_name p_link_id
      p_id=$(_rel_field_value "$rec" "parent")
      p_name=$(_rel_field_display "$rec" "parent")
      [[ -z "$p_id" ]] && p_id=$(_rel_field_id_from_link "$rec" "parent")

      # Extract child info
      local c_id c_name c_link_id
      c_id=$(_rel_field_value "$rec" "child")
      c_name=$(_rel_field_display "$rec" "child")
      [[ -z "$c_id" ]] && c_id=$(_rel_field_id_from_link "$rec" "child")

      # Extract relationship type
      local type_display
      type_display=$(_rel_field_display "$rec" "type")
      [[ -z "$type_display" ]] && type_display="Related to"

      # Determine direction and other CI
      local other_id other_name rel_dir
      if [[ "$p_id" == "$current_id" ]]; then
        other_id="$c_id"
        other_name="$c_name"
        rel_dir="downstream"
      elif [[ "$c_id" == "$current_id" ]]; then
        other_id="$p_id"
        other_name="$p_name"
        rel_dir="upstream"
      else
        # Neither matches (shouldn't happen)
        i=$((i + 1)); continue
      fi

      # Skip self-references
      [[ "$other_id" == "$current_id" ]] && { i=$((i + 1)); continue; }

      # Direction filter
      if [[ "$direction" != "both" && "$rel_dir" != "$direction" ]]; then
        i=$((i + 1)); continue
      fi

      # Type filter (substring match)
      if [[ -n "$rel_type" ]]; then
        if [[ "${type_display,,}" != *"${rel_type,,}"* ]]; then
          i=$((i + 1)); continue
        fi
      fi

      # Dedup at this level
      local pair_key="${other_id}:${rel_dir}"
      if [[ "$seen_pairs" == *"|${pair_key}|"* ]]; then
        i=$((i + 1)); continue
      fi
      seen_pairs+="|${pair_key}|"

      items=$(echo "$items" | jq \
        --arg oid "$other_id" \
        --arg oname "$other_name" \
        --arg tname "$type_display" \
        --arg dir "$rel_dir" \
        '. + [{"id": $oid, "name": $oname, "type": $tname, "direction": $dir}]')

      i=$((i + 1))
    done

    # ── Resolve classes for all items (needed for filtering + display) ─
    # Pre-fetch classes into cache to avoid redundant lookups
    local total
    total=$(echo "$items" | jq 'length')
    [[ "$total" -eq 0 ]] && return 0

    local k=0
    while [[ $k -lt $total ]]; do
      local prefetch_id
      prefetch_id=$(echo "$items" | jq -r ".[$k].id")
      _rel_get_class "$prefetch_id" >/dev/null
      k=$((k + 1))
    done

    # ── Output this level + recurse ────────────────────────────────
    k=0
    while [[ $k -lt $total ]]; do
      local item_id item_name item_type item_dir
      item_id=$(echo "$items" | jq -r ".[$k].id")
      item_name=$(echo "$items" | jq -r ".[$k].name")
      item_type=$(echo "$items" | jq -r ".[$k].type")
      item_dir=$(echo "$items" | jq -r ".[$k].direction")

      local item_class
      item_class="${_rel_class_cache[$item_id]:-unknown}"

      # Check class filter — skip display but still traverse
      local show_item=true
      if [[ -n "$ci_class" ]]; then
        if [[ "${item_class,,}" != *"${ci_class,,}"* ]]; then
          show_item=false
        elif [[ -n "${_rel_displayed[$item_id]+x}" ]]; then
          show_item=false  # already displayed via another branch
        fi
      fi

      # Tree connectors
      local connector child_prefix
      if [[ $k -eq $((total - 1)) ]]; then
        connector="└─"
        child_prefix="${prefix}   "
      else
        connector="├─"
        child_prefix="${prefix}│  "
      fi

      # Direction indicator
      local dir_arrow
      [[ "$item_dir" == "upstream" ]] && dir_arrow="▲" || dir_arrow="▼"

      if [[ "$show_item" == "true" ]]; then
        _rel_displayed["$item_id"]=1

        if [[ "$json_output" == "true" ]]; then
          _rel_json_result=$(echo "$_rel_json_result" | jq \
            --arg name "$item_name" --arg cls "$item_class" \
            --arg type "$item_type" --arg dir "$item_dir" \
            --arg id "$item_id" --argjson dep "$current_depth" \
            '. + [{"name": $name, "class": $cls, "type": $type, "direction": $dir, "sys_id": $id, "depth": $dep}]')
        else
          echo "${prefix}${connector} ${dir_arrow} ${item_name} [${item_class}] (${item_type})"
        fi
      fi

      # Recurse deeper if allowed and not visited
      if [[ "$current_depth" -lt "$max_depth" ]] && [[ -z "${_rel_visited[$item_id]+x}" ]]; then
        _rel_visited["$item_id"]=1
        _rel_traverse "$item_id" $(( current_depth + 1 )) "$max_depth" "$child_prefix"
      fi

      k=$((k + 1))
    done
  }

  # ── Print header and start traversal ─────────────────────────────
  if [[ "$json_output" != "true" ]]; then
    echo ""
    echo "● $root_name [$root_class]"
  fi

  _rel_traverse "$root_id" 1 "$depth" ""

  if [[ "$json_output" == "true" ]]; then
    local root_json
    root_json=$(jq -n \
      --arg name "$root_name" --arg cls "$root_class" --arg id "$root_id" \
      --argjson rels "$_rel_json_result" \
      '{root: {name: $name, class: $cls, sys_id: $id}, relationships: $rels}')
    echo "$root_json" | jq .
  else
    local rel_count_final
    rel_count_final=$(echo "$_rel_json_result" | jq 'length' 2>/dev/null || echo "0")
    echo ""
    info "Found relationships (depth=$depth, direction=$direction)"
  fi

  # Clean up functions
  unset -f _rel_get_class _rel_field_value _rel_field_display _rel_field_id_from_link _rel_traverse
}

# ── script ─────────────────────────────────────────────────────────────
# Executes a background script on ServiceNow via sys.scripts.do
# This uses a session-based approach (login → get CSRF token → POST script)
# because ServiceNow does NOT expose a REST API for background scripts.
cmd_script() {
  local script_code="" script_file="" timeout=30 scope="global" confirm=false
  local MAX_TIMEOUT=300
  local MAX_SIZE=51200  # 50KB in bytes

  # Destructive keywords that require --confirm
  local DESTRUCTIVE_PATTERNS='deleteRecord|deleteMultiple|\.delete\(\)|GlideRecord\.delete|setWorkflow\(false\)'

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)    script_file="$2"; shift 2 ;;
      --timeout) timeout="$2";     shift 2 ;;
      --scope)   scope="$2";       shift 2 ;;
      --confirm) confirm=true;     shift ;;
      -*)        die "Unknown option: $1" ;;
      *)
        if [[ -z "$script_code" ]]; then
          script_code="$1"
        else
          die "Unexpected argument: $1 (wrap script in quotes)"
        fi
        shift
        ;;
    esac
  done

  # ── Load script from file or inline ─────────────────────────────
  if [[ -n "$script_file" ]]; then
    [[ ! -f "$script_file" ]] && die "Script file not found: $script_file"
    script_code=$(cat "$script_file") || die "Failed to read script file: $script_file"
    info "Loaded script from: $script_file"
  fi

  [[ -z "$script_code" ]] && die "Usage: sn.sh script '<javascript code>' [--file <path>] [--timeout <seconds>] [--scope <app_scope>] [--confirm]"

  # ── Validate timeout ────────────────────────────────────────────
  if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    die "Timeout must be a positive integer (got: $timeout)"
  fi
  if (( timeout > MAX_TIMEOUT )); then
    info "WARNING: Capping timeout from ${timeout}s to ${MAX_TIMEOUT}s"
    timeout=$MAX_TIMEOUT
  fi
  if (( timeout < 1 )); then
    timeout=1
  fi

  # ── Validate script size ────────────────────────────────────────
  local script_size
  script_size=$(printf '%s' "$script_code" | wc -c)
  if (( script_size > MAX_SIZE )); then
    die "Script exceeds maximum size: ${script_size} bytes > ${MAX_SIZE} bytes (50KB limit)"
  fi

  # ── Compute script hash for audit trail ─────────────────────────
  local script_hash
  script_hash=$(printf '%s' "$script_code" | sha256sum | cut -c1-8)

  # ── Safety: check for destructive keywords ──────────────────────
  if echo "$script_code" | grep -qE "$DESTRUCTIVE_PATTERNS"; then
    if [[ "$confirm" != "true" ]]; then
      echo "🛑 DESTRUCTIVE SCRIPT DETECTED" >&2
      echo "" >&2
      echo "This script contains potentially destructive operations:" >&2
      echo "$script_code" | grep -nE "$DESTRUCTIVE_PATTERNS" | head -5 | while IFS= read -r line; do
        echo "  $line" >&2
      done
      echo "" >&2
      die "Destructive scripts require --confirm flag. This is a safety measure."
    fi
    info "WARNING: Destructive script confirmed by user"
  fi

  # ── Safety warning ──────────────────────────────────────────────
  echo "⚠️  WARNING: Executing server-side background script on ${SN_INSTANCE}" >&2
  echo "   Scope: ${scope} | Timeout: ${timeout}s | Size: ${script_size} bytes | Hash: ${script_hash}" >&2
  echo "" >&2

  info "Executing background script via Playwright (hash=${script_hash}, scope=${scope})"

  # ── Resolve the Playwright runner script path ───────────────────
  local SKILL_DIR RUNNER_SCRIPT SCRIPT_TMPFILE
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  RUNNER_SCRIPT="${SKILL_DIR}/scripts/sn_script_runner.js"

  if [[ ! -f "$RUNNER_SCRIPT" ]]; then
    die "Playwright runner not found: $RUNNER_SCRIPT"
  fi

  # Write script code to a temp file (avoids env var size/escaping issues)
  SCRIPT_TMPFILE=$(mktemp /tmp/sn_script.XXXXXX.js)
  trap "rm -f '${SCRIPT_TMPFILE}'" EXIT
  printf '%s' "$script_code" > "$SCRIPT_TMPFILE"

  # Convert timeout from seconds to milliseconds for the Playwright runner
  local timeout_ms=$(( timeout * 1000 ))

  # ── Run the Playwright script runner ────────────────────────────
  # stdout from node → captured in $output
  # stderr from node → flows through to our stderr
  local output="" runner_exit=0
  output=$(SN_INSTANCE="${SN_INSTANCE}" \
    SN_USER="${SN_USER}" \
    SN_PASSWORD="${SN_PASSWORD}" \
    SN_SCRIPT_FILE="${SCRIPT_TMPFILE}" \
    SN_TIMEOUT="${timeout_ms}" \
    SN_SCOPE="${scope}" \
    node "$RUNNER_SCRIPT") || runner_exit=$?

  # Clean up temp file
  rm -f "$SCRIPT_TMPFILE"
  trap - EXIT

  if [[ $runner_exit -ne 0 ]]; then
    die "Playwright script runner failed (exit $runner_exit)"
  fi

  # Build structured output
  local result
  result=$(jq -n \
    --arg status "success" \
    --arg hash "$script_hash" \
    --arg scope "$scope" \
    --arg instance "$SN_INSTANCE" \
    --arg output "$output" \
    --argjson size "$script_size" \
    '{
      status: $status,
      script_hash: $hash,
      script_size_bytes: $size,
      scope: $scope,
      instance: $instance,
      output: $output
    }')

  echo "$result" | jq .
  info "Script executed successfully (hash=${script_hash})"
}

# ── syslog ─────────────────────────────────────────────────────────────
cmd_syslog() {
  local level="" source="" message="" query="" limit="25" since="60"
  local fields="sys_id,level,source,message,sys_created_on"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --level)   level="$2";   shift 2 ;;
      --source)  source="$2";  shift 2 ;;
      --message) message="$2"; shift 2 ;;
      --query)   query="$2";   shift 2 ;;
      --limit)   limit="$2";   shift 2 ;;
      --since)   since="$2";   shift 2 ;;
      --fields)  fields="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  # Build query from individual filters (unless raw --query overrides)
  local sysparm_query=""
  if [[ -n "$query" ]]; then
    sysparm_query="$query"
  else
    local parts=()
    [[ -n "$level" ]]   && parts+=("level=${level}")
    [[ -n "$source" ]]  && parts+=("sourceLIKE${source}")
    [[ -n "$message" ]] && parts+=("messageLIKE${message}")
    parts+=("sys_created_on>=javascript:gs.minutesAgoStart(${since})")
    sysparm_query=$(IFS='^'; echo "${parts[*]}")
  fi

  # Always order by newest first
  sysparm_query+="^ORDERBYDESCsys_created_on"

  local encoded_q
  encoded_q=$(jq -rn --arg v "$sysparm_query" '$v | @uri')
  local url="${SN_INSTANCE}/api/now/table/syslog?sysparm_query=${encoded_q}&sysparm_fields=${fields}&sysparm_limit=${limit}"

  info "GET syslog (limit=$limit, since=${since}m)"
  local resp
  resp=$(sn_curl GET "$url") || die "API request failed"

  local count
  count=$(echo "$resp" | jq '.result | length')

  # Format output: show timestamp, level, source, message
  echo "$resp" | jq '[.result[] | {
    sys_id,
    timestamp: .sys_created_on,
    level,
    source,
    message: (if (.message | length) > 300 then (.message[:300] + "...") else .message end)
  }]'
  info "Returned $count log entries"
}

# ── codesearch ─────────────────────────────────────────────────────────
cmd_codesearch() {
  local search_term="" table="" field="" limit="20"

  # First positional arg is the search term
  if [[ $# -gt 0 && "$1" != --* ]]; then
    search_term="$1"; shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --table) table="$2"; shift 2 ;;
      --field) field="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -z "$search_term" ]] && die "Usage: sn.sh codesearch <search_term> [--table <table>] [--field <field>] [--limit N]"

  # Define default search targets: table:field pairs
  local -a search_tables=()
  local -a search_fields=()
  local -a search_labels=()

  if [[ -n "$table" ]]; then
    search_tables+=("$table")
    search_fields+=("${field:-script}")
    search_labels+=("$table")
  else
    search_tables+=("sys_script" "sys_script_include" "sys_ui_script" "sys_script_client" "sys_ws_operation")
    search_fields+=("script"     "script"              "script"        "script"            "operation_script")
    search_labels+=("Business Rules" "Script Includes" "UI Scripts" "Client Scripts" "Scripted REST")
  fi

  local all_results='[]'
  local total_found=0
  local per_table_limit=$(( limit ))

  # If searching multiple tables, distribute limit
  local num_tables=${#search_tables[@]}
  if [[ $num_tables -gt 1 ]]; then
    per_table_limit=$(( (limit + num_tables - 1) / num_tables ))
    [[ $per_table_limit -lt 5 ]] && per_table_limit=5
  fi

  for i in "${!search_tables[@]}"; do
    local t="${search_tables[$i]}"
    local f="${search_fields[$i]}"
    local l="${search_labels[$i]}"

    local q="${f}LIKE${search_term}"
    local encoded_q
    encoded_q=$(jq -rn --arg v "$q" '$v | @uri')
    local url="${SN_INSTANCE}/api/now/table/${t}?sysparm_query=${encoded_q}&sysparm_fields=sys_id,name,${f}&sysparm_limit=${per_table_limit}"

    info "Searching $l ($t) for '${search_term}'..."
    local resp
    resp=$(sn_curl GET "$url" 2>/dev/null) || { info "Warning: Failed to query $t"; continue; }

    local count
    count=$(echo "$resp" | jq '.result | length')
    total_found=$(( total_found + count ))

    if [[ "$count" -gt 0 ]]; then
      # Add table context and code snippet to each result
      local table_results
      table_results=$(echo "$resp" | jq --arg tbl "$t" --arg lbl "$l" --arg fld "$f" \
        '[.result[] | {
          table: $tbl,
          table_label: $lbl,
          sys_id,
          name: (.name // "unnamed"),
          snippet: (if (.[$fld] | length) > 200 then (.[$fld][:200] + "...") else (.[$fld] // "") end)
        }]')
      all_results=$(echo "$all_results $table_results" | jq -s '.[0] + .[1]')
    fi
  done

  # Trim to requested limit
  all_results=$(echo "$all_results" | jq --argjson lim "$limit" '.[:$lim]')
  local final_count
  final_count=$(echo "$all_results" | jq 'length')

  echo "$all_results" | jq '.'
  info "Found $total_found match(es) across ${num_tables} table(s), showing $final_count"
}

# ── discover ───────────────────────────────────────────────────────────
cmd_discover() {
  local subcmd="${1:?Usage: sn.sh discover <tables|apps|plugins> [options]}"
  shift

  case "$subcmd" in
    tables)
      local query="" limit="20"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --query) query="$2"; shift 2 ;;
          --limit) limit="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done

      local fields="sys_id,name,label,super_class,sys_scope,is_extendable"
      local sysparm_query=""
      if [[ -n "$query" ]]; then
        sysparm_query="nameLIKE${query}^ORlabelLIKE${query}"
      fi

      local url="${SN_INSTANCE}/api/now/table/sys_db_object?sysparm_fields=${fields}&sysparm_limit=${limit}&sysparm_display_value=true"
      [[ -n "$sysparm_query" ]] && url+="&sysparm_query=$(jq -rn --arg v "$sysparm_query" '$v | @uri')"

      info "Discovering tables (limit=$limit)"
      local resp
      resp=$(sn_curl GET "$url") || die "API request failed"

      local count
      count=$(echo "$resp" | jq '.result | length')
      echo "$resp" | jq '[.result[] | {
        sys_id,
        name,
        label,
        super_class,
        scope: .sys_scope,
        is_extendable
      }]'
      info "Found $count table(s)"
      ;;

    apps)
      local query="" limit="20" active="true"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --query)  query="$2";  shift 2 ;;
          --limit)  limit="$2";  shift 2 ;;
          --active) active="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done

      local all_apps='[]'

      # Search scoped apps (sys_app)
      local app_fields="sys_id,name,version,scope,active"
      local app_query=""
      [[ -n "$query" ]]              && app_query="nameLIKE${query}"
      [[ "$active" == "true" ]]      && { [[ -n "$app_query" ]] && app_query+="^"; app_query+="active=true"; }

      local app_url="${SN_INSTANCE}/api/now/table/sys_app?sysparm_fields=${app_fields}&sysparm_limit=${limit}"
      [[ -n "$app_query" ]] && app_url+="&sysparm_query=$(jq -rn --arg v "$app_query" '$v | @uri')"

      info "Discovering scoped apps..."
      local app_resp
      if app_resp=$(sn_curl GET "$app_url" 2>/dev/null); then
        local scoped
        scoped=$(echo "$app_resp" | jq '[.result[] | . + {source: "scoped"}]')
        all_apps=$(echo "$all_apps $scoped" | jq -s '.[0] + .[1]')
      else
        info "Warning: Could not query sys_app (may require elevated role)"
      fi

      # Search store apps (sys_store_app)
      local store_query=""
      [[ -n "$query" ]]              && store_query="nameLIKE${query}"
      [[ "$active" == "true" ]]      && { [[ -n "$store_query" ]] && store_query+="^"; store_query+="active=true"; }

      local store_url="${SN_INSTANCE}/api/now/table/sys_store_app?sysparm_fields=${app_fields}&sysparm_limit=${limit}"
      [[ -n "$store_query" ]] && store_url+="&sysparm_query=$(jq -rn --arg v "$store_query" '$v | @uri')"

      info "Discovering store apps..."
      local store_resp
      if store_resp=$(sn_curl GET "$store_url" 2>/dev/null); then
        local store_apps
        store_apps=$(echo "$store_resp" | jq '[.result[] | . + {source: "store"}]')
        all_apps=$(echo "$all_apps $store_apps" | jq -s '.[0] + .[1]')
      else
        info "Warning: Could not query sys_store_app"
      fi

      local total
      total=$(echo "$all_apps" | jq 'length')
      # Trim to limit
      all_apps=$(echo "$all_apps" | jq --argjson lim "$limit" '.[:$lim]')
      echo "$all_apps" | jq '.'
      info "Found $total app(s)"
      ;;

    plugins)
      local query="" limit="20" active=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --query)  query="$2";  shift 2 ;;
          --limit)  limit="$2";  shift 2 ;;
          --active) active="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done

      local plugin_query=""
      [[ -n "$query" ]]   && plugin_query="nameLIKE${query}"
      [[ -n "$active" ]]  && { [[ -n "$plugin_query" ]] && plugin_query+="^"; plugin_query+="active=${active}"; }

      local plugin_fields="sys_id,name,active"
      local plugin_url="${SN_INSTANCE}/api/now/table/v_plugin?sysparm_fields=${plugin_fields}&sysparm_limit=${limit}"
      [[ -n "$plugin_query" ]] && plugin_url+="&sysparm_query=$(jq -rn --arg v "$plugin_query" '$v | @uri')"

      info "Discovering plugins (limit=$limit)"
      local resp
      resp=$(sn_curl GET "$plugin_url") || die "API request failed"

      local count
      count=$(echo "$resp" | jq '.result | length')
      echo "$resp" | jq '[.result[] | {sys_id, name, active}]'
      info "Found $count plugin(s)"
      ;;

    *) die "Unknown discover subcommand: $subcmd (use tables, apps, plugins)" ;;
  esac
}

# ── atf (Automated Test Framework) ──────────────────────────────────────
cmd_atf() {
  local subcmd="${1:?Usage: sn.sh atf <list|suites|run|run-suite|results> ...}"
  shift

  case "$subcmd" in
    # ── atf list — List ATF tests ────────────────────────────────────
    list)
      local query="" fields="sys_id,name,description,active,sys_updated_on" limit="20" suite=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --suite)  suite="$2";  shift 2 ;;
          --query)  query="$2";  shift 2 ;;
          --limit)  limit="$2";  shift 2 ;;
          --fields) fields="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done

      # If --suite given, resolve the suite sys_id by name and filter tests
      if [[ -n "$suite" ]]; then
        info "Resolving suite: $suite"
        local suite_encoded
        suite_encoded=$(jq -rn --arg v "name=$suite" '$v | @uri')
        local suite_resp
        suite_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/sys_atf_test_suite?sysparm_query=${suite_encoded}&sysparm_fields=sys_id,name&sysparm_limit=1") \
          || die "Failed to resolve suite: $suite"
        local suite_id
        suite_id=$(echo "$suite_resp" | jq -r '.result[0].sys_id // empty')
        [[ -z "$suite_id" ]] && die "Suite not found: $suite"
        info "Suite resolved: $suite_id"

        # Query sys_atf_test_suite_test (M2M table) for test sys_ids in suite
        local m2m_resp
        m2m_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/sys_atf_test_suite_test?sysparm_query=test_suite=${suite_id}&sysparm_fields=test&sysparm_limit=500") \
          || die "Failed to query suite tests"
        local test_ids
        test_ids=$(echo "$m2m_resp" | jq -r '[.result[].test] | join(",")' 2>/dev/null)
        if [[ -z "$test_ids" || "$test_ids" == "null" ]]; then
          echo '{"record_count":0,"results":[]}'
          info "No tests found in suite: $suite"
          return 0
        fi
        # Build IN clause for test sys_ids
        local suite_filter="sys_idIN${test_ids}"
        if [[ -n "$query" ]]; then
          query="${suite_filter}^${query}"
        else
          query="$suite_filter"
        fi
      fi

      local url="${SN_INSTANCE}/api/now/table/sys_atf_test?sysparm_limit=${limit}&sysparm_fields=${fields}"
      [[ -n "$query" ]] && url+="&sysparm_query=$(jq -rn --arg v "$query" '$v | @uri')"

      info "GET sys_atf_test (limit=$limit)"
      local resp
      resp=$(sn_curl GET "$url") || die "API request failed"
      local count
      count=$(echo "$resp" | jq '.result | length')
      echo "$resp" | jq '{record_count: (.result | length), results: .result}'
      info "Returned $count test(s)"
      ;;

    # ── atf suites — List ATF test suites ────────────────────────────
    suites)
      local query="" fields="sys_id,name,description,active" limit="20"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --query)  query="$2";  shift 2 ;;
          --limit)  limit="$2";  shift 2 ;;
          --fields) fields="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done

      local url="${SN_INSTANCE}/api/now/table/sys_atf_test_suite?sysparm_limit=${limit}&sysparm_fields=${fields}"
      [[ -n "$query" ]] && url+="&sysparm_query=$(jq -rn --arg v "$query" '$v | @uri')"

      info "GET sys_atf_test_suite (limit=$limit)"
      local resp
      resp=$(sn_curl GET "$url") || die "API request failed"
      local count
      count=$(echo "$resp" | jq '.result | length')
      echo "$resp" | jq '{record_count: (.result | length), results: .result}'
      info "Returned $count suite(s)"
      ;;

    # ── atf run — Run a single ATF test ──────────────────────────────
    run)
      local test_id="${1:?Usage: sn.sh atf run <test_sys_id> [--wait] [--timeout <seconds>]}"
      shift
      local wait=true timeout=120
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --wait)    wait=true;     shift ;;
          --no-wait) wait=false;    shift ;;
          --timeout) timeout="$2";  shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done

      info "Running ATF test: $test_id"

      # Try the ATF REST API: POST /api/sn_atf/rest/test
      local run_url="${SN_INSTANCE}/api/sn_atf/rest/test"
      local run_resp http_code

      http_code=$(curl -s -o /tmp/sn_atf_run_resp.json -w "%{http_code}" \
        -X POST "$run_url" \
        -u "$AUTH" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{\"test_id\":\"${test_id}\"}")

      if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        run_resp=$(cat /tmp/sn_atf_run_resp.json)
        info "Test execution triggered via sn_atf REST API"
      else
        # Fallback: try /api/now/atf/test/{sys_id}/run
        info "sn_atf API returned HTTP $http_code, trying alternative endpoint..."
        http_code=$(curl -s -o /tmp/sn_atf_run_resp.json -w "%{http_code}" \
          -X POST "${SN_INSTANCE}/api/now/atf/test/${test_id}/run" \
          -u "$AUTH" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json")

        if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
          run_resp=$(cat /tmp/sn_atf_run_resp.json)
          info "Test execution triggered via /api/now/atf"
        else
          # Fallback: schedule run by inserting into sys_atf_test_result
          info "REST APIs not available (HTTP $http_code). Scheduling test run via Table API..."
          local schedule_payload
          schedule_payload=$(jq -n --arg tid "$test_id" '{test: $tid, status: "scheduled"}')
          run_resp=$(sn_curl POST "${SN_INSTANCE}/api/now/table/sys_atf_test_result" -d "$schedule_payload" 2>/dev/null) || true

          if [[ -z "$run_resp" ]]; then
            cat /tmp/sn_atf_run_resp.json 2>/dev/null
            die "All ATF execution methods failed. Ensure the ATF plugin is active and your user has atf_admin role."
          fi
          info "Test run scheduled via Table API"
        fi
      fi
      rm -f /tmp/sn_atf_run_resp.json

      # Extract result tracker (sys_id or tracker_id from response)
      local result_id tracker_id
      result_id=$(echo "$run_resp" | jq -r '.result.sys_id // .result.result_id // empty' 2>/dev/null)
      tracker_id=$(echo "$run_resp" | jq -r '.result.tracker_id // .result.progress_id // empty' 2>/dev/null)

      if [[ "$wait" != "true" ]]; then
        echo "$run_resp" | jq '.'
        [[ -n "$result_id" ]] && info "Result ID: $result_id"
        [[ -n "$tracker_id" ]] && info "Tracker ID: $tracker_id"
        info "Test triggered (not waiting for completion)"
        return 0
      fi

      # Poll for completion
      info "Waiting for test completion (timeout: ${timeout}s)..."
      local elapsed=0 poll_interval=5
      local status=""

      while (( elapsed < timeout )); do
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))

        # Try to poll result by result_id
        if [[ -n "$result_id" ]]; then
          local poll_resp
          poll_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/sys_atf_test_result/${result_id}?sysparm_fields=sys_id,test,status,output,duration,start_time,end_time&sysparm_display_value=true" 2>/dev/null) || true
          status=$(echo "$poll_resp" | jq -r '.result.status // empty' 2>/dev/null)
        elif [[ -n "$tracker_id" ]]; then
          # Poll via tracker
          local tracker_resp
          tracker_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/sys_execution_tracker/${tracker_id}?sysparm_fields=state,result,message&sysparm_display_value=true" 2>/dev/null) || true
          local tracker_state
          tracker_state=$(echo "$tracker_resp" | jq -r '.result.state // empty' 2>/dev/null)
          if [[ "$tracker_state" == "Successful" || "$tracker_state" == "Failed" || "$tracker_state" == "Cancelled" ]]; then
            status="complete"
          fi
        else
          # Poll by test sys_id — find the most recent result
          local poll_resp
          poll_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/sys_atf_test_result?sysparm_query=test=${test_id}^ORDERBYDESCsys_created_on&sysparm_fields=sys_id,test,status,output,duration,start_time,end_time&sysparm_display_value=true&sysparm_limit=1" 2>/dev/null) || true
          status=$(echo "$poll_resp" | jq -r '.result[0].status // empty' 2>/dev/null)
          result_id=$(echo "$poll_resp" | jq -r '.result[0].sys_id // empty' 2>/dev/null)
        fi

        # Check completion statuses
        local status_lower
        status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
        if [[ "$status_lower" == "success" || "$status_lower" == "pass" || "$status_lower" == "passed" \
            || "$status_lower" == "failure" || "$status_lower" == "fail" || "$status_lower" == "failed" \
            || "$status_lower" == "error" || "$status_lower" == "complete" || "$status_lower" == "skipped" \
            || "$status_lower" == "cancelled" ]]; then
          info "Test completed: $status (${elapsed}s)"
          break
        fi

        printf "." >&2
      done
      echo "" >&2

      if (( elapsed >= timeout )); then
        info "⚠️  Timeout reached (${timeout}s) — test may still be running"
      fi

      # Fetch final result
      if [[ -n "$result_id" ]]; then
        local final_resp
        final_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/sys_atf_test_result/${result_id}?sysparm_fields=sys_id,test,status,output,duration,start_time,end_time&sysparm_display_value=true" 2>/dev/null) || true
        echo "$final_resp" | jq '.result'
      else
        echo "$run_resp" | jq '.'
      fi
      ;;

    # ── atf run-suite — Run an ATF test suite ────────────────────────
    run-suite)
      local suite_id="${1:?Usage: sn.sh atf run-suite <suite_sys_id> [--wait] [--timeout <seconds>]}"
      shift
      local wait=true timeout=300
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --wait)    wait=true;     shift ;;
          --no-wait) wait=false;    shift ;;
          --timeout) timeout="$2";  shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done

      info "Running ATF test suite: $suite_id"

      # Try the ATF REST API: POST /api/sn_atf/rest/suite
      local run_url="${SN_INSTANCE}/api/sn_atf/rest/suite"
      local run_resp http_code

      http_code=$(curl -s -o /tmp/sn_atf_suite_resp.json -w "%{http_code}" \
        -X POST "$run_url" \
        -u "$AUTH" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{\"suite_id\":\"${suite_id}\"}")

      if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        run_resp=$(cat /tmp/sn_atf_suite_resp.json)
        info "Suite execution triggered via sn_atf REST API"
      else
        # Fallback: try /api/now/atf/suite/{sys_id}/run
        info "sn_atf API returned HTTP $http_code, trying alternative endpoint..."
        http_code=$(curl -s -o /tmp/sn_atf_suite_resp.json -w "%{http_code}" \
          -X POST "${SN_INSTANCE}/api/now/atf/suite/${suite_id}/run" \
          -u "$AUTH" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json")

        if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
          run_resp=$(cat /tmp/sn_atf_suite_resp.json)
          info "Suite execution triggered via /api/now/atf"
        else
          cat /tmp/sn_atf_suite_resp.json 2>/dev/null
          die "Suite execution failed (HTTP $http_code). Ensure the ATF plugin is active and your user has atf_admin role."
        fi
      fi
      rm -f /tmp/sn_atf_suite_resp.json

      # Extract tracking info
      local result_id tracker_id
      result_id=$(echo "$run_resp" | jq -r '.result.sys_id // .result.result_id // empty' 2>/dev/null)
      tracker_id=$(echo "$run_resp" | jq -r '.result.tracker_id // .result.progress_id // empty' 2>/dev/null)

      if [[ "$wait" != "true" ]]; then
        echo "$run_resp" | jq '.'
        [[ -n "$result_id" ]] && info "Result ID: $result_id"
        [[ -n "$tracker_id" ]] && info "Tracker ID: $tracker_id"
        info "Suite triggered (not waiting for completion)"
        return 0
      fi

      # Poll for completion
      info "Waiting for suite completion (timeout: ${timeout}s)..."
      local elapsed=0 poll_interval=5
      local completed=false

      while (( elapsed < timeout )); do
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))

        if [[ -n "$tracker_id" ]]; then
          local tracker_resp
          tracker_resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/sys_execution_tracker/${tracker_id}?sysparm_fields=state,result,message,completion_percent&sysparm_display_value=true" 2>/dev/null) || true
          local tracker_state
          tracker_state=$(echo "$tracker_resp" | jq -r '.result.state // empty' 2>/dev/null)
          local pct
          pct=$(echo "$tracker_resp" | jq -r '.result.completion_percent // empty' 2>/dev/null)
          [[ -n "$pct" ]] && printf "\r  Progress: %s%%" "$pct" >&2
          if [[ "$tracker_state" == "Successful" || "$tracker_state" == "Failed" || "$tracker_state" == "Cancelled" ]]; then
            completed=true
            echo "" >&2
            info "Suite completed: $tracker_state (${elapsed}s)"
            break
          fi
        else
          printf "." >&2
        fi
      done
      [[ "$completed" != "true" ]] && echo "" >&2

      if (( elapsed >= timeout )); then
        info "⚠️  Timeout reached (${timeout}s) — suite may still be running"
      fi

      # Fetch suite results — query test results linked to this suite execution
      local results_query="test_suite=${suite_id}^ORDERBYDESCsys_created_on"
      local results_url="${SN_INSTANCE}/api/now/table/sys_atf_test_result?sysparm_query=$(jq -rn --arg v "$results_query" '$v | @uri')&sysparm_fields=sys_id,test,status,output,duration,start_time,end_time&sysparm_display_value=true&sysparm_limit=200"

      local results_resp
      results_resp=$(sn_curl GET "$results_url" 2>/dev/null) || true

      local total_tests passed failed skipped
      total_tests=$(echo "$results_resp" | jq '.result | length' 2>/dev/null || echo "0")
      passed=$(echo "$results_resp" | jq '[.result[] | select(.status == "Success" or .status == "Pass" or .status == "Passed")] | length' 2>/dev/null || echo "0")
      failed=$(echo "$results_resp" | jq '[.result[] | select(.status == "Failure" or .status == "Fail" or .status == "Failed" or .status == "Error")] | length' 2>/dev/null || echo "0")
      skipped=$(echo "$results_resp" | jq '[.result[] | select(.status == "Skipped" or .status == "Cancelled")] | length' 2>/dev/null || echo "0")

      # Build summary output
      local summary
      summary=$(jq -n \
        --arg sid "$suite_id" \
        --argjson total "$total_tests" \
        --argjson pass "$passed" \
        --argjson fail "$failed" \
        --argjson skip "$skipped" \
        '{suite_sys_id: $sid, summary: {total: $total, passed: $pass, failed: $fail, skipped: $skip}}')

      # Append individual results
      if [[ "$total_tests" -gt 0 ]]; then
        summary=$(echo "$summary" | jq --argjson r "$(echo "$results_resp" | jq '.result')" '. + {results: $r}')
      fi

      echo "$summary" | jq '.'
      info "Suite results: $passed passed, $failed failed, $skipped skipped (of $total_tests)"
      ;;

    # ── atf results — Get test/suite execution results ───────────────
    results)
      local execution_id="${1:?Usage: sn.sh atf results <execution_id> [--fields <fields>] [--limit <N>]}"
      shift
      local fields="sys_id,test,status,output,duration,start_time,end_time" limit="50"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --fields) fields="$2"; shift 2 ;;
          --limit)  limit="$2";  shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done

      info "Fetching ATF results for: $execution_id"

      # First try: direct get by sys_id (single test result)
      local resp
      resp=$(sn_curl GET "${SN_INSTANCE}/api/now/table/sys_atf_test_result/${execution_id}?sysparm_fields=${fields}&sysparm_display_value=true" 2>/dev/null) || true
      local got_single
      got_single=$(echo "$resp" | jq -r '.result.sys_id // empty' 2>/dev/null)

      if [[ -n "$got_single" ]]; then
        echo "$resp" | jq '.result'
        info "Returned 1 result record"
        return 0
      fi

      # Second try: query by execution_id or parent field
      local query="execution=${execution_id}^ORparent=${execution_id}^ORtest_suite=${execution_id}"
      local query_url="${SN_INSTANCE}/api/now/table/sys_atf_test_result?sysparm_query=$(jq -rn --arg v "$query" '$v | @uri')&sysparm_fields=${fields}&sysparm_display_value=true&sysparm_limit=${limit}"

      resp=$(sn_curl GET "$query_url") || die "Failed to query results"
      local count
      count=$(echo "$resp" | jq '.result | length')
      echo "$resp" | jq '{record_count: (.result | length), results: .result}'
      info "Returned $count result(s)"
      ;;

    *) die "Unknown atf subcommand: $subcmd (use list, suites, run, run-suite, results)" ;;
  esac
}

# ── Main dispatcher ────────────────────────────────────────────────────
cmd="${1:?Usage: sn.sh <query|get|create|update|delete|aggregate|schema|attach|batch|health|nl|script|relationships|syslog|codesearch|discover|atf> ...}"
shift

case "$cmd" in
  query)         cmd_query "$@" ;;
  get)           cmd_get "$@" ;;
  create)        cmd_create "$@" ;;
  update)        cmd_update "$@" ;;
  delete)        cmd_delete "$@" ;;
  aggregate)     cmd_aggregate "$@" ;;
  schema)        cmd_schema "$@" ;;
  attach)        cmd_attach "$@" ;;
  batch)         cmd_batch "$@" ;;
  health)        cmd_health "$@" ;;
  nl)            cmd_nl "$@" ;;
  script)        cmd_script "$@" ;;
  relationships) cmd_relationships "$@" ;;
  syslog)        cmd_syslog "$@" ;;
  codesearch)    cmd_codesearch "$@" ;;
  discover)      cmd_discover "$@" ;;
  atf)           cmd_atf "$@" ;;
  *)             die "Unknown command: $cmd" ;;
esac
