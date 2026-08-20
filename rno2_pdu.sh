#!/usr/bin/env bash
#
# rno2_pdu.sh — read-only RNO2A PDU-refresh manifest & progress tracker.
#
# Pulls the live BareMetalNode picture for RNO2 straight from VictoriaMetrics
# (no cluster login needed) and renders it as the artifacts you need to drive
# the PDU refresh rack-by-rack:
#
#   manifest              full per-node CSV: rack,dh,fabric,slot,bmn,node,serial,bmc_ip,org,sku,state,done,row
#   racks                 one row per rack: #nodes, #orgs, orgs, #prod, sku-mix, spare-gap, DONE?
#   rack <rackid>         detail for one rack — the node list + per-SKU spare requirement vs availability
#   row <n> [--dh s2]     every node on physical row <n> across its racks (Rack/SLOT/BMN/STATE/ORG/DH/SKU/BMC)
#                         add --counts for per-STATE totals only (e.g. row 2 --dh s2 --counts)
#   spares                ready spare pool by SKU (available) + recoverable pool (triage/fail/hold) by SKU
#   remaining [--org X]   racks NOT yet swapped, per org (honours the done-ledger); overall % complete
#   progress              top-line dashboard (racks done/remaining, nodes parked, spare posture)
#   plan [--num N]        pick the N easiest not-yet-swapped racks (default 16) + ready-backfill summary
#   gameplan [--num N]    the plan as actionable lists: rack list, prod→triage, ready spares, easy-wins
#   raw '<promql>'        escape hatch: run an arbitrary instant query, print the label sets
#
# This tool is READ-ONLY. It never transitions, powers, or delivers a node.
# Use it to plan/track; use the §3 runbook commands (cwctl / ipmitool /
# return_to_fleet.sh) to act.
#
# Progress ledger: append a rack id (e.g. s2-r024) per line to done_racks.txt as
# each rack's PDU is swapped. `#' comments and blank lines are ignored. Once a
# rack is in the ledger it is counted done for EVERY org that had a node in it.
#
# done_racks.txt is SHARED STATE, TRACKED IN GIT — several people run this tool
# and progress must match on every desktop. So: `git pull --rebase' before you
# plan a wave, and commit+push each completion the same day (keep the file
# sorted with `sort -u -o done_racks.txt done_racks.txt' to keep merges clean).
# An unpushed completion is invisible to everyone else and will get re-planned
# into someone's next wave. Use DONE_FILE / --done for private what-if ledgers.
#
# Scope (optional): SCOPE_FILE with one rack id per line limits every view to the
# racks actually in the refresh scope (e.g. the manager's list). Default = every
# rack currently reporting a node.
#
# Env / flags:
#   VM_URL      VictoriaMetrics query endpoint (default: us-west super-region, which serves RNO2)
#   REGION      metric region label (default: RNO2)
#   DONE_FILE   completed-rack ledger      (default: ./done_racks.txt)   | --done <file>
#   SCOPE_FILE  in-scope rack allowlist    (default: none = all racks)   | --scope <file>
#   --dh <s2>   limit every view to one datahall — Phase 1 is S2 (FAB7): --dh s2  (bare "--dh 2" also works)
#   --org <id>  (remaining view) limit to one org
#   --num <N>   (plan/gameplan) target rack count (default 16)
#   --color <auto|always|never> / --no-color   colorize status keywords (default auto: on when a TTY,
#               off when piped or NO_COLOR is set; needs perl). Legend: production=green ready=bright-green
#               triage=yellow hold=cyan fail=red broken=bright-red rma=magenta in-progress=blue GAP=red.
#
# Datasource note: RNO2/RNO2A metrics live in the US-WEST regional VictoriaMetrics
# (Grafana UID P546B13C064491369). If VM_URL is unreachable from your shell, run
# from a jump host / mlxhelp context, or fall back to the mgmt cluster:
#   tls rno2 mgmt ; kubectl get bmn --show-labels   (see notes/RUNBOOK.md)
#
# Usage (racks/remaining tables are auto-aligned + colored — no need to pipe to column):
#   ./rno2_pdu.sh progress
#   ./rno2_pdu.sh racks --dh s2
#   ./rno2_pdu.sh gameplan --dh s2
#   ./rno2_pdu.sh rack s2-r024
#   ./rno2_pdu.sh row 1 --dh s2                               # every node on physical row 1 in datahall s2
#   ./rno2_pdu.sh manifest > rno2_manifest_$(date +%F).csv    # raw CSV, uncolored
#   ./rno2_pdu.sh remaining --org 189d5b
#
set -euo pipefail

