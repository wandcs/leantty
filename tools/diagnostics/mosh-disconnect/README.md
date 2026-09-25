# Mosh disconnect case handoff

This is a diagnostic handoff, not a LeanTTY gate or a production compatibility
layer. `cases.json` contains seven deduplicated families, with 19 failing/control
variants measured against mosh-client v0.1.3 at `77f2101` and stock server 1.4.0.
The recorded failures are **baseline observations**, not desired behavior.

Run every extracted HostBytes case together in WSL:

```sh
python3 tools/diagnostics/mosh-disconnect/run.py \
  --source /path/to/mosh-client-rs \
  --work /tmp/mosh-disconnect-review
```

The work directory must be new. Cargo and the source's locked dependencies must
already be available offline. The runner copies the source, appends one private
test module, and calls the existing `apply_host_bytes` unchanged. A failure ends
only that case; the next case starts from a fresh screen. It records all results
and their differences from v0.1.3 in `results.json`. It does not change the source
checkout, connect to a server, install LeanTTY, or relax any rejection rule.

Add `--scan` to replay all 277 exploratory inputs from `scan-cases.jsonl` in one
run. All failures and controls are retained, including raw-only rejection cases
that the stock server normalizes. `stock_sweep_requested` records whether an
input was included in the server sweep; it is not an independent session verdict.

Direct HostBytes rejection alone does not prove that stock Mosh emits that
sequence. `stock_baseline` separately records 19 fresh stock-server sessions:
12 Protocol failures and 7 positive controls. For example, a standalone reverse
video reset is rejected as raw HostBytes but stock server emits no change when
it is already off. The full recording did capture the reset after enabling it.

After a repair, run the whole pack, review desired outcomes for each family, and
recheck all selected stock-server cases together. C01–C03 identify ordinary
output compatibility gaps. C04 is a declared mode exclusion, C05 malformed
clipboard policy, and C06–C07 retained resource limits; do not weaken them just
to make every result `Ok`.

The complete batch method, 277-input scan, reference-state replay, fatal-exit
inventory, and evidence boundaries are in
[`mosh-disconnect-batch-20260925.md`](../../../docs/design/mosh-disconnect-batch-20260925.md).
Original session recordings remain local and ignored; this pack contains only
synthetic inputs.
