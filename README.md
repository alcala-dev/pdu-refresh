# pdu-refresh

**A read-only planning and progress tracker for the legacy-site PDU refresh.**

`pdu.sh` pulls the live `BareMetalNode` (BMN) picture for a site straight from VictoriaMetrics —
no cluster login required — joins lifecycle state with owning org, `cw_sku`, and physical-topology
row, then renders it as the artifacts you actually need to drive a PDU replacement campaign rack by
rack: per-node manifests, per-rack spare-coverage math, a wave planner with 1:1 ready-node backfill
assignments, and progress against a per-site completion ledger.

> **This tool never mutates the fleet.** It issues instant `GET` queries only. It does not transition,
> power, drain, or deliver a node. Plan and track with this; act with the runbook commands in
> [docs/RNO2-PDU-Refresh-Proposal.md](docs/RNO2-PDU-Refresh-Proposal.md) (`cwctl`, `jumpipmitool`,
> `return_to_fleet.sh`).

---

## Sites

Every view is scoped to exactly one site, selected with `--site` (default `rno2`). A site maps to a
metric `region` label and to its own completion ledger, so progress for one region can never be
mixed into another's.

| `--site` | `region` label | Ledger | Datahalls |
| --- | --- | --- | --- |
| `rno2` *(default)* | `RNO2` | `completed/rno2/done_racks.txt` | `s2` `s4` `s6` |
| `us-west-02` | `US-WEST-02` | `completed/us-west-02/done_racks.txt` | `c160` |
| `us-west-04` | `US-WEST-04` | `completed/us-west-04/done_racks.txt` | `dh1` |

```bash
./pdu.sh sites                      # the table above, plus racks-done per ledger
./pdu.sh progress --site us-west-04
```

All three sites are served by the same US-WEST regional VictoriaMetrics (Grafana datasource UID
`P546B13C064491369`), so no per-site `--vm-url` is needed today.

To add a site, see [docs/SITES.md](docs/SITES.md) — it is two lines of shell plus a ledger file.

### Deviceslot shapes differ per site

The tool parses `deviceslot` generically as `<dh>-r<rack>-node-<nn>[-<zone>]`:

| Site | Example `deviceslot` | `dh` | `rack` |
| --- | --- | --- | --- |
| `rno2` | `s2-r024-node-01` | `s2` | `s2-r024` |
| `us-west-02` | `c160-r018-node-10-us-west-02b` | `c160` | `c160-r018` |
| `us-west-04` | `dh1-r002-node-01-us-west-04a` | `dh1` | `dh1-r002` |

The datahall is whatever precedes `-r<digits>`, the rack id always keeps its `dh` prefix, and any
trailing zone suffix is ignored. So `--dh` takes `s2`, `c160` or `dh1` depending on the site
(`--dh 2` remains shorthand for `s2`).

---

## Why it exists

Legacy racks are **org-mixed** — a single rack routinely holds production nodes belonging to several
different tenants, at several different SKUs. De-powering a rack therefore affects every org in it at
once, and each production node pulled out needs its own matching-SKU spare so the owning nodepool never
drops below target. That makes the *physical rack* the unit of work and the *ready spare pool* the
binding constraint — neither of which is visible from an org-oriented view of the fleet.

This tool computes that rack-centric, spare-aware view live, so a wave can be sized to what the fleet
can actually cover today rather than to PDU labor capacity.

## Requirements

| Dependency | Needed for | Behavior if missing |
| --- | --- | --- |
| `curl`, `jq`, `awk`, `sort` | everything | hard exit with `missing dependency: <name>` |
| `python3` | `plan`, `gameplan` | hard exit when those subcommands run |
| `perl` | ANSI status coloring | silently degrades to plain text |
| `column` | table auto-alignment | silently degrades to tab-separated |

Plus **network reachability to the VictoriaMetrics query endpoint**. Run from a VPN-connected shell or
a jump host. If the endpoint is unreachable the script exits with a message pointing at `--vm-url` and
the mgmt-cluster fallback (`tls <site> mgmt` + `kubectl get bmn`).

## Install

```bash
git clone https://github.com/alcala-dev/pdu-refresh.git
cd pdu-refresh
./pdu.sh help
```

No build step — it's a single Bash script with an embedded Python planner. The completion ledgers
(`completed/<site>/done_racks.txt`) ship **tracked in the repo**, so a fresh clone already knows what's
been swapped at every site. The ledger path is resolved relative to the script, so the tool works from
any working directory.

## Commands

