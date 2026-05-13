# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Xmpp.DockerStats do
  @moduledoc """
  Per-second CPU% + memory samplers for a docker container — used by
  `Awfy.Xmpp.Runner` to drive the AWFY trend signal from MongooseIM's
  resource use rather than from throughput. The ESL MongooseIM team
  measures the same way; with a *fixed* offered load (interarrival,
  user count) the interesting question is "how much CPU does the
  broker need", not "how many msgs/s did we sustain".

  Implements `Awfy.MetricSource` — first impl of the behaviour;
  PLAN/MONGOOSEIM_BENCH_PLAN.md § Phase 4 will add a Prometheus
  scraper alongside.

  Sampler shape: blocking, one-second cadence, until a deadline.
  Returns the `%{cpu_pct: [...], mem_mb: [...], throughput: nil}`
  map every `MetricSource` produces — the runner pairs it with the
  load-gen's throughput stream before handing both to
  `Awfy.AppBench.Result.build_multi/2`.

  `docker stats --no-stream` is used over the streaming variant
  because the streamed output is ANSI-escaped (designed for human
  TTY rendering). Each `--no-stream` call takes ~150-300ms by itself,
  so the effective cadence drifts past 1s — acceptable for trend
  signal across runs; the AWFY dashboard reads aggregates, not
  per-sample timing.
  """

  @behaviour Awfy.MetricSource

  @impl Awfy.MetricSource
  def supported_metrics(_source), do: [:cpu_pct, :mem_mb]

  @doc """
  Sample CPU% and memory MB for `container_or_list` once per second
  until the monotonic-ms `deadline` passes. Returns the
  `Awfy.MetricSource.samples` shape with `throughput: nil` since
  this source doesn't observe the load-gen.

  Accepts either a single container name (legacy single-broker
  callsites) or a list (multi-broker CETS cluster). For a list, each
  per-second sample is the SUM of the per-container CPU% and mem MB
  — that's the cluster-aggregate the dashboard plots. (Means of
  shares would just smear hot brokers; users care "how much CPU
  does the cluster need to handle this load".)

  Failures on a single call become a 0.0 sample (so a transient
  `docker stats` flake doesn't crash the whole run); the run-level
  stability check will flag a topology that's silently dropping reads.
  """
  @impl Awfy.MetricSource
  @spec sample_until(String.t() | [String.t()], integer()) :: Awfy.MetricSource.samples()
  def sample_until(container, deadline) when is_binary(container) do
    sample_until([container], deadline)
  end

  def sample_until(containers, deadline) when is_list(containers) do
    {cpu, mem} = loop(containers, deadline, [], [])
    %{cpu_pct: cpu, mem_mb: mem, throughput: nil}
  end

  defp loop(containers, deadline, cpus, mems) do
    {cpu, mem} = read_once(containers)
    cpus2 = [cpu | cpus]
    mems2 = [mem | mems]

    if System.monotonic_time(:millisecond) >= deadline do
      {Enum.reverse(cpus2), Enum.reverse(mems2)}
    else
      # No Process.sleep between iterations: a single
      # `docker stats --no-stream` blocks ~1 s while the daemon
      # collects a sampling window, so the call itself provides the
      # 1 Hz cadence we want. Adding a sleep on top stretches the
      # period to ~2 s and the dashboard ends up with ~30 samples
      # in a 60 s window instead of ~60. The parallel fan-out in
      # read_once/1 keeps the wall-clock pinned at ~1 s regardless
      # of cluster size.
      loop(containers, deadline, cpus2, mems2)
    end
  end

  defp read_once(containers) when is_list(containers) do
    # Sum the per-container CPU% + mem MB across the cluster — the
    # unbalanced-shard case (broker-1 takes 60%, broker-2 / -3 each
    # ~15%) shows as the cluster total, same convention as
    # `kubectl top` reports pod-summed.
    #
    # We deliberately do NOT use a single
    # `docker stats --no-stream <c1> <c2> <c3>` call here: empirically
    # Docker reads containers serially inside that call, so the
    # per-call wall-clock grows ~linearly with the cluster size and
    # at the 1 sample/s cadence we throttled to ~21 samples in a 60 s
    # window with 3 brokers. Spawning one `docker stats` per container
    # in parallel keeps the per-sample wall-clock pinned at the slowest
    # single-container read (~150–300 ms) regardless of cluster size.
    #
    # Phase 4 swaps this whole path for a MongooseIM prometheus
    # endpoint scrape (`:9091/metrics`); see PLAN/MONGOOSEIM_BENCH_PLAN.md
    # § Phase 4. The async-fan-out shape is kept compatible for an
    # easy migration.
    containers
    |> Enum.map(fn container ->
      Task.async(fn -> read_one(container) end)
    end)
    |> Enum.map(fn task -> Task.await(task, 10_000) end)
    |> Enum.reduce({0.0, 0.0}, fn {c, m}, {cs, ms} -> {cs + c, ms + m} end)
  end

  defp read_one(container) do
    args = ["stats", "--no-stream", "--format", "{{.CPUPerc}}|{{.MemUsage}}", container]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {out, 0} -> parse(out)
      _ -> {0.0, 0.0}
    end
  end

  @doc false
  # Public for tests. Parses one `--format "{{.CPUPerc}}|{{.MemUsage}}"`
  # line; e.g. `12.34%|1.23GiB / 8GiB` → {12.34, 1259.52} (MB).
  @spec parse(String.t()) :: {float(), float()}
  def parse(line) do
    case String.split(String.trim(line), "|", parts: 2) do
      [cpu, mem] -> {parse_cpu(cpu), parse_mem(mem)}
      _ -> {0.0, 0.0}
    end
  end

  defp parse_cpu(s) do
    case Float.parse(String.trim_trailing(String.trim(s), "%")) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  # `docker stats` mem format: `<used> / <limit>` where each value is
  # `<num><unit>` with unit in {B, KiB, MiB, GiB, TiB}. We only care
  # about the used side, converted to MB (1024-based MiB).
  defp parse_mem(s) do
    used = s |> String.split("/", parts: 2) |> List.first() |> String.trim()

    case Regex.run(~r/^([\d.]+)\s*([KMGTP]?i?B)$/i, used) do
      [_, n, unit] ->
        case Float.parse(n) do
          {v, _} -> v * unit_to_mb(String.upcase(unit))
          :error -> 0.0
        end

      _ ->
        0.0
    end
  end

  defp unit_to_mb("B"), do: 1 / (1024 * 1024)
  defp unit_to_mb("KIB"), do: 1 / 1024
  defp unit_to_mb("MIB"), do: 1.0
  defp unit_to_mb("GIB"), do: 1024.0
  defp unit_to_mb("TIB"), do: 1024 * 1024.0
  defp unit_to_mb("KB"), do: 1000 / (1024 * 1024)
  defp unit_to_mb("MB"), do: 1.0
  defp unit_to_mb("GB"), do: 1000.0
  defp unit_to_mb(_), do: 0.0
end
