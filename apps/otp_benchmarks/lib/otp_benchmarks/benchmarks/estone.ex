# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Estone do
  @moduledoc """
  estone benchmark, driven by the verbatim upstream
  `erts/emulator/test/estone_SUITE.erl` (vendored at
  `apps/otp_benchmarks/vendor/`). Each input below corresponds to one
  micro from upstream's `micros/0` and invokes the per-micro entry
  function (`:estone_SUITE.<name>(<loops>)`) with the canonical loop
  count from the suite's `#micro{}` record — so per-iteration work
  matches what OTP's own PGO training and `estone_bench/1` measure.

  `port_io` is intentionally skipped here: it needs the `estone_cat`
  port executable built from `vendor/estone_SUITE_data/estone_cat.c`,
  and the framework doesn't yet wire up that build step. Adding it is
  a small follow-up — would expose port-I/O speed across versions.

  The composite weighted ESTONES headline (`(weight^2 * STONEFACTOR)
  / microsecs` summed across micros) is also not currently reproduced;
  the dashboard's snapshot bar instead uses a geomean of per-input
  medians as a single representative number. Reproducing the canonical
  ESTONES score is a separate workstream.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "estone"

  # Canonical loops per micro, copied from `micro(Name)` in
  # vendor/estone_SUITE.erl. Calibrated for 2002 hardware (~300ms each
  # on a reference VAX); on modern CPUs each call is sub-millisecond,
  # which Benchee handles by upping the sample count.
  #
  # Omitted micros:
  #   * `port_io` — needs the estone_cat C port binary built from
  #     vendor/estone_SUITE_data/; framework not yet wired up.
  #   * `generic` — registers `:funky` per call and kills it via
  #     async `exit(_, kill)`. estone runs each micro in a fresh
  #     process so the next iteration sees a clean registry, but
  #     Benchee invokes the same function many times back-to-back
  #     on one process; the second invocation's `register/2` races
  #     the pending unregistration of the first and crashes with
  #     "name already used" / "not a local pid". Re-introduce when
  #     the runner has a per-Benchee-sample-cleanup hook for state-
  #     ful micros (or rewrite generic to use `register_or_replace`).
  @micros [
    {"lists",                     6400},
    {"msgp",                      1515},
    {"msgp_medium",               1527},
    {"msgp_huge",                   52},
    {"pattern",                   1046},
    {"trav",                      2834},
    {"large_dataset_work",        1193},
    {"large_local_dataset_work",  1174},
    {"alloc",                     3710},
    {"bif_dispatch",              5623},
    {"binary_h",                   581},
    {"ets",                        342},
    {"int_arith",                 4157},
    {"float_arith",               5526},
    {"fcalls",                     882},
    {"timer",                     2312},
    {"links",                       30}
  ]

  def inputs do
    Map.new(@micros, fn {name, loops} ->
      {name, {String.to_atom(name), loops}}
    end)
  end

  def setup(input), do: input
  def run({fun, loops}), do: apply(:estone_SUITE, fun, [loops])
  def teardown(_), do: :ok

  # Estone micros are already internally looped (each takes a Loops
  # count and runs that many iterations) and several — generic,
  # links, timer — register named processes per call. Wrapping them
  # in an outer batch loop double-batches and races the registration,
  # so opt out of auto-batching.
  def batchable?, do: false
end
