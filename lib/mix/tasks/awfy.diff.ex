defmodule Mix.Tasks.Awfy.Diff do
  @shortdoc "Print a per-benchmark delta between two saved labels"
  @moduledoc """
  Console-only delta between two `mix awfy.measure` runs. Prints
  one line per benchmark with both labels' median runtime in
  milliseconds and the percentage delta, plus a geomean row at the
  bottom answering "is this PR a regression overall?"

  ## Usage

      mix awfy.diff before after
      mix awfy.diff before after --lang erlang
      mix awfy.diff before after --benchmarks Bounce,Sieve

  Both labels must be present under `results/`. By convention the
  *first* label is the baseline (changes shown as `+X% slower` /
  `-X% faster` relative to it).
  """

  use Mix.Task

  @switches [
    lang: :string,
    benchmarks: :string,
    out: :string
  ]

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    case positional do
      [baseline_label, target_label] ->
        do_diff(baseline_label, target_label, opts)

      _ ->
        Mix.raise("usage: mix awfy.diff BASELINE_LABEL TARGET_LABEL [--lang erlang|elixir]")
    end
  end

  defp do_diff(baseline, target, opts) do
    out_root = opts[:out] || "results"
    data = Awfy.Compare.Data.load(out_root)

    labels_present = Enum.map(data.runs, & &1.label) |> MapSet.new()

    Enum.each([baseline, target], fn l ->
      unless MapSet.member?(labels_present, l) do
        Mix.raise("label not found in #{out_root}/: #{l}")
      end
    end)

    lang_filter = parse_lang(opts[:lang])
    bench_filter = parse_csv(opts[:benchmarks])

    base_rows = filter_rows(data.rows, baseline, lang_filter, bench_filter)
    target_rows = filter_rows(data.rows, target, lang_filter, bench_filter)

    print_table(baseline, target, base_rows, target_rows)
  end

  defp parse_lang(nil), do: nil
  defp parse_lang(s), do: s

  defp parse_csv(nil), do: nil
  defp parse_csv(s), do: String.split(s, ",", trim: true)

  defp filter_rows(rows, label, lang, benches) do
    rows
    |> Enum.filter(&(&1.label == label))
    |> then(fn rs ->
      if lang, do: Enum.filter(rs, &(&1.lang == lang)), else: rs
    end)
    |> then(fn rs ->
      if benches, do: Enum.filter(rs, &(&1.benchmark in benches)), else: rs
    end)
  end

  defp print_table(baseline, target, base_rows, target_rows) do
    by_key_base = index_by_key(base_rows)
    by_key_target = index_by_key(target_rows)

    keys =
      MapSet.intersection(
        MapSet.new(Map.keys(by_key_base)),
        MapSet.new(Map.keys(by_key_target))
      )
      |> MapSet.to_list()
      |> Enum.sort()

    only_base = Map.keys(by_key_base) -- keys
    only_target = Map.keys(by_key_target) -- keys

    label_w = max(8, max(String.length(baseline), String.length(target)))
    name_col = "Benchmark/lang" |> String.pad_trailing(28)

    header =
      [
        name_col,
        String.pad_leading("#{baseline} (ms)", label_w + 6),
        String.pad_leading("#{target} (ms)", label_w + 6),
        String.pad_leading("Δ", 12)
      ]
      |> Enum.join("  ")

    sep = String.duplicate("-", String.length(header))
    IO.puts(header)
    IO.puts(sep)

    ratios =
      Enum.map(keys, fn key ->
        b = by_key_base[key]
        t = by_key_target[key]
        ratio = t / b
        pct = (ratio - 1.0) * 100

        IO.puts(
          [
            String.pad_trailing(key, 28),
            String.pad_leading(fmt(b), label_w + 6),
            String.pad_leading(fmt(t), label_w + 6),
            String.pad_leading(fmt_delta(pct), 12)
          ]
          |> Enum.join("  ")
        )

        ratio
      end)

    IO.puts(sep)

    if ratios != [] do
      sum_log = Enum.reduce(ratios, 0.0, &(&1 |> :math.log() |> Kernel.+(&2)))
      gm = :math.exp(sum_log / length(ratios))
      gm_pct = (gm - 1.0) * 100

      IO.puts(
        [
          String.pad_trailing("Geomean (n=#{length(ratios)})", 28),
          String.pad_leading("", label_w + 6),
          String.pad_leading("", label_w + 6),
          String.pad_leading(fmt_delta(gm_pct), 12)
        ]
        |> Enum.join("  ")
      )
    end

    if only_base != [] or only_target != [] do
      IO.puts("")
      if only_base != [], do: IO.puts("only in #{baseline}: #{Enum.join(only_base, ", ")}")
      if only_target != [], do: IO.puts("only in #{target}: #{Enum.join(only_target, ", ")}")
    end
  end

  defp index_by_key(rows) do
    rows
    |> Enum.filter(& &1.median_ms)
    |> Map.new(fn r -> {"#{r.benchmark}/#{r.lang}", r.median_ms} end)
  end

  defp fmt(nil), do: "—"
  defp fmt(x) when is_float(x), do: :io_lib.format("~7.2f", [x]) |> IO.iodata_to_binary()
  defp fmt(x), do: to_string(x)

  defp fmt_delta(pct) when pct > 0,
    do: :io_lib.format("+~5.1f%", [pct]) |> IO.iodata_to_binary()

  defp fmt_delta(pct),
    do: :io_lib.format("~6.1f%", [pct]) |> IO.iodata_to_binary()
end