VM_URL="${VM_URL:-http://vmui.us-west.int.coreweave.com/select/0/prometheus/api/v1/query}"
REGION="${REGION:-RNO2}"
DONE_FILE="${DONE_FILE:-./done_racks.txt}"
SCOPE_FILE="${SCOPE_FILE:-}"

# cache dir is created lazily (only commands that need live data allocate it),
# so `help` / `raw` work even where TMPDIR isn't writable.
CACHE_DIR=""; CACHE=""
init_cache_dir() {
  [[ -n "$CACHE_DIR" ]] && return
  CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rno2_pdu.XXXXXX")"
  trap 'rm -rf "$CACHE_DIR"' EXIT
  CACHE="$CACHE_DIR/manifest.tsv"
}

die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need curl; need jq; need awk; need sort

# --- arg parse --------------------------------------------------------------
CMD="${1:-help}"; shift || true
ORG_FILTER=""
DH_FILTER="${DH_FILTER:-}"     # e.g. s2 — limit every view to one datahall (Phase 1 = S2 / FAB7)
PLAN_N="${PLAN_N:-16}"         # target number of racks for plan/gameplan (>= this many when possible)
COLOR_WHEN="auto"             # auto|always|never — colorize node/rack status (--color / --no-color)
COUNTS=0                      # row view: --counts shows per-STATE counts instead of the node list
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)   ORG_FILTER="${2:-}"; shift 2 ;;
    --dh)    DH_FILTER="${2:-}"; shift 2 ;;
    --counts) COUNTS=1; shift ;;
    --num)   PLAN_N="${2:-16}"; shift 2 ;;
    --done)  DONE_FILE="${2:-}"; shift 2 ;;
    --scope) SCOPE_FILE="${2:-}"; shift 2 ;;
    --vm-url) VM_URL="${2:-}"; shift 2 ;;
    --color) COLOR_WHEN="${2:-auto}"; shift 2 ;;
    --no-color) COLOR_WHEN="never"; shift ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

# Datahall shorthand: allow --dh 2 for s2 (datahall values are s<N>).
[[ "$DH_FILTER" =~ ^[0-9]+$ ]] && DH_FILTER="s$DH_FILTER"

# Decide whether to emit ANSI color: never if asked / NO_COLOR set / perl absent;
# always if forced; auto = only when stdout is a real terminal.
COLOR_ON=0
case "$COLOR_WHEN" in
  never)  COLOR_ON=0 ;;
  always) COLOR_ON=1 ;;
  auto)   [[ -t 1 && -z "${NO_COLOR:-}" ]] && COLOR_ON=1 ;;
esac
command -v perl >/dev/null 2>&1 || COLOR_ON=0

