# Vendored estone_SUITE

`estone_SUITE.erl` + `estone_SUITE_data/` are near-verbatim copies
from `erlang/otp` master, used to drive the snapshot/trend chart's
ESTONES bar with the canonical upstream micros instead of our own
slimmer reimplementation.

The suite has a `-DPGO` compile mode that drops the `common_test`
dependency — see the `-ifndef(PGO)` guards around `ct_event:notify/1`.
We always build with `-DPGO` so the suite is self-contained.

## Local modifications

Lines that differ from the upstream copy:

* `split_loop/3` (~853-854): bind `size(X)` and
  `binary_to_list(Y, 1, 2)` to `_`. Upstream uses them as
  statements, which triggers the OTP 27+ "result of calling X/N is
  ignored" warning.
* `int_arith/1` (~927) and `float_arith/1` (~962): bind the leading
  9× `do_arith(I) + ... + 66` expression to `_`. Same warning class
  — the sum is intentionally computed-and-discarded as part of the
  benchmark workload, but the compiler can't tell.

Carry these forward on every re-vendor (upstream churn is low
enough that hand-reapplying is cheaper than maintaining a patch
file).

## Source

- Upstream path: `erts/emulator/test/estone_SUITE.erl` and
  `erts/emulator/test/estone_SUITE_data/*`.
- Pinned at: `erlang/otp` master, commit
  `86d723182daeb489d4347a200be7b958101b4e36` (fetched 2026-05-11).

## Updating

The upstream files rarely change. To pull a fresh copy:

```sh
cd /tmp && git clone --depth=1 https://github.com/erlang/otp.git
SHA=$(git -C /tmp/otp rev-parse HEAD)
DST="apps/otp_benchmarks/vendor"
cp /tmp/otp/erts/emulator/test/estone_SUITE.erl                "$DST/"
cp /tmp/otp/erts/emulator/test/estone_SUITE_data/estone_cat.c  "$DST/estone_SUITE_data/"
cp /tmp/otp/erts/emulator/test/estone_SUITE_data/Makefile.src  "$DST/estone_SUITE_data/"
```

Then bump the SHA in this README, rerun the suite to sanity-check it
still compiles + runs, and commit.

## Why vendor and not submodule

Three files, ~1300 lines total, low churn. A git submodule adds
clone-time friction (`git submodule update --init`) for every
contributor for almost no upside. A plain copy plus a documented
update procedure is the right call here.
