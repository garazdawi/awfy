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

  Sampler shape: blocking, one-second cadence, until a deadline.
  Returns two parallel lists — `{cpu_pcts, mem_mbs}` — so the runner
  can drop them into separate `%Benchee.Suite{}` scenarios.

  `docker stats --no-stream` is used over the streaming variant
  because the streamed output is ANSI-escaped (designed for human
  TTY rendering). Each `--no-stream` call takes ~150-300ms by itself,
  so the effective cadence drifts past 1s — acceptable for trend
  signal across runs; the AWFY dashboard reads aggregates, not
  per-sample timing.
  """

  @doc """
  Sample CPU% and memory MB for `container` once per second until the
  monotonic-ms `deadline` passes. Returns parallel sample lists.
  Failures on a single call become a 0.0 sample (so a transient
  `docker stats` flake doesn't crash the whole run); the run-level
  stability check will flag a topology that's silently dropping reads.
  """
  @spec sample_until(String.t(), integer()) :: {[float()], [float()]}
  def sample_until(container, deadline) when is_binary(container) do
    loop(container, deadline, [], [])
  end

  defp loop(container, deadline, cpus, mems) do
    {cpu, mem} = read_once(container)
    cpus2 = [cpu | cpus]
    mems2 = [mem | mems]

    if System.monotonic_time(:millisecond) >= deadline do
      {Enum.reverse(cpus2), Enum.reverse(mems2)}
    else
      Process.sleep(1_000)
      loop(container, deadline, cpus2, mems2)
    end
  end

  defp read_once(container) do
    args = [
      "stats",
      "--no-stream",
      "--format",
      "{{.CPUPerc}}|{{.MemUsage}}",
      container
    ]

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
