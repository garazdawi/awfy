# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmark do
  @moduledoc """
  Behaviour for BEAM-internal benchmarks (phash2, ETS, Mnesia, …).

  See `PLAN/EXTENDED_BENCH_PLAN.md` for the design and
  `OtpBenchmarks` for the registry of currently-ported families.

  ## Shape

  Each module is a *family* of related scenarios driven by Benchee
  inputs, not the AWFY suite's `inner_iter` loop. A `phash2` family
  exposes one timed function (`run/1` calling `:erlang.phash2/1`)
  applied across many input variants (`small int`, `4 KB binary`,
  `1000-key map`, …). Benchee runs each (function × input) pair as
  a scenario and reports per-input medians.

  Why not reuse `Awfy.Benchmark`: the AWFY shape assumes one
  benchmark = one timed loop with `verify_result/1` checking the
  computed answer. Extended benchmarks call BIFs/NIFs whose
  per-call cost is what we want to measure — there's no "right
  answer" to verify against (a `phash2` regression doesn't change
  the hash) and the inner-iter loop adds dispatch overhead we'd
  rather not include in the timed window.

  ## Required callbacks

    * `name/0` — display name, used as the `.benchee` filename and
      the scenario prefix in Benchee output.
    * `inputs/0` — map of `scenario_name => input_term`. Each entry
      becomes one Benchee scenario.
    * `run/1` — the timed function. Receives the input term, called
      many times by Benchee under its time budget.

  ## Optional callbacks

    * `setup/1` — runs once per scenario via Benchee's
      `:before_scenario`. Receives the raw input from `inputs/0`,
      returns the value `run/1` will be called with. Use for
      benchmarks where the input must be allocated fresh on the
      target VM (e.g. an opened ETS table, a populated Mnesia
      schema) rather than baked into the suite at compile time.
      Default: identity.
    * `teardown/1` — runs once per scenario after timing finishes,
      with whatever `setup/1` returned. Use for cleanup
      (`:ets.delete/1`, `:mnesia.stop/0`). Default: no-op.
  """

  @doc "Display name (e.g. `\"phash2\"`)."
  @callback name() :: String.t()

  @doc """
  Map of scenario name → input term. The runner builds one Benchee
  scenario per entry, passing the input through `setup/1` (default
  identity) before timing.
  """
  @callback inputs() :: %{required(String.t()) => term()}

  @doc "The timed function — called many times by Benchee with the input."
  @callback run(input :: term()) :: term()

  @doc "Optional per-scenario setup. Default: identity."
  @callback setup(raw_input :: term()) :: term()

  @doc "Optional per-scenario cleanup. Default: no-op."
  @callback teardown(scenario_state :: term()) :: term()

  @optional_callbacks setup: 1, teardown: 1

  defmacro __using__(_) do
    quote do
      @behaviour OtpBenchmarks.Benchmark

      def setup(raw), do: raw
      def teardown(_), do: :ok

      defoverridable setup: 1, teardown: 1
    end
  end
end