Add `--site <id>` to any view. Within a site, scope to one datahall with `--dh`.

| Command | What it gives you |
| --- | --- |
| `./pdu.sh sites` | Known sites, their region label, ledger path, and racks completed |
| `./pdu.sh progress --dh s2` | Top-line dashboard — racks in scope / swapped / remaining, % complete, node + production totals, spare posture |
| `./pdu.sh racks --dh s2` | One line per rack: physical row, datahall, fabric, #nodes, #orgs, org list, #production, #ready, production SKU mix, done flag |
| `./pdu.sh rack s2-r024` | One rack in detail — full node list (slot / BMN / state / org / SKU / BMC IP) plus per-SKU spare requirement vs site-wide `ready` availability, flagged `GAP` or `covered` |
| `./pdu.sh row 1 --dh s2` | Every node on physical DC row 1, across its racks. Row numbers repeat between datahalls — always scope with `--dh` |
| `./pdu.sh row 2 --dh s2 --counts` | Same row, per-state totals only (descending) plus `TOTAL` |
| `./pdu.sh spares --dh s2` | `ready` spare pool by SKU (immediately usable) plus the recoverable pool (`triage`/`fail`/`hold`) by SKU and state |
| `./pdu.sh remaining --dh s2` | Racks left per org, honoring the ledger. `--org <id>` narrows to one tenant |
| `./pdu.sh plan --dh s2` | Select the N easiest not-yet-swapped racks (default 16, `--num N`), with the resulting backfill commitments and easy-win shortfall |
| `./pdu.sh gameplan --dh s2` | The same selection rendered as four actionable lists (see below) |
| `./pdu.sh manifest --dh s2` | Full per-node CSV — never colored, safe to redirect |
| `./pdu.sh raw '<promql>'` | Escape hatch — run an arbitrary instant query and print the raw label sets |
| `./pdu.sh help` | The script header (full flag and env reference) |

### `plan` / `gameplan` — the wave picker

Racks are scored easiest-first:

1. **Pure non-production racks** — nothing to drain, no spare required.
2. **Production racks that can be covered** by a matching `ready` spare (same `cw_sku` *and* fabric)
   drawn from a rack that is *not* in this wave.
3. **Ready-heavy racks last** — selecting them powers off spares, so it burns the pool.

Each production node selected for triage is paired **1:1 with a specific ready spare BMN on another
rack**, so the pulled nodepool never drops below target. Where matching spares run short, the planner
computes the shortfall per `(sku, fabric)` and lists the **easy-win** `triage`/`fail` nodes to recover to
`ready` first — excluding any node sitting on a rack already selected for this wave.

`gameplan` prints that as:

- **A) Rack list** — easiest first; list order *is* work order. Includes each rack's physical `row` for
  batching DCT work by aisle.
- **B) Production nodes → triage** — each with its assigned backfill spare and source rack.
- **C) Ready nodes to deliver as backfill.**
- **D) Easy-wins** — `triage`/`fail` nodes to return to `ready` to unlock spare-limited racks.

> **Trade-off the planner makes explicit:** swapping a non-production `triage`/`fail` rack powers those
> nodes off, so they can't also be recovered as easy-win spares in the same wave. In a spare-tight SKU,
> decide per wave whether a given rack is better *swapped now* or *recovered first* — the output shows
> both the pick and the resulting shortfall.

## The completion ledgers — `completed/<site>/done_racks.txt`

**These files are shared state, tracked in git.** Everyone running the tracker reads the same ledger, so
progress reads identically on every desktop — which only holds if completions are pushed. Keeping them in
the repo is deliberate: `progress`, `racks`, `remaining`, `plan`, and `gameplan` all derive from them, so a
completion that lives only on one laptop makes everyone else's numbers wrong and gets the same rack
re-planned into somebody's next wave.

One ledger per site, so RNO2 completions can never be counted against US-WEST-04 or vice versa.

Format: one rack id per line as it appears in `deviceslot` (`s2-r024`, `c160-r018`, `dh1-r002`). `#`
comments and blank lines are ignored. The file is kept **sorted and unique**. A brand-new site ledger is
legitimately empty.

### Marking a rack complete — the required workflow

```bash
SITE=rno2                                                  # the site you just worked
LEDGER="completed/$SITE/done_racks.txt"

git pull --rebase                                          # 1. start from everyone else's completions
echo "s2-r024" >> "$LEDGER"                                # 2. append the verified rack
sort -u -o "$LEDGER" "$LEDGER"                             # 3. re-sort (keeps merges clean, kills dupes)
git commit -am "chore(ledger): $SITE s2-r024 PDU swap complete"
git push                                                   # 4. same day — don't sit on it
```

