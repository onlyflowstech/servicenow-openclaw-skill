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
# Commands: query, get, create, update, delete, aggregate, schema, attach
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

# ── Main dispatcher ────────────────────────────────────────────────────
cmd="${1:?Usage: sn.sh <query|get|create|update|delete|aggregate|schema|attach> ...}"
shift

case "$cmd" in
  query)     cmd_query "$@" ;;
  get)       cmd_get "$@" ;;
  create)    cmd_create "$@" ;;
  update)    cmd_update "$@" ;;
  delete)    cmd_delete "$@" ;;
  aggregate) cmd_aggregate "$@" ;;
  schema)    cmd_schema "$@" ;;
  attach)    cmd_attach "$@" ;;
  *)         die "Unknown command: $cmd" ;;
esac
