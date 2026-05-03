# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Measure.Helpers do
  @moduledoc """
  Pure helpers used by `Mix.Tasks.Awfy.Measure`. Extracted so the
  label/run-dir naming and option parsing can be unit-tested without
  spinning up the full Mix task — these strings end up baked into
  archived run directories on `gh-pages`, so getting the format
  wrong is hard to roll back.
  """

  @doc """
  Format a UTC datetime as the basic-ISO timestamp the run-dir
  naming convention uses (`YYYYMMDDTHHMM`, 13 characters).
  """
  @spec basic_ts(DateTime.t()) :: String.t()
  def basic_ts(%DateTime{} = dt) do
    dt
    |> DateTime.to_iso8601(:basic)
    |> String.replace("Z", "")
    |> binary_part(0, 13)
  end

  @doc """
  Build a run label. Clean trees use the SHA verbatim so labels
  collide deterministically across re-runs of the same commit; dirty
  trees get the timestamp appended so concurrent dirty runs don't
  trample each other on disk.
  """
  @spec auto_label(String.t(), boolean(), DateTime.t()) :: String.t()
  def auto_label(sha, false, _now), do: sha
  def auto_label(sha, true, %DateTime{} = now), do: "#{sha}-dirty_#{basic_ts(now)}"

  @doc """
  Build the run directory name under `out_root`. Format:

      <ts>_otp<release>_elixir<version>_<label>

  This format is parsed by `Mix.Tasks.Awfy.Fill` to discover what's
  already on `gh-pages`, so it must match `parse_run_dir/1` there.
  """
  @spec run_dir(String.t(), String.t(), DateTime.t(), String.t(), String.t()) :: String.t()
  def run_dir(out_root, label, %DateTime{} = now, otp_release, elixir_version) do
    Path.join(out_root, "#{basic_ts(now)}_otp#{otp_release}_elixir#{elixir_version}_#{label}")
  end

  @doc """
  Parse the `--lang` flag. Raises `Mix.Error` on unknown values to
  match Mix conventions; tests assert on the raise.
  """
  @spec parse_lang(String.t() | nil) :: :both | :erlang | :elixir
  def parse_lang(nil), do: :both
  def parse_lang("both"), do: :both
  def parse_lang("erlang"), do: :erlang
  def parse_lang("elixir"), do: :elixir
  def parse_lang(other), do: Mix.raise("unknown --lang: #{inspect(other)}")

  @spec parse_benchmarks(String.t() | nil) :: [String.t()] | nil
  def parse_benchmarks(nil), do: nil
  def parse_benchmarks(s), do: String.split(s, ",", trim: true)

  @spec filter_lang([{atom(), module()}], :both | :erlang | :elixir) :: [{atom(), module()}]
  def filter_lang(entries, :both), do: entries
  def filter_lang(entries, lang), do: Enum.filter(entries, fn {l, _} -> l == lang end)

  @spec filter_benchmarks([{atom(), module()}], [String.t()] | nil) :: [{atom(), module()}]
  def filter_benchmarks(entries, nil), do: entries

  def filter_benchmarks(entries, names) do
    set = MapSet.new(names)
    Enum.filter(entries, fn entry -> MapSet.member?(set, Awfy.name(entry)) end)
  end

  @doc """
  Coerce `:erlang.system_info(:logical_processors)` into something
  JSON-serializable. The BIF returns `:unknown` on platforms where
  the count can't be determined; `meta.json` uses `null` for those.
  """
  @spec safe_integer(integer() | :unknown | any()) :: integer() | nil
  def safe_integer(:unknown), do: nil
  def safe_integer(n) when is_integer(n), do: n
  def safe_integer(_), do: nil

  @spec maybe_put(keyword(), atom(), any()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
