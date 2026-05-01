defmodule Awfy.Compare.Data do
  @moduledoc """
  Loads measurement runs from `results/` and assembles the flat
  dataset consumed by `mix awfy.compare` and `mix awfy.diff`.

  Public surface:

    * `load/2` — discover run dirs, decode each `meta.json` and every
      `*.benchee` file, return `%{runs: [...], rows: [...]}`.
    * `geomean_ratio/2` — suite-wide aggregate metric (geomean of
      per-benchmark `median_ms / baseline_median_ms`); used by both
      the dashboard index page and `mix awfy.diff`.

  A "row" is a single (run × benchmark × language) measurement,
  flattened so the dashboard JS doesn't have to navigate Benchee's
  Suite struct:

      %{
        label: "v1",
        timestamp: "2026-05-01T12:34:56Z",
        otp: "28.4.1",
        elixir: "1.19.5",
        hostname: "lukas-m5",
        cpu: "Apple M5",
        arch: "aarch64-apple-darwin",
        emu_flavor: "jit",
        lang: "erlang",
        benchmark: "Bounce",
        median_ms: 116.7,
        mean_ms: 116.4,
        stddev_ms: 0.8,
        samples_n: 9,
        inner_iter: 1500,
        source_sha256: "abc...",
        verified: true
      }
  """

  @doc """
  Discover run dirs under `root`, optionally filtering by label list.

  Returns `%{runs: [...meta...], rows: [...flat measurements...]}`.
  """
  @spec load(Path.t(), [String.t()] | nil) :: %{runs: [map()], rows: [map()]}
  def load(root \\ "results", labels \\ nil) do
    label_filter = if labels, do: MapSet.new(labels), else: nil

    run_dirs =
      case File.ls(root) do
        {:ok, names} ->
          names
          |> Enum.map(&Path.join(root, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.filter(&File.exists?(Path.join(&1, "meta.json")))

        _ ->
          []
      end

    runs =
      run_dirs
      |> Enum.map(&load_run/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn run ->
        label_filter == nil or MapSet.member?(label_filter, run.label)
      end)
      |> Enum.sort_by(& &1.timestamp)

    rows = Enum.flat_map(runs, &rows_for_run/1)
    %{runs: runs, rows: rows}
  end

  defp load_run(dir) do
    meta_path = Path.join(dir, "meta.json")

    with {:ok, json} <- File.read(meta_path),
         {meta, _, _} <- :json.decode(json, :ok, %{}) do
      %{
        dir: dir,
        label: get(meta, "label"),
        timestamp: get(meta, "timestamp"),
        otp: get(meta, "otp"),
        elixir: get(meta, "elixir"),
        format_version: get(meta, "format_version") || 0,
        machine: get(meta, "machine") || %{},
        runtime: get(meta, "runtime") || %{},
        config: get(meta, "config") || %{},
        git: get(meta, "git") || %{},
        benchmarks_meta: get(meta, "benchmarks") || []
      }
    else
      _ -> nil
    end
  end

  defp rows_for_run(run) do
    bench_paths =
      Path.wildcard(Path.join(run.dir, "*.benchee"))

    bench_paths
    |> Enum.flat_map(fn path ->
      bench_name = Path.basename(path, ".benchee")

      case decode_suite(path) do
        nil ->
          []

        suite ->
          per_bench_meta = bench_meta(run.benchmarks_meta, bench_name)
          inner_iter = get(per_bench_meta, "inner_iter")
          languages = get(per_bench_meta, "languages") || %{}

          Enum.map(suite.scenarios, fn scenario ->
            {bname, lang} = parse_name(scenario.name)
            stats = scenario.run_time_data.statistics
            lang_meta = Map.get(languages, lang, %{})

            %{
              label: run.label,
              timestamp: run.timestamp,
              otp: run.otp,
              elixir: run.elixir,
              hostname: get(run.machine, "hostname"),
              cpu: get(run.machine, "cpu"),
              arch: get(run.machine, "arch"),
              cores: get(run.machine, "cores"),
              emu_flavor: get(run.runtime, "emu_flavor"),
              schedulers_online: get(run.runtime, "schedulers_online"),
              lang: lang,
              benchmark: bname || bench_name,
              median_ms: ns_to_ms(stats.median),
              mean_ms: ns_to_ms(stats.average),
              stddev_ms: ns_to_ms(stats.std_dev),
              samples_n: stats.sample_size,
              inner_iter: inner_iter,
              source_sha256: get(lang_meta, "source_sha256"),
              verified: get(lang_meta, "verified")
            }
          end)
      end
    end)
  end

  defp decode_suite(path) do
    case File.read(path) do
      {:ok, bin} ->
        try do
          :erlang.binary_to_term(bin)
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp bench_meta(list, name) when is_list(list) do
    Enum.find(list, %{}, fn entry -> get(entry, "name") == name end)
  end

  defp bench_meta(_, _), do: %{}

  # Scenario names look like "Bounce/erlang (v1)" — extract benchmark + lang.
  defp parse_name(name) do
    base = String.split(name, " ", parts: 2) |> hd()

    case String.split(base, "/", parts: 2) do
      [bench, lang] -> {bench, lang}
      _ -> {nil, nil}
    end
  end

  defp ns_to_ms(nil), do: nil
  defp ns_to_ms(ns) when is_number(ns), do: Float.round(ns / 1_000_000, 3)

  defp get(m, k) when is_map(m), do: Map.get(m, k)
  defp get(_, _), do: nil

  @doc """
  Geomean of `median_ms / baseline_median_ms` across the intersection
  of benchmarks present in *both* labels (per Q12 plan decision).

  Both `label_rows` and `baseline_rows` are lists of `rows_for_run`
  output filtered down to a single label and (optionally) a single
  language.
  """
  @spec geomean_ratio([map()], [map()]) :: {float(), [String.t()]}
  def geomean_ratio(label_rows, baseline_rows) do
    label_by_bench = index_by_benchmark(label_rows)
    base_by_bench = index_by_benchmark(baseline_rows)

    intersection =
      MapSet.intersection(
        MapSet.new(Map.keys(label_by_bench)),
        MapSet.new(Map.keys(base_by_bench))
      )
      |> MapSet.to_list()
      |> Enum.sort()

    dropped =
      MapSet.union(
        MapSet.new(Map.keys(label_by_bench)),
        MapSet.new(Map.keys(base_by_bench))
      )
      |> MapSet.difference(MapSet.new(intersection))
      |> MapSet.to_list()
      |> Enum.sort()

    case intersection do
      [] ->
        {nil, dropped}

      benches ->
        sum_log =
          Enum.reduce(benches, 0.0, fn b, acc ->
            ratio = Map.fetch!(label_by_bench, b) / Map.fetch!(base_by_bench, b)
            acc + :math.log(ratio)
          end)

        gm = :math.exp(sum_log / length(benches))
        {Float.round(gm, 4), dropped}
    end
  end

  defp index_by_benchmark(rows) do
    rows
    |> Enum.filter(& &1.median_ms)
    |> Enum.group_by(& &1.benchmark)
    |> Map.new(fn {bench, rs} ->
      # If both languages present, take erlang first (matches AWFY-style
      # cross-language tables; users can pre-filter by lang if needed).
      pick =
        Enum.find(rs, &(&1.lang == "erlang")) ||
          Enum.find(rs, &(&1.lang == "elixir")) ||
          List.first(rs)

      {bench, pick.median_ms}
    end)
  end
end