Three conventions make this work with several people appending at once:

- **Pull before you plan.** A stale ledger will hand you racks that are already done.
- **Keep it sorted.** New ids land in the middle of the file rather than all colliding on the last line,
  so concurrent appends usually merge without conflict. The file is pure data (no header comments)
  precisely so `sort -u -o` is safe to run blind.
- **On a conflict, take both sides.** The ledger is an append-only set, so a conflict is never a real
  disagreement — union the two sides and re-sort:

  ```bash
  LEDGER=completed/rno2/done_racks.txt
  git checkout --ours "$LEDGER" && git checkout --theirs "$LEDGER" 2>/dev/null
  grep -hvE '^\s*(#|<<<|>>>|===)' "$LEDGER" | sort -u -o "$LEDGER"
  git add "$LEDGER" && git rebase --continue
  ```

Once a rack is in the ledger it counts as **done for every org that had a node in it** — that is what
makes "the big tenants need less work later" arithmetic correct instead of double-counted, since large
tenants are decomposed rack-by-rack as their racks get swapped inside other orgs' waves.

Point the tracker at a different ledger with `--done <file>` or `DONE_FILE=<file>` — useful for
what-if planning without touching shared state. Separately, `--scope <file>` (a rack allowlist, one id
per line) limits every view to the racks actually in scope for the refresh; default scope is every rack
currently reporting a node.

## Snapshots — `snapshots/<site>/`

Wave records live under `snapshots/<site>/`. Manifests carry **BMC IPs and serials**, and the `*.csv`
rule in `.gitignore` covers them, so anything you intend to keep has to be force-added deliberately:

```bash
./pdu.sh manifest --site rno2 --dh s2 > "snapshots/rno2/s2_manifest_$(date +%F).csv"
```

## Flags and environment

| Flag | Env | Default | Meaning |
| --- | --- | --- | --- |
| `--site <id>` | `SITE` | `rno2` | Site to operate on — selects region label + ledger |
| `--vm-url <url>` | `VM_URL` | US-WEST super-region query API | VictoriaMetrics instant-query endpoint |
| — | `REGION` | *(from site)* | Metric `region` label — overrides the site default |
| `--done <file>` | `DONE_FILE` | `completed/<site>/done_racks.txt` | Completion ledger |
| `--scope <file>` | `SCOPE_FILE` | *(none = all racks)* | Rack allowlist |
| `--dh <id>` | `DH_FILTER` | *(none)* | Limit every view to one datahall (`s2`, `c160`, `dh1`). Bare `--dh 2` = `s2` |
| `--org <id>` | — | *(none)* | `remaining` view: one org only |
| `--num <N>` | `PLAN_N` | `16` | `plan`/`gameplan` target rack count |
| `--counts` | — | off | `row` view: per-state totals instead of the node list |
| `--color <auto\|always\|never>`, `--no-color` | `NO_COLOR` | `auto` | ANSI status coloring |

**Color** is `auto`: on at a TTY, off when piped or redirected — so `manifest` CSVs and `> file` redirects
stay clean. Legend: `production` green, `ready` bright green, `triage` yellow, `hold` cyan, `fail` red,
`broken` bright red, `rma` magenta, in-flight lifecycle states blue, spare `GAP` red. In the `racks` view
a completed rack (`done=Y`) is painted as a **full green row**.

## Data model

`build_cache()` joins three metrics on the `bmn` label into one TSV, reused by every view:

| Metric | Supplies | Join |
| --- | --- | --- |
| `baremetal_node_status_flcc_state{region=…} == 1` | authoritative identity + `state`, `cluster_org`, `deviceslot`, `serial`, `bmc_ip`, `node` | base |
| `bmn:baremetal_node_info:limit_1{region=…}` | `cw_sku`, `ib_fabric` | `bmn`; missing sku → `unknown` |
| `baremetal_node_physical_topology_labels{region=…}` | `ds.coreweave.com/physical-topology.row` | `bmn`; soft fetch, missing → `?` |

Rack, datahall, and slot are derived from `deviceslot` (see the per-site shapes above). **Fabric comes
from the `ib_fabric` label**, falling back to the site's datahall→fabric map for nodes whose info series
lacks it (`rno2`: `s2` → `RNO2-FAB7`, `s4` → `RNO2-FAB13`). The physical row is **not** derivable from
`deviceslot` — it only encodes the rack — which is why the topology metric is joined separately.

