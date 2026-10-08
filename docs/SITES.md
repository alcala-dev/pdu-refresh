# Adding a site

The tracker is multi-site. A "site" is a short id (`rno2`, `us-west-02`) that resolves to a metric
`region` label and to its own completion ledger. Adding one is two edits in `pdu.sh` plus a file.

## 1. Find the region label

Site ids are ours; `region` is whatever the metrics actually carry. Check before guessing — the two
are not always spelled the same (`rno2` → `RNO2`, but `us-west-02` → `US-WEST-02`).

```bash
BASE=http://vmui.us-west.int.coreweave.com/select/0/prometheus/api/v1
curl -sfG "$BASE/label/region/values" \
  --data-urlencode 'match[]=baremetal_node_status_flcc_state' | jq -r '.data[]' | sort
```

## 2. Check the deviceslot shape

Rack and datahall are parsed from `deviceslot` as `<dh>-r<rack>-node-<nn>[-<zone>]`. Confirm the new
site fits that shape before trusting any output:

```bash
curl -sfG "$BASE/query" \
  --data-urlencode 'query=baremetal_node_status_flcc_state{region="US-WEST-04"} == 1' \
  | jq -r '.data.result[].metric.deviceslot' | sort -u | head
```

Known shapes:

| Site | `deviceslot` | Parsed `dh` | Parsed `rack` |
| --- | --- | --- | --- |
| `rno2` | `s2-r024-node-01` | `s2` | `s2-r024` |
| `us-west-02` | `c160-r018-node-10-us-west-02b` | `c160` | `c160-r018` |
| `us-west-04` | `dh1-r002-node-01-us-west-04a` | `dh1` | `dh1-r002` |

If a new site does **not** match `<dh>-r<digits>-node-<nn>`, the parser in `build_cache()` needs
extending — don't just add the registry entry, or every rack will come back as `unknown`.

## 3. Register the site

In `pdu.sh`, add the id to `SITES_KNOWN` and a case arm to `site_region()`:

```bash
SITES_KNOWN="rno2 us-west-02 us-west-04 us-east-07"

site_region() {
  case "$1" in
    rno2)       echo "RNO2" ;;
    us-west-02) echo "US-WEST-02" ;;
    us-west-04) echo "US-WEST-04" ;;
    us-east-07) echo "US-EAST-07" ;;       # <- new
    *)          return 1 ;;
  esac
}
```

## 4. Fabric fallback (usually not needed)

Fabric comes from the `ib_fabric` label on `bmn:baremetal_node_info:limit_1`. Only add a
`site_fabric_map()` entry if a meaningful number of that site's nodes lack the label *and* you know
the correct datahall→fabric mapping. `rno2` needs one because its `s2` nodes predate `ib_fabric`:

```bash
site_fabric_map() {
  case "$1" in
    rno2) echo "s2=RNO2-FAB7 s4=RNO2-FAB13" ;;
    *)    echo "" ;;
  esac
}
```

Check coverage first:

```bash
curl -sfG "$BASE/query" \
  --data-urlencode 'query=bmn:baremetal_node_info:limit_1{region="US-EAST-07"}' \
  | jq -r '.data.result[].metric.ib_fabric // "(none)"' | sort | uniq -c
```

A missing fabric is not fatal — it shows as `-` and the planner keys spare matching on
`(sku, no-fab)`. It only matters if the site has more than one fabric, where an unlabelled node
could be matched against a spare it can't actually join.

## 5. Create the ledger

```bash
mkdir -p completed/us-east-07 snapshots/us-east-07
: > completed/us-east-07/done_racks.txt
: > snapshots/us-east-07/.gitkeep
git add completed/us-east-07 snapshots/us-east-07
```

The ledger must exist and must be **pure data** — one rack id per line, no header comments — so that
`sort -u -o` is safe to run blind. An empty file is correct for a site that hasn't started.

## 6. Verify

```bash
./pdu.sh sites                                  # new site listed, ledger found, 0 racks done
./pdu.sh progress --site us-east-07             # racks in scope > 0
./pdu.sh racks    --site us-east-07 | head      # rack ids look right, no "unknown"
./pdu.sh manifest --site us-east-07 | head -3   # 13 columns, dh/rack/slot populated
```

The thing most worth checking is that `rack` is never `unknown` and `dh` is never blank — both mean
the deviceslot didn't parse and every downstream rollup will be wrong.

## A note on the VM endpoint

All current sites are served by the US-WEST regional VictoriaMetrics
(Grafana UID `P546B13C064491369`), which is the `VM_URL` default. A site held in a different regional
VM needs `--vm-url` / `VM_URL` at call time; if that becomes common, make the endpoint part of the
site registry rather than a flag people have to remember.