# --- color filter: wrap status keywords in ANSI *after* alignment -----------
# Applied as the last stage of a pipeline so column widths (measured on plain
# text) stay correct. No-op unless COLOR_ON=1. Manifest/raw are never colored.
#   production=green ready=bright-green triage=yellow hold=cyan
#   fail=red broken=bright-red rma=magenta  |  in-progress states=blue  |  GAP=red  DONE Y=green
colorize() {
  [[ "${COLOR_ON:-0}" == 1 ]] || { cat; return; }
  perl -pe '
    BEGIN{ %C=("production","32","ready","92","triage","33","hold","36","fail","31",
               "broken","91","rma","35","debug","90","dev","90","unknown","90",
               "onboard","94","test","94","fielddiag","94","node-zap","94",
               "power-cycle","94","power-drain","94"); }
    for my $k (sort { length($b) <=> length($a) } keys %C){ s/\b\Q$k\E\b/\e[$C{$k}m$k\e[0m/g; }
    s/\bGAP\b/\e[31mGAP\e[0m/g;
    s/\bcovered\b/\e[32mcovered\e[0m/g;
  '
}

# racks view: paint the WHOLE row green when its last column (done) is Y
# (a completed rack), otherwise fall back to normal keyword coloring.
colorize_racks() {
  [[ "${COLOR_ON:-0}" == 1 ]] || { cat; return; }
  perl -pe '
    BEGIN{ %C=("production","32","ready","92","triage","33","hold","36","fail","31",
               "broken","91","rma","35","debug","90","dev","90","unknown","90"); }
    if ($. > 1 && /(?:^|\s)Y\s*$/) { chomp; $_ = "\e[32m$_\e[0m\n"; }   # done rack → full green row
    else { for my $k (keys %C){ s/\b\Q$k\E\b/\e[$C{$k}m$k\e[0m/g; } }
  '
}

# --- VM query helper: prints selected metric labels as TSV ------------------
# $1 = PromQL, $2 = jq per-metric transform (operates on each .metric object)
vmq() {
  local q="$1" filter="$2" resp
  resp="$(curl -sfG "$VM_URL" --data-urlencode "query=$q" 2>/dev/null)" \
    || die "VM query failed (endpoint $VM_URL unreachable?). Try --vm-url or the kubectl fallback in the header."
  jq -e '.status=="success"' >/dev/null 2>&1 <<<"$resp" \
    || die "VM returned non-success for query: $q"
  jq -r ".data.result[].metric | $filter" <<<"$resp"
}

# --- build the joined cache once, reused by every view ----------------------
# Columns: rack  dh  fabric  slot  bmn  node  serial  bmc_ip  org  sku  state  done  row
#   row = ds.coreweave.com/physical-topology.row (the physical DC row the rack sits in, e.g. 13)
build_cache() {
  init_cache_dir
  local state_tsv="$CACHE_DIR/state.tsv" info_tsv="$CACHE_DIR/info.tsv" topo_tsv="$CACHE_DIR/topo.tsv"

  # STATE metric is authoritative for identity+state and already carries org/deviceslot/serial/bmc.
  vmq "baremetal_node_status_flcc_state{region=\"$REGION\"} == 1" \
    '[.bmn, .deviceslot, (.node // ""), (.serial // .bmn_serial // ""), (.bmc_ip // .label_net_coreweave_cloud_bmc_ip // ""), (.cluster_org // "unknown"), .state] | @tsv' \
    > "$state_tsv"
  [[ -s "$state_tsv" ]] || die "no BareMetalNode state series returned for region=$REGION"

  # INFO metric supplies cw_sku (join key: bmn). Some orphan/fleetops nodes lack info → sku=unknown.
  vmq "bmn:baremetal_node_info:limit_1{region=\"$REGION\"}" \
    '[.bmn, (.cw_sku // "unknown")] | @tsv' \
    > "$info_tsv"

  # TOPOLOGY metric supplies ds.coreweave.com/physical-topology.row (the physical DC row the rack sits in).
  # Join key: bmn. Soft fetch: if the metric/label is absent, row shows "?" (a row can't be derived from
  # the deviceslot, which only encodes the rack).
  : > "$topo_tsv"
  curl -sfG "$VM_URL" --data-urlencode "query=baremetal_node_physical_topology_labels{region=\"$REGION\"}" 2>/dev/null \
    | jq -r '.data.result[].metric | [.bmn, (.label_ds_coreweave_com_physical_topology_row // "")] | @tsv' > "$topo_tsv" 2>/dev/null || : > "$topo_tsv"

  # Optional scope allowlist (rack ids). Empty file/var = all racks.
  local scope="$CACHE_DIR/scope.txt"; : > "$scope"
  [[ -n "$SCOPE_FILE" && -f "$SCOPE_FILE" ]] && grep -vE '^\s*(#|$)' "$SCOPE_FILE" | tr -d ' ' | sort -u > "$scope"

  # Done ledger (rack ids).
  local done="$CACHE_DIR/done.txt"; : > "$done"
  [[ -f "$DONE_FILE" ]] && grep -vE '^\s*(#|$)' "$DONE_FILE" | tr -d ' ' | sort -u > "$done"

  awk -F'\t' -v OFS='\t' \
      -v scopef="$scope" -v donef="$done" -v dhf="$DH_FILTER" -v topof="$topo_tsv" '
    BEGIN{
      while((getline l < scopef)>0){ if(l!="") scope[l]=1 } ; nscope=length(scope)
      while((getline l < donef)>0){ if(l!="") done[l]=1 }
      while((getline l < topof)>0){ if(l!=""){ split(l,tp,"\t"); if(tp[1]!="") rowlbl[tp[1]]=tp[2] } }
    }
    NR==FNR{ if(FNR==1||$1!=""){ sku[$1]=$2 } ; next }   # first file = info.tsv (bmn -> sku)
    {
      bmn=$1; ds=$2; node=$3; serial=$4; bmc=$5; org=$6; state=$7
      # derive rack / datahall / slot from deviceslot  s<dh>-r<rack>-node-<nn>
      rack="unknown"; dh=""; slot=""
      if (match(ds, /^s[0-9]+-r[0-9]+/)) { rack=substr(ds,RSTART,RLENGTH) }
      if (match(ds, /^s[0-9]+/))         { dh=substr(ds,RSTART,RLENGTH) }
      n=split(ds,a,"-"); if(n>=3){ slot=a[3] (a[4]?"-"a[4]:"") }
      # fabric from datahall (SEC2/S2 = FAB7, SEC4/S4 = FAB13; others blank per site quirks)
      fab=""; if(dh=="s2") fab="RNO2-FAB7"; else if(dh=="s4") fab="RNO2-FAB13"
      if (dhf!="" && dh!=dhf) next                      # datahall filter (Phase 1 = s2)
      if (nscope>0 && !(rack in scope)) next            # scope filter
      d=(rack in done)?"Y":"N"
      s=(bmn in sku)?sku[bmn]:"unknown"
      # row = ds.coreweave.com/physical-topology.row label; "?" if absent (not derivable from deviceslot)
      rr=(bmn in rowlbl && rowlbl[bmn]!="")?rowlbl[bmn]:"?"
      print rack, dh, fab, slot, bmn, node, serial, bmc, org, s, state, d, rr
    }
  ' "$info_tsv" "$state_tsv" | sort -k1,1 -k4,4 > "$CACHE"
}

# --- views ------------------------------------------------------------------
view_manifest() {
  echo "rack,dh,fabric,slot,bmn,node,serial,bmc_ip,org,sku,state,done,row"
  awk -F'\t' '{ $1=$1 } 1' OFS=',' "$CACHE"
}

view_racks() {
  # 'row' = ds.coreweave.com/physical-topology.row (the physical DC row), shared by all nodes in the rack.
  printf 'row\track\tdh\tfab\tnodes\torgs\tprod\tready_here\tsku_mix\torgs_list\tdone\n'
  awk -F'\t' '
    { rack=$1; dh[rack]=$2; fab[rack]=$3; row[rack]=$13; n[rack]++
      orgs[rack","$9]=1
      if($11=="production"){ prod[rack]++; skc[rack","$10]++ }
      if($11=="ready") ready[rack]++
      done[rack]=$12
    }
    END{
      for(r in n){
        # orgs list + count
        oc=0; ol=""
        for(k in orgs){ split(k,p,","); if(p[1]==r){ oc++; ol=ol (ol?"|":"") p[2] } }
        # sku mix among prod
        smix=""
        for(k in skc){ split(k,p,","); if(p[1]==r){ smix=smix (smix?"|":"") p[2]":"skc[k] } }
        printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n", row[r], r, dh[r], fab[r], n[r], oc, (prod[r]+0), (ready[r]+0), (smix?smix:"-"), ol, done[r]
      }
    }' "$CACHE" | sort -k2,2
}

view_rack() {
  local rk="${1:-}"; [[ -n "$rk" ]] || die "usage: rack <rackid>  (e.g. s2-r024)"
  echo "== Rack $rk =="
  awk -F'\t' -v rk="$rk" '$1==rk{ printf "  %-10s %-16s %-9s %-16s %-8s %-14s %s\n", $4,$5,$11,$9,$2,$10,$8 }' "$CACHE" \
    | (echo "  SLOT       BMN              STATE     ORG              DH       SKU            BMC_IP"; cat)
  echo
  echo "  Per-SKU spare requirement (production nodes in this rack) vs. site-wide READY availability:"
  awk -F'\t' -v rk="$rk" '
    $1==rk && $11=="production"{ need[$10]++ }
    $11=="ready"{ avail[$10]++ }
    END{
      any=0
      for(s in need){ any=1; g=need[s]-(avail[s]+0);
        printf "    %-14s need %2d   ready-avail %2d   %s\n", s, need[s], (avail[s]+0), (g>0?"GAP "g" (recover from triage/fail or accept dip)":"covered") }
      if(!any) print "    (no production nodes in this rack — no spares required)"
    }' "$CACHE"
}

view_row() {
  # List every node on a physical row (ds.coreweave.com/physical-topology.row), across all its racks.
  # Row numbers repeat across datahalls, so scope with --dh (e.g. row 1 --dh s2).
  local rw="${1:-}"; [[ -n "$rw" ]] || die "usage: row <row-number> [--dh s2] [--counts]   (e.g. row 1 --dh s2)"
  local n
  n=$(awk -F'\t' -v rw="$rw" '$13==rw{c++} END{print c+0}' "$CACHE")
  if [[ "$n" -eq 0 ]]; then
    echo "No nodes found on row '$rw'${DH_FILTER:+ in datahall $DH_FILTER}. (row numbers repeat across datahalls — try --dh)" >&2
    return 0
  fi
  if [[ "$COUNTS" == 1 ]]; then
    # --counts: per-STATE totals for the row instead of the node list (states by count desc, TOTAL last)
    printf 'STATE\tCOUNT\n'
    awk -F'\t' -v rw="$rw" '$13==rw{c[$11]++} END{ for(s in c) printf "%s\t%d\n", s, c[s] }' "$CACHE" \
      | sort -t"$(printf '\t')" -k2 -nr
    printf 'TOTAL\t%d\n' "$n"
    return 0
  fi
  printf 'Rack\tSLOT\tBMN\tSTATE\tORG\tDH\tSKU\tBMC_IP\n'
  awk -F'\t' -v rw="$rw" '$13==rw{ print $1"\t"$4"\t"$5"\t"$11"\t"$9"\t"$2"\t"$10"\t"$8 }' "$CACHE" \
    | sort -t"$(printf '\t')" -k1,1 -k2,2
}

view_spares() {
  echo "READY spare pool by SKU (immediately usable for prefill/deliver):"
  awk -F'\t' '$11=="ready"{r[$10]++} END{ for(s in r) printf "  %-14s %d\n", s, r[s] }' "$CACHE" | sort
  echo
  echo "Recoverable pool by SKU (triage/fail/hold — recover to ready before it counts as a spare):"
  awk -F'\t' '$11=="triage"||$11=="fail"||$11=="hold"{k=$10" "$11; c[k]++}
    END{ for(k in c) printf "  %-14s %-8s %d\n", substr(k,1,index(k," ")-1), substr(k,index(k," ")+1), c[k] }' "$CACHE" \
    | sort
}

view_remaining() {
  # racks per org still standing (done==N), honouring scope; a rack counts once per org present in it.
  printf 'ORG\tRACKS\tDONE\tREMAINING\n'
  awk -F'\t' -v orgf="$ORG_FILTER" '
    { seen[$1","$9]=1; rackdone[$1]=$12 }
    END{
      for(k in seen){ split(k,p,","); r=p[1]; o=p[2];
        if(orgf!="" && o!=orgf) continue
        tot[o]++; if(rackdone[r]=="Y") d[o]++;
      }
      for(o in tot) printf "%s\t%d\t%d\t%d\n", o, tot[o], (d[o]+0), tot[o]-(d[o]+0)
    }' "$CACHE" | sort -t"$(printf '\t')" -k4 -nr
}

view_progress() {
  awk -F'\t' '
    { rack[$1]=1; if($12=="Y") rackdone[$1]=1
      nodes++; if($11=="production") prod++
      if($11=="production" && $12=="Y") prod_swapped++
    }
    END{
      tr=length(rack); dr=length(rackdone)
      printf "RNO2 PDU refresh — progress\n"
      printf "  racks in scope : %d\n", tr
      printf "  racks swapped  : %d  (%.1f%%)\n", dr, (tr?100*dr/tr:0)
      printf "  racks remaining: %d\n", tr-dr
      printf "  nodes total    : %d   (production: %d)\n", nodes, prod
      printf "  prod nodes on already-swapped racks: %d\n", prod_swapped+0
    }' "$CACHE"
  echo
  echo "Spare posture:"
  view_spares | sed 's/^/  /'
}

# --- planner (plan / gameplan) ----------------------------------------------
# Picks the N easiest not-yet-swapped racks and builds an accurate ready-node
# backfill plan. "Easiest" = pure non-production racks first (nothing to drain,
# no spare needed), then production racks that CAN be covered by matching
# ready spares, then ready-heavy racks last (selecting them burns spares).
# The backfill rule: a production node pulled to triage is replaced in its
# nodepool by a matching ready node (same cw_sku + fabric) drawn from a rack
# NOT in this wave — so the pool never drops below target. Where matching ready
# spares run short, it lists the triage/fail "easy-win" nodes to recover to
# ready first (the return-to-ready flow) to unlock those racks.
run_planner() {
  need python3
  local mode="$1"
  python3 - "$CACHE" "$mode" "$PLAN_N" <<'PY'
import sys, collections
cache, mode, N = sys.argv[1], sys.argv[2], int(sys.argv[3])

Node = collections.namedtuple("Node", "rack dh fab slot bmn node serial bmc org sku state")
racks = collections.defaultdict(list)
rack_row = {}                                # rack -> node.coreweave.cloud/rack (physical row number)
with open(cache) as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if len(c) < 12 or c[11] == "Y":   # skip malformed + already-swapped racks
            continue
        n = Node(*c[:11])
        racks[n.rack].append(n)
        rack_row.setdefault(n.rack, c[12] if len(c) > 12 else "?")

def key(n): return (n.sku, n.fab)            # nodepool-compat match: cw_sku + fabric

# per-rack rollups
info = {}
ready_pool = collections.defaultdict(list)   # (sku,fab) -> [Node] in ready state
easywin    = collections.defaultdict(list)   # (sku,fab) -> [Node] in triage/fail (recoverable candidates)
for r, ns in racks.items():
    prod  = [n for n in ns if n.state == "production"]
    rdy   = [n for n in ns if n.state == "ready"]
    orgs  = sorted({n.org for n in ns})
    info[r] = dict(dh=ns[0].dh, fab=ns[0].fab, nodes=len(ns), prod=prod, ready=rdy, orgs=orgs)
    for n in rdy: ready_pool[key(n)].append(n)
    for n in ns:
        if n.state in ("triage", "fail"):
            easywin[key(n)].append(n)
# prefer triage over fail as easy-wins (triage is usually the milder / more transient bucket)
for k in easywin: easywin[k].sort(key=lambda n: 0 if n.state == "triage" else 1)

for r in info:
    i = info[r]
    if not i["prod"] and not i["ready"]:      i["score"] = i["nodes"]                 # pure non-prod: easiest
    elif i["prod"]:                            i["score"] = 100 + len(i["prod"])*100 + len(i["orgs"])*10 + i["nodes"]
    else:                                      i["score"] = 100000 + len(i["ready"])  # ready-heavy: last (burns spares)

selected, used, assign, gap = [], set(), {}, []   # assign: prod_bmn -> spare Node
def pool_avail(k, exclude_rack):
    return [n for n in ready_pool.get(k, [])
            if n.bmn not in used and n.rack not in selected and n.rack != exclude_rack]

while len(selected) < N:
    progressed = False
    for r in sorted([x for x in info if x not in selected], key=lambda x: info[x]["score"]):
        i = info[r]
        trial, ok, taken = {}, True, set()
        for p in i["prod"]:
            cand = next((n for n in pool_avail(key(p), r) if n.bmn not in taken), None)
            if cand is None: ok = False; break
            trial[p.bmn] = cand; taken.add(cand.bmn)
        if not ok:
            if r not in [g[0] for g in gap]: gap.append((r, i))
            continue
        selected.append(r)
        for n in i["ready"]: used.add(n.bmn)          # rack's own ready leaves the pool (powered off)
        for pb, sp in trial.items(): assign[pb] = sp; used.add(sp.bmn)
        progressed = True
        break
    if not progressed:
        break

sel_prod  = [p for r in selected for p in info[r]["prod"]]
sel_ready = sorted({assign[p.bmn].bmn: assign[p.bmn] for p in sel_prod}.values(), key=lambda n: n.rack)
pure      = [r for r in selected if not info[r]["prod"]]
covered   = [r for r in selected if info[r]["prod"]]

# unmet demand among not-selected production racks, by (sku,fab)
unmet = collections.defaultdict(int)
for r in info:
    if r in selected: continue
    for p in info[r]["prod"]:
        unmet[key(p)] += 1
# subtract still-available ready
for k in list(unmet):
    unmet[k] = max(0, unmet[k] - len(pool_avail(k, None)))

def kfmt(k): return f"{k[0]}/{k[1] or 'no-fab'}"

print(f"RNO2 PDU refresh — PLAN  (target {N} racks; {len(selected)} selected)")
print(f"  easiest picks : {len(pure)} pure non-production racks (no drain, no spare)")
print(f"                  {len(covered)} production racks covered by ready backfill")
print(f"  prod nodes → triage : {len(sel_prod)}   ready spares committed : {len(sel_ready)}")
if len(selected) < N:
    print(f"  ⚠ only {len(selected)} racks were feasible — the rest are spare-limited (see easy-wins).")
print()
print("  Ready spare pool remaining by SKU/fabric after this wave's commitments:")
allk = set(list(ready_pool) + list(unmet))
for k in sorted(allk):
    print(f"    {kfmt(k):22s} avail {len(pool_avail(k, None)):3d}   unmet-demand-elsewhere {unmet[k]:3d}")
need = {k: v for k, v in unmet.items() if v > 0}
if need:
    print()
    print("  Easy-wins to unlock more production racks — recover these triage/fail nodes to READY")
    print("  (HPC spot-check first; then: cwctl flcc node -w return-to-ready -o -m \"...\" $BMN):")
    for k in sorted(need):
        cands = [n for n in easywin.get(k, []) if n.bmn not in used and n.rack not in selected][:need[k]]
        got = ", ".join(f"{n.bmn}({n.rack},{n.state})" for n in cands) or "NONE on unselected racks — source spares externally"
        print(f"    {kfmt(k):22s} need {need[k]:3d}  → {got}")

if mode == "gameplan":
    print("\n" + "="*78)
    print("GAME PLAN — actionable lists\n")
    print("A) RACK LIST (work these — listed easiest first; 'row' = ds.coreweave.com/physical-topology.row):")
    print(f"   {'ROW':5s} {'RACK':12s} {'DH':4s} {'FAB':12s} {'NODES':5s} {'PROD':4s} {'READY':5s} ORGS")
    for r in sorted(selected, key=lambda x: info[x]["score"]):
        i = info[r]
        print(f"   {rack_row.get(r,'?'):5s} {r:12s} {i['dh']:4s} {i['fab'] or '-':12s} {i['nodes']:5d} {len(i['prod']):4d} {len(i['ready']):5d} {'|'.join(i['orgs'])}")
    print("\nB) PRODUCTION NODES → TRIAGE  (cwctl flcc node -w return-to-fleet -m 'Triage for RNO2 PDU Refresh' $BMN):")
    if sel_prod:
        print(f"   {'PROD_BMN':16s} {'RACK':12s} {'SKU':14s} {'FAB':12s} {'ORG':12s} -> {'BACKFILL_SPARE':16s} FROM_RACK")
        for p in sorted(sel_prod, key=lambda n: n.rack):
            sp = assign[p.bmn]
            print(f"   {p.bmn:16s} {p.rack:12s} {p.sku:14s} {p.fab or '-':12s} {p.org:12s} -> {sp.bmn:16s} {sp.rack}")
    else:
        print("   (none — all selected racks are non-production; no triage/backfill needed)")
    print("\nC) READY NODES TO DELIVER AS BACKFILL  (let capacity control place them into the pulled pool):")
    if sel_ready:
        print(f"   {'SPARE_BMN':16s} {'RACK':12s} {'SKU':14s} FAB")
        for n in sel_ready:
            print(f"   {n.bmn:16s} {n.rack:12s} {n.sku:14s} {n.fab or '-'}")
    else:
        print("   (none needed)")
    print("\nD) EASY-WINS — recover to READY to unlock spare-limited production racks:")
    if need:
        print(f"   {'BMN':16s} {'RACK':12s} {'STATE':8s} {'SKU':14s} FAB")
        for k in sorted(need):
            for n in [x for x in easywin.get(k, []) if x.bmn not in used and x.rack not in selected][:need[k]]:
                print(f"   {n.bmn:16s} {n.rack:12s} {n.state:8s} {n.sku:14s} {n.fab or '-'}")
    else:
        print("   (none — ready pool covers all reachable production racks)")
PY
}

usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,"");print}' "$0"; }

# tab-separated tables are aligned here (widths from plain text) then colorized.
align() { column -t -s "$(printf '\t')" 2>/dev/null || cat; }

case "$CMD" in
  manifest)  build_cache; view_manifest ;;                          # raw CSV — never colored
  racks)     build_cache; view_racks     | align | colorize_racks ;;
  rack)      build_cache; view_rack "${1:-}"  | colorize ;;
  row)       build_cache; view_row "${1:-}" | align | colorize ;;
  spares)    build_cache; view_spares    | colorize ;;
  remaining) build_cache; view_remaining | align | colorize ;;
  progress)  build_cache; view_progress  | colorize ;;
  plan)      build_cache; run_planner plan     | colorize ;;
  gameplan)  build_cache; run_planner gameplan | colorize ;;
  raw)       vmq "${1:?usage: raw '<promql>'}" '. ' ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $CMD" >&2; usage; exit 2 ;;
esac
