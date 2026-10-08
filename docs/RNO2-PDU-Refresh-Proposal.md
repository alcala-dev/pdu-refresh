# RNO2A PDU Refresh — Execution Proposal

> **DRAFT — owner: A. Alcala (FROps).** Plan to complete the remaining PDU replacements in RNO2A,
> rack-by-rack, at ≥24 racks/wave, with spare coverage and zero avoidable customer capacity loss.
> All node/state numbers are live snapshots (VictoriaMetrics US-WEST `P546B13C064491369`, region `RNO2`)
> as of query time — re-pull before each wave; counts drift daily.

> **Path note:** the tracker referenced throughout (§8) lives at the root of this repository as
> `./pdu.sh`. `return_to_fleet.sh`, `notes/RUNBOOK.md`, and `notes/command_notes.md` are separate
> internal ops artifacts and are **not** part of this repo.

---

## 1. Executive summary

- The unit of work is the **physical rack**, not the org. **RNO2A racks are org-mixed** — verified: rack
  `s2-r024` holds `node-01` = org **cw0002** and `node-02` = org **97715c**, both in production. If a swap
  de-powers a rack, every org with a node in it is affected at once. → **Sequence by rack; enumerate
  per-rack org membership live; account for every org in each rack.**
- **Default posture: no maintenance window.** Each swap is engineered to be non-impacting so it needs no
  MAINT — a DO ticket is the record. The lever is **power topology: dual-fed (A/B) racks get a per-feed
  swap with no node power-off at all** (no drain/spare/MAINT — the target path). A MAINT is opened *only*
  when a swap is unavoidably customer-impacting (the §6 gate). Steps 2–8 of the runbook apply only to
  nodes that would actually lose power (single-fed racks / full de-power).