Manifest columns (unchanged across sites):

```
rack,dh,fabric,slot,bmn,node,serial,bmc_ip,org,sku,state,done,row
```

> **PromQL gotcha encoded in this tool:** `*` binds tighter than `==`, so a state×info join must be
> parenthesized — `(… == 1) * on(bmn) group_left(cw_sku) …`. Without the parens it silently returns empty.

## Typical daily loop

```bash
SITE=rno2

# 0. Sync the shared ledgers first — someone else may have finished racks
git pull --rebase

# 1. Where do we stand, and can we cover the SKUs in play today?
./pdu.sh progress --site $SITE --dh s2
./pdu.sh spares   --site $SITE --dh s2

# 2. Let the planner pick this wave and build the backfill plan
./pdu.sh plan      --site $SITE --dh s2     # summary: picks, spares committed, easy-wins
./pdu.sh gameplan  --site $SITE --dh s2     # the four actionable lists
./pdu.sh remaining --site $SITE --dh s2     # per-org progress cross-check

# 3. Before working a rack, freeze its node list + spare requirement
./pdu.sh rack s2-r024 --site $SITE

# 4. Snapshot the manifest for the wave's records
./pdu.sh manifest --site $SITE --dh s2 > "snapshots/$SITE/s2_manifest_$(date +%F).csv"

# 5. After each swap is verified, tick the ledger, publish it, and re-check
echo "s2-r024" >> "completed/$SITE/done_racks.txt"
sort -u -o "completed/$SITE/done_racks.txt" "completed/$SITE/done_racks.txt"
git commit -am "chore(ledger): $SITE s2-r024 PDU swap complete" && git push
./pdu.sh progress --site $SITE --dh s2
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `unknown site '<x>'` | Not in the registry. Run `./pdu.sh sites`; add one per [docs/SITES.md](docs/SITES.md) |
| `VM query failed (endpoint … unreachable?)` | Not on VPN / wrong region VM. Pass `--vm-url`, or use the mgmt-cluster fallback: `tls <site> mgmt` then `kubectl get bmn --show-labels` |
| `no BareMetalNode state series returned for site=… (region=…)` | Query succeeded but empty — wrong `region` label for that site, or you're pointed at a VM that doesn't hold it. Verify the datasource UID in Grafana before a wave |
| Every `sku` shows `unknown` | The `bmn:baremetal_node_info:limit_1` recording rule didn't return — check it exists in that VM |
| Every `row` shows `?` | `baremetal_node_physical_topology_labels` or its row label is absent. This is a soft failure by design; all other views still work |
| `fab` shows `-` | That node has no `ib_fabric` label and the site has no fallback entry for its datahall. Spare matching still works, it just keys on `(sku, no-fab)` |
| No nodes found for a row | Row numbers repeat across datahalls — scope with `--dh` |
| Racks view columns look shifted | Fixed: blank fields are emitted as `-`, because `column -t` collapses consecutive separators |
| Output is uncolored at a terminal | `perl` missing, `NO_COLOR` set, or output is piped. Force with `--color always` |

## Repository layout

```
pdu.sh                                 # the tracker (read-only, multi-site)
completed/<site>/done_racks.txt        # SHARED completion ledgers, one per site — commit and push
  completed/rno2/done_racks.txt
  completed/us-west-02/done_racks.txt
  completed/us-west-04/done_racks.txt
snapshots/<site>/                      # per-site wave records (manifests; gitignored by default)
docs/SITES.md                          # how to add a site
docs/RNO2-PDU-Refresh-Proposal.md      # RNO2 execution plan: site constraints, per-rack runbook,
                                       # core queries, wave sequencing, safety gates
```

The runbook in `docs/` references two operational helpers that live outside this repo:
`return_to_fleet.sh` (bulk prod→triage / return-to-fleet with dry-run and 1:1 ticket pairing) and the
internal `notes/RUNBOOK.md` + `notes/command_notes.md`.

## Scope and confidentiality

Internal CoreWeave operational tooling. `docs/RNO2-PDU-Refresh-Proposal.md` contains tenant
identifiers, per-tenant production footprints, internal endpoints, and ticket-routing details — **keep
this repository private.** Generated manifests contain BMC IPs and serials; they are gitignored by
default and anything committed under `snapshots/` was force-added deliberately.

Owner: A. Alcala (Fleet Reliability Operations).
