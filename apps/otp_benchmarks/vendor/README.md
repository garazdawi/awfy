# Vendored estone_SUITE

`estone_SUITE.erl` + `estone_SUITE_data/` are verbatim copies from
`erlang/otp` master, used to drive the snapshot/trend chart's
ESTONES bar with the canonical upstream micros instead of our own
slimmer reimplementation.

The suite has a `-DPGO` compile mode that drops the `common_test`
dependency — see the `-ifndef(PGO)` guards around `ct_event:notify/1`.
We always build with `-DPGO` so the suite is self-contained.

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