- **"Racks per org" method:** an org's rack count = the number of distinct physical racks that hold at
  least one of its nodes (derived live via the §4 per-org rack query). Because racks are shared, a single
  rack counts toward every org present in it, so an org's node count and its rack count don't track 1:1
  (e.g. `189d5b`'s ~988 nodes span many shared racks). Use the racks-per-org tally to **set the
  sequencing order**, and use the live per-rack enumeration (§4) as the authoritative membership that
  drives each individual swap.
- **Spares are the binding constraint, not PDU labor.** RNO2 currently has **92 `ready` nodes total**
  (all in the `cw-internal` fleetops pool) against **1,673 in production**. You cannot prefill-cover 24
  racks of *production* customer nodes at once **on the de-power path**. → Prefer per-feed swaps (no
  power loss, no spares needed); where nodes must power off, do **spare-free racks first** (fleetops +
  non-prod) and size customer waves to matching-SKU spare availability. A dip/MAINT is only the fallback
  when a production node must lose power with no matching spare (§6).
- **⚠️ There are ZERO H100 spares in `ready`.** The 92-node ready pool is `CPU-* (29) + GPU-A100-01 (11)
  + GPU-GH200-01 (52)` — no `GPU-H100-0x` at all. But **every node in the S2 (FAB7) and S4 (FAB13) racks
  is H100**, and H100 is the bulk of production. So H100 racks **cannot be prefill-covered today** — you
  must first **recover H100 spares from the triage/fail pool** (H100-01: 26 triage/18 fail; H100-04:
  15 triage/29 fail; H100-02: 1 triage/9 fail — many are transient XID109/PEX890xx false positives per
  the RNO2A quirks doc, recoverable to `ready` after an HPC spot-check) **or** run the H100 racks as an
  agreed capacity-dip maintenance. This is the #1 scheduling gate for Blocks B/C.
- **Site scale (live):** **565 distinct racks** currently host RNO2 nodes — **S2/FAB7 228, S4/FAB13 192,
  S6/SPK01 144** — and **356 of them (63%) are org-mixed** (host >1 org). Because most racks are shared,
  the **rack is the unit of work** and every co-tenant in a rack is handled together in the same window;
  the tracker (§8) computes the per-org rack list and per-rack spare gap live so each shared rack is
  fully scoped before its swap.
- Recommend a **canary rack (internal, non-customer)** to validate the runbook before scaling to
  24 racks/wave.

### Live RNO2 fleet snapshot (state = 1)
| state | count | notes |
|---|---:|---|
| production | 1,673 | in customer/prod clusters |
| ready | 92 | **the entire spare/prefill pool** (all `cw-internal`) |
| triage | 48 | |
| hold | 15 | already parked (all `cw-internal`) |
| rma | 133 | |
| fail | 98 | |
| broken / debug / test / fielddiag / power-* | ~27 | in-flight lifecycle |
| **total BMNs** | **~2,094** | |

### Live per-org production footprint (customer impact per org)
| org | production nodes | | org | production nodes |
|---|---:|---|---|---:|
| 189d5b (Mistral, primary) | 988 | | cw4637 (CW Inference) | 109 |
| 3de217 | 201 | | cfc69f | 48 |
| 97715c (Silico) | 116 | | c3e81c (CZI/DFS) | 43 |
| 208261 (Marin) | 65 | | cwde22 | 36 |
| b5500f | 15 | | cw0002 (CW Storage) | 10 |
| cw1337 / pocfeb / 60e2f0 | 6 each | | ex7 / cwac1d | 4 each |
| ff9f72 / cw-internal | 3 each | | cwsa / 82d82b | 2 each |

> Note: `3de217` is a **201-node production tenant**, not the "~1 node unresolved" entry in the old
> quirks draft — resolve its owner before scheduling its racks. `cw-internal` production = 3 (the pool
> is `ready`/`hold`/`triage`, not prod).

---

## 2. Site facts that constrain the plan (RNO2A quirks)

- **Two LOCODEs, one logical zone:** US-SPK01 (NAP01, SEC6) + US-SPK02 (NAP02, SEC1/2/4). **Ship &
  dispatch by LOCODE, never region name** (Switch's "RNO1/RNO2" labels are offset from ours).
- **Rack/datahall naming in `deviceslot`:** `s2-r###-node-##` = SEC2 datahall S2 (fabric **RNO2-FAB7**);
  `s4-r###-node-##` = SEC4 datahall S4 (fabric **RNO2-FAB13**). SEC1 and SEC6 (SPK01) also present.
- **Ticket routing by sector:** SEC1 → `service-desk-albatross` (SDA); **SEC2 / SEC4 / SEC6 → `dct-ops`
  (DO tickets)**. RNO1 ("Albatross") is SOE, not us — do not action RNO1 nodes.
- **Mixed-gen, multi-vendor:** A100/H100/L40/GH200; **H100 is both Supermicro and Dell (Dell in SEC4)**.
  Confirm vendor before any hands-on. **No Blackwell here** (US-WEST-01A is the GB200/GB300 Sparks zone —
  don't conflate).
- **FAB13 (SEC4) sheds H100 nodes on XID 109** (INCI-2084) — expect churn in `s4-*` racks; don't
  mistake it for PDU/power faults.
- **Metrics datasource caveat:** the RNO2A quirks/on-call drafts say "query US-CENTRAL"; the live data
  for this plan came from **US-WEST VM `P546B13C064491369`** (returns full RNO2 data). Verify the UID in
  your Grafana before a wave; if empty, try the US-CENTRAL regional VM.

---

## 3. Per-rack workflow (the runbook applied to every rack)

For each rack, in order. 1 is prep (hours/days ahead); 2–8 is the swap.

**Default posture: no formal maintenance.** We engineer each swap to be non-impacting, so most racks
need **no MAINT window** — just a DO/hardware ticket as the work record and a courtesy heads-up to
co-tenants per policy. A **MAINT is opened only when a swap is *unavoidably* customer-impacting** — see
the decision gate in §6. Confirm with change-management whether any customer/sector mandates a MAINT
regardless of impact; otherwise proceed on the no-MAINT path.

**0. Record.** Open the **DO/hardware ticket** for the rack (route by sector: SEC2/4/6 → `dct-ops`,
SEC1 → SDA) and add the rack to `completed/rno2/done_racks.txt` when complete. Skip the MAINT unless §6 says it's required.

**1. Enumerate the rack (authoritative).** Get every node in the rack with state + org + serial + BMC IP
(§4 query). Freeze this as the rack's node list.

**1.5. Determine power topology — this decides everything downstream.** Confirm the rack's PDU/feed
layout with facilities/DCT (netbox powerfeed + physical check):
- **Dual-fed (A/B), nodes dual-corded** → replace **one feed at a time**; nodes ride the surviving feed
  and **never lose power**. **No drain, no spare, no power-off, no MAINT** — skip straight to step 7 and
  supervise the per-feed swap. *This is the target path and how 24 racks/wave is achieved cleanly.*
- **Single-fed, or the swap requires full-rack de-power** → nodes will lose power → continue steps 2–8
  (spare/drain/hold/power-off), and apply the §6 MAINT gate.

**2. Ensure spares (production nodes only).** For each *production* node in the rack, confirm a
matching-SKU/fabric `ready` spare exists so the owning pool stays at target:
- CKS pools: enable **Node Pool prefill** (provisions the replacement *before* the node is drained → no
  capacity gap). Confirm with the pool owner.
- Don't hand-deliver a specific spare. Instead **replenish the `ready` pool** and let the capacity
  controller / prefill place nodes automatically — return a recovered/parked node to ready with:
  `cwctl flcc node -w return-to-ready -o -m "<message>" $BMN`.
- If no matching spare exists, the rack's production capacity **will** dip while nodes are off — that
  crosses the §6 gate, so open a MAINT and notify before proceeding (don't take the dip silently).

**3. Take production nodes out of production.** Pull each production node back into the FLCC lifecycle
(prod → triage) with the return-to-fleet workflow; workloads should be drained/idle first:
```bash
cwctl flcc node -w return-to-fleet -m "Triage for RNO2 PDU Refresh" $BMN
```
Bulk this with `scripts/return_to_fleet.sh` (same workflow, dry-run + 1:1 ticket pairing).
Non-production nodes (ready/hold/triage/fail/fleetops) are already out of prod — skip to step 5.

**4. Pin the nodes so automation won't move them.** Assign yourself as owner so FLCC/capacity control
won't re-deliver or re-onboard mid-swap:
```bash
cwctl owner assign bmn <bmn1> <bmn2> ... -u aalcala -g fro          # add --override if already owned
```

**5. Hold the nodes in place.** Move the rack's nodes to the **`hold`** state (real FLCC state; 15 nodes
already sit here) so they stay parked, powered-off, pinned to the rack:
```bash
cwctl flcc node -w default -s hold -o -m "holding for RNO2 PDU Refresh" $BMN
```

**6. Power off the whole rack (node BMCs).** `jumpipmitool` resolves the BMC + creds from the BMN, so
pass the BMN directly — no need to look up `bmc_ip` / `getbmcpass`:
```bash
# per node — check state, power off, then re-confirm Off before the DCT touches the PDU
jumpipmitool -c "chassis power status" $BMN
jumpipmitool -c "chassis power off"    $BMN
```
(FLCC also exposes `power-off` / `powering-off` workflow steps — usable as an alternative; confirm the
driving command with the FLCC owners.) **Gate:** every node reports `Chassis Power is off` before handing
the rack to the DCT.

**7. Hand off to DCT for the physical PDU swap.** Route the DO ticket to `dct-ops` (SEC2/4/6) or `SDA`
(SEC1); coordinate with **@dct-rno** on-call; ops channel **#ops-rno2-us-spk02-sparks**. Confirm both
A/B feeds are staged so the swap is per-feed where the rack supports it.

**8. Power on + return to fleet (post-swap).**
```bash
# per node — check state, then power on
jumpipmitool -c "chassis power status" $BMN
jumpipmitool -c "chassis power on"     $BMN
# then return each node through onboard/zap/HPC-verification back to ready→production:
./scripts/return_to_fleet.sh --rtf "<bmns...>" --tickets "<DO tickets...>"        # dry-run
./scripts/return_to_fleet.sh --rtf "<bmns...>" --tickets "<...>" --run            # executes cwctl flcc node -w return-to-fleet
```
Un-assign the temporary owner once nodes are healthy. Verify GPU/IB health before declaring the rack done
(`nvidia-smi`, `dcgmi diag -r 2`, IB per-leaf BW — see `notes/command_notes.md`).

---

## 4. The core query — "nodes in a rack, with status + org"

**Authoritative live enumeration** (single metric already carries state, org, serial, BMC — no join):
```promql
# every node in rack s2-r024 with lifecycle state, owning org, serial, BMC IP, k8s node
baremetal_node_status_flcc_state{region="RNO2", deviceslot=~"s2-r024-.*"} == 1
```
Returned labels per node: `state`, `cluster_org`, `bmn`, `serial`/`bmn_serial`, `bmc_ip`, `node`,
`deviceslot`, `zone`. This is the source of truth for steps 1–6.

**Per-org rack inventory** (derive the authoritative rack list per org — this is the "racks per org" method):
```promql
# racks per org (distinct s?-r### groups)
count by (cluster_org) (
  count by (cluster_org, rack) (
    label_replace(baremetal_node_status_flcc_state{region="RNO2"} == 1,
                  "rack", "$1", "deviceslot", "(s[0-9]+-r[0-9]+)-.*")
  )
)
```

**Live cluster (kubectl) equivalent**, from the mgmt cluster — use when you need CRD fields / to act:
```bash
tls rno2 mgmt        # teleport into rno2a-mgmt
# nodes in a rack (slot label mirrors deviceslot):
kubectl get bmn -l "flcc.coreweave.com/state,node.coreweave.cloud/slot" \
  -o custom-columns='BMN:.metadata.name,STATE:.metadata.labels.flcc\.coreweave\.com/state,\
OWNER:.metadata.labels.ownership\.coreweave\.com/owner,SKU:.metadata.labels.ds\.coreweave\.com/sku\.cw-sku,\
BMC:.metadata.labels.ds\.coreweave\.com/node\.ip\.bmc,SLOT:.metadata.labels.node\.coreweave\.cloud/slot' \
  | grep 's2-r024-'          # confirm exact rack/slot label name with: kubectl get bmn <one> --show-labels
```
> Confirm the on-CRD rack/slot label name (`node.coreweave.cloud/slot` seen in metrics as
> `label_node_coreweave_cloud_slot`) against a live BMN before scripting the kubectl path.

**Spare check before a wave** (matching-SKU ready pool):
```promql
count by (cw_sku) (
  baremetal_node_status_flcc_state{region="RNO2", state="ready"} == 1
  * on (bmn) group_left(cw_sku)
    bmn:baremetal_node_info:limit_1{region="RNO2"}
)
```

---

## 5. Sequencing — how to hit ≥24 racks/wave safely

**Phase 1 = datahall S2 (FAB7), racks `s2-r###`.** The refresh starts in S2 (aligns with the existing
`rno2-fab7-ProdToTriage` work). S2 = **228 racks, all H100 on RNO2-FAB7** — so the **H100 spare gap is
the immediate gate for any de-power path**. First confirm S2 rack power topology (step 1.5): **dual-fed
racks get per-feed swaps with no power-off — no H100 spare needed at all**, which is the primary way S2
runs without maintenance. Only for single-fed / full-de-power racks does the H100 gap bind — there, stand
up an H100 spare-recovery track from day 1 — after an HPC spot-check, return each transient triage/fail
H100 to the ready pool with `cwctl flcc node -w return-to-ready -o -m "<message>" $BMN` (XID109/PEX890xx
are usually transient) and let capacity control place them — then fall back to a MAINT dip with Mistral
(189d5b) + S2 co-tenants only if a node must power off with no spare. Scope every
tracker view with `--dh s2`. Later phases: S4 (FAB13, 192 racks — watch the XID109 churn) then S6 (SPK01,
144 racks). Within each datahall, apply the org order below.

**Guiding order within a datahall (blast-radius first, then the manager's smallest-cw-first intent):**

**Wave block A — spare-free, zero customer coordination (do first; validates the 24-rack runbook).**
The `cw-internal` fleetops pool (92 ready + 15 hold + 48 triage nodes) and any all-non-production racks
carry **no customer** and need **no spares**. Start the canary here (1 rack), then run these at
24 racks/wave. This is where the "86 cw-internal racks" in the table actually live and where throughput
is unconstrained.

**Wave block B — smallest customer-owned cw orgs first** (smallest-cw-first ordering): **cwsa (2 prod) →
cw0002 (10) → cwde22 (36) → cw4637 (109)**. Per-feed swaps run these with no window; only de-power racks
are sized to spare availability (MAINT only per §6). Because racks are org-mixed, each will *also* contain
non-cw nodes — pull the full per-rack org list (§4) and account for every co-tenant.

**Wave block C — external customer racks, largest last**, spare-gated and account-team-coordinated:
smallest → largest by production footprint: b5500f (15) → c3e81c (43) → cfc69f (48) → 208261 (65) →
97715c (116) → 3de217 (201) → **189d5b (988, Mistral)**. 189d5b dominates the site; its racks will
almost always be spare-constrained → schedule in many small windows or with an agreed capacity dip.

### 5a. Decision: org-anchored waves + opportunistic co-tenant triage

The wave is **anchored** to the current org (smallest cw first), but the atomic unit stays the **rack**.
When an anchored rack also holds *other* orgs' production nodes, **those nodes are triaged in the same
window** (you can't de-power half a rack). This is intentional and efficient: because the big tenants
(189d5b 988, 3de217 201) are spread across many racks, handling them opportunistically inside small-org
waves **decomposes those giants into rack-sized bites** — so by the time they come up as the "primary"
org, most of their racks are already done.

Two rules make this safe (non-negotiable):

1. **Co-tenant production nodes get the full treatment, not a silent triage.** Each one still needs a
   **matching spare (by SKU *and* fabric)** + owner notification + inclusion in the MAINT scope. Match
   spares **per node** — SKUs differ *within* a rack (verified: `s2-r024` node-01 = `GPU-H100-02`,
   node-02 = `GPU-H100-04`). Do not pull a customer's prod node without its spare/notification.
2. **Track completion by rack, not by org.** Once a rack's PDU is swapped, *all* its nodes (every org)
   are done. Maintain the `completed/rno2/done_racks.txt` ledger and compute **remaining racks per org = its racks minus
   already-swapped racks** (query below) — that's the real progress metric and what makes "less work on
   the big orgs later" true rather than double-counted.

```promql
# All production nodes in a candidate rack, with SKU (drives per-node spare matching across co-tenants)
(baremetal_node_status_flcc_state{region="RNO2", state="production", deviceslot=~"s2-r024-.*"} == 1)
  * on (bmn) group_left(cw_sku) bmn:baremetal_node_info:limit_1{region="RNO2"}

# Remaining (org, rack) pairs after excluding swapped racks — feed done racks into the deviceslot!~ regex
count by (cluster_org, rack) (
  label_replace(
    baremetal_node_status_flcc_state{region="RNO2", deviceslot!~"s2-r024-.*|s4-r314-.*"} == 1,
    "rack","$1","deviceslot","(s[0-9]+-r[0-9]+)-.*")
)
```
> ⚠️ PromQL gotcha: `*` binds tighter than `==`, so the state×info join **must** be parenthesised
> `(… == 1) * on(bmn) group_left(…) …` — without the parens it silently returns empty.

**Throughput math / the real limiter.** 24 racks × ~14 devices/rack (netbox `device_count` on sampled
RNO2A racks) ≈ **~330 nodes/wave**. Against a 92-node ready pool, only **Block A** sustains 24
*production-covered* racks/wave. For Blocks B/C, either (a) cap the wave at (matching ready spares)
÷ (nodes/rack), or (b) run the physical swaps at 24 racks/wave but accept a scheduled capacity
reduction for the covered orgs. **Decide this explicitly per wave; don't let spares silently bound it.**

---

## 6. Safety gates & rollback

**MAINT decision gate (default = NO maintenance).** Open a MAINT **only if any** of these is true for
the rack; otherwise proceed on the no-MAINT path (DO ticket + co-tenant courtesy notice):
1. The swap requires nodes to lose power (single-fed / full de-power — see step 1.5) **and** any
   production node lacks a matching-SKU/fabric spare or prefill → the owning pool drops below target.
2. A production workload on the rack **cannot be gracefully drained** in the window (non-interruptible,
   no checkpoint) → the swap would interrupt running work.
3. Change-management / a customer contract mandates a MAINT for that sector or org regardless of impact.
> If none apply — non-prod racks, **dual-fed per-feed swaps (no power loss)**, or prod racks fully
> prefill-covered and gracefully drained — **no MAINT is required.** Keep the DO ticket as the record and
> keep every safety gate below; "no MAINT" means "no customer impact," not "less rigor."

- **Dry-run everything.** `return_to_fleet.sh` and any bulk loop must preview first; the script already
  defaults to dry-run and refuses mismatched lists.
- **Power-off gate:** no PDU is touched until *all* nodes in the rack report `Chassis Power is off`.
- **Blast-radius cap:** one rack = one atomic unit; never de-power a rack before its spares/prefill are
  confirmed green (Block B/C) or it's confirmed non-production (Block A).
- **Pin + hold before power-off** (steps 4–5) so capacity control can't re-deliver a held node into a
  customer pool mid-swap (avoids the orphan/stale-move failure mode).
- **Rollback:** power the rack back on (`chassis power on`) and `return_to_fleet.sh` restores nodes
  through the normal onboard→ready→production path; un-assign the temp owner. If a node won't return,
  it follows standard triage/RMA — it does not block the rest of the rack.
- **Reconcile the org/rack table** against §4's live per-org rack query before committing the schedule,
  and confirm `3de217` ownership and whether `cfc69f`'s `prod-rno3` nodes are physically in RNO2A.

---

## 7. Open items to confirm before wave 1
1. Exact `cwctl nlcc` / `cwctl flcc node` subcommands & flags for production-exit and `hold` (`--help`).
2. Whether FLCC's `power-off` workflow step is the sanctioned de-power path vs raw ipmitool.
3. On-CRD rack/slot label name for the kubectl enumeration path.
4. Netbox is the physical-rack + A/B power-feed source of truth (powerfeed data was sparse in the mirror);
   pull the authoritative rack + PDU list with facilities/DCT for the final rack count.
5. Per-SKU spare inventory vs. the customer racks in Blocks B/C → sets real wave sizes.

---

## 8. Tracking & monitoring — `pdu.sh`

> **Multi-site note.** The tracker now covers several legacy sites and lives in the `pdu-refresh`
> repo (formerly `rno2-pdu-refresh`, script formerly `rno2_pdu.sh`). Every command below operates on
> RNO2 because `rno2` is the default `--site`; pass `--site us-west-02` / `--site us-west-04` for the
> others. Each site keeps its own ledger under `completed/<site>/`, so completions never mix across
> regions. See the repo README and `docs/SITES.md`.


A **read-only** tracker that pulls the live BareMetalNode picture for RNO2 straight from VictoriaMetrics,
joins state + org + SKU, and renders the manifest and progress you drive the refresh from. It never
transitions, powers, or delivers a node — plan/track with it; act with the §3 runbook commands. Because it
re-queries live every run, counts always reflect the fleet *now*, and progress is measured against your
completion ledger.

### Prerequisites
- `curl`, `jq`, `awk` on `PATH` (the script checks and exits if missing).
- Network reachability to the VictoriaMetrics query endpoint (default: the US-WEST super-region VM that
  serves RNO2). Run from a jump host / VPN-connected shell. If unreachable, pass `--vm-url <endpoint>` or
  fall back to the mgmt cluster (`tls rno2 mgmt` + kubectl — see the script header and `notes/RUNBOOK.md`).

### The completion ledger — `completed/rno2/done_racks.txt`
One rack id per line (e.g. `s2-r024`); `#` comments and blank lines ignored. **Append a rack the moment
its PDU swap is verified complete.** Once a rack is in the ledger it counts as done for *every* org that
had a node in it — that's what makes the "big orgs need less work later" math correct.

The ledger is **shared state, tracked in git**, because several people run the tracker and progress must
match on every desktop. So marking a rack complete is a four-step action, not a one-liner — an unpushed
completion is invisible to everyone else and will get re-planned into someone's next wave:
```bash
git pull --rebase                                   # start from everyone else's completions
echo "s2-r024" >> completed/rno2/done_racks.txt                    # mark a rack complete
sort -u -o completed/rno2/done_racks.txt completed/rno2/done_racks.txt            # keep sorted — minimizes merge conflicts
git commit -am "chore(ledger): s2-r024 PDU swap complete" && git push
```
**Pull before planning a wave**, or the planner will hand you racks that are already done. A merge
conflict in the ledger is never a real disagreement — it's an append-only set, so union both sides and
re-sort (see the README).
Optional: `--scope <file>` (a rack allowlist, one id per line) limits every view to the racks actually in
scope for the refresh; default is every rack currently reporting a node.

### Commands (Phase 1 = S2/FAB7 → add `--dh s2` to any view)
| Command | What it gives you |
| --- | --- |
| `./pdu.sh progress --dh s2` | Top-line dashboard: racks done/remaining, % complete, nodes parked, spare posture |
| `./pdu.sh racks --dh s2` | One line per rack, with its `row` (= `ds.coreweave.com/physical-topology.row`): #nodes, #orgs, orgs, #prod, sku-mix, ready, DONE? |
| `./pdu.sh rack s2-r024` | One rack in detail — node list (slot/bmn/state/org/sku/BMC) + per-SKU spare need vs ready availability |
| `./pdu.sh row 1 --dh s2` | Every node on physical row 1 (all its racks): Rack/SLOT/BMN/STATE/ORG/DH/SKU/BMC_IP (`--dh 2` also works) |
| `./pdu.sh row 2 --dh s2 --counts` | Same row, but per-STATE totals only (hold/production/ready/fail…) + TOTAL |
| `./pdu.sh remaining --dh s2` | Racks left per org (honours the ledger); an org drops toward 0 as its racks get swapped |
| `./pdu.sh spares --dh s2` | READY spare pool by SKU + recoverable pool (triage/fail/hold) by SKU |
| `./pdu.sh plan --dh s2` | Pick the N easiest not-yet-swapped racks (default 16) + ready-backfill summary + easy-wins |
| `./pdu.sh gameplan --dh s2` | The plan as actionable lists: rack list, prod→triage, ready spares, easy-wins |
| `./pdu.sh manifest --dh s2` | Full per-node CSV (rack,dh,fabric,slot,bmn,node,serial,bmc_ip,org,sku,state,done,row) |
| `./pdu.sh raw '<promql>'` | Escape hatch — run an arbitrary instant query, print the label sets |

### `plan` / `gameplan` — the wave picker + backfill plan
`plan` selects the **N easiest not-yet-swapped racks** (default 16; `--num` to change) and builds an
accurate ready-node backfill plan; `gameplan` prints the same selection as **actionable lists**. Selection
order (easiest first): **(1) pure non-production racks** — all fail/rma/triage/hold, nothing to drain, no
spare needed; **(2) production racks that can be covered** by a matching **ready** spare (same `cw_sku` +
fabric) drawn from a rack *not* in the wave; **(3) ready-heavy racks last** (selecting them burns spares).
The backfill rule is encoded: each production node pulled to triage is paired 1:1 with a specific ready
spare BMN on another rack, so the pulled nodepool never drops below target. Where matching spares run
short, it computes the shortfall by SKU/fabric and lists the **easy-win** triage/fail nodes to recover to
`ready` first (via `cwctl flcc node -w return-to-ready …`), excluding any node that sits on a rack already
selected for this wave.

> **`gameplan` output = the four lists you asked for:** (A) rack list showing each rack's `row`
> (`ds.coreweave.com/physical-topology.row`, the physical DC row the rack sits in), listed easiest-first
> (list order = work order); (B) production nodes → triage, each with its assigned backfill spare + source
> rack; (C) ready nodes to deliver as backfill; (D) easy-wins to recover to ready to unlock the
> spare-limited production racks.
>
> The `row` value comes from the `ds.coreweave.com/physical-topology.row` BMN label (via
> `baremetal_node_physical_topology_labels`, joined on `bmn`); if that label is absent for a node the row
> shows `?` (a row can't be derived from the deviceslot, which only encodes the rack). Row numbers repeat
> across datahalls, so read `row` alongside `dh`. A row is a physical aisle spanning many racks — handy for
> batching DCT work by aisle.
>
> ⚠️ Trade-off the tool makes explicit: picking a non-prod **triage/fail** rack to swap powers those nodes
> off, so they can't also be recovered as easy-win spares in the same wave. In a spare-tight SKU (e.g. S2
> H100 today, 0 ready), decide per wave whether a given triage/fail rack is better *swapped now* or
> *recovered to ready first* — the plan shows both the pick and the resulting easy-win shortfall.

### Color
Every human view **color-codes node/rack status** so state jumps out at a glance —
`production`=green, `ready`=bright-green, `triage`=yellow, `hold`=cyan, `fail`=red, `broken`=bright-red,
`rma`=magenta, in-progress states=blue, and spare `GAP`=red. In `racks`, a **completed rack (`done=Y`) is
shown as a full green row** so finished racks are obvious at a glance. Tables (`racks`, `remaining`)
auto-align, so no `| column` is needed. Color is **auto**: on at a terminal, off when piped or redirected (so `manifest`
CSVs and `> file` redirects stay clean). Force with `--color always`, disable with `--no-color` or
`NO_COLOR=1` (needs `perl`; degrades to plain if absent).

### Typical daily loop
```bash
# 0. Sync the shared ledger first — someone else may have finished racks
git pull --rebase

# 1. Morning: where do we stand, and can we cover H100 today?
./pdu.sh progress --dh s2
./pdu.sh spares --dh s2

# 2. Let the planner pick this wave's easiest 16 racks + the backfill/easy-win plan
./pdu.sh plan --dh s2                # summary: picks, spares committed, easy-wins
./pdu.sh gameplan --dh s2               # the four actionable lists (rack / prod→triage / spares / easy-wins)
./pdu.sh remaining --dh s2              # per-org progress cross-check (auto-aligned + colored)

# 3. Before working a rack, freeze its node list + spare requirement
./pdu.sh rack s2-r024

# 4. Snapshot the manifest for the wave's records
./pdu.sh manifest --dh s2 > snapshots/rno2/s2_manifest_$(date +%F).csv

# 5. After each rack's PDU swap is verified, tick the ledger, publish it, re-check
echo "s2-r024" >> completed/rno2/done_racks.txt
sort -u -o completed/rno2/done_racks.txt completed/rno2/done_racks.txt
git commit -am "chore(ledger): s2-r024 PDU swap complete" && git push
./pdu.sh progress --dh s2
```

### Overrides (env or flags)
`VM_URL` / `--vm-url` (query endpoint) · `REGION` (default `RNO2`) · `DONE_FILE` / `--done` (ledger) ·
`SCOPE_FILE` / `--scope` (rack allowlist) · `--dh <s2>` (datahall) · `--org <id>` (remaining view).
Run `./pdu.sh help` for the full header.
