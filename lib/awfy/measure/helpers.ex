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

  @doc """
  Resolve the OTP version label that goes into a run's `meta.json`
  and drives the dashboard's trend-axis grouping.

  Order of precedence:
    1. `AWFY_OTP_VERSION` env var — set by CI from the resolved
       feature release (`"20.1"`, `"21.3"`, `"master"`). Lets a
       host-orchestrated run (e.g. the XMPP path, where the
       orchestrator runs a fixed OTP but the dockerized broker is
       on a different one) record the *target* OTP, not the host's.
    2. The `releases/<release>/OTP_VERSION` file under the install
       root — the full `X.Y.Z[.P]` string for every modern OTP
       source build.
    3. `System.otp_release/0` — the major only; last-resort.
  """
  @spec otp_version_label() :: String.t()
  def otp_version_label do
    case System.get_env("AWFY_OTP_VERSION") do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        otp_version_label_from_file() || to_string(System.otp_release())
    end
  end

  @doc """
  Read the full OTP version string from the install root's
  `OTP_VERSION` file. Returns `nil` if the file is missing or empty
  so callers can chain a fallback.
  """
  @spec otp_version_label_from_file() :: String.t() | nil
  def otp_version_label_from_file do
    release = to_string(System.otp_release())
    path = Path.join([:code.root_dir() |> to_string(), "releases", release, "OTP_VERSION"])

    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> nil
          v -> v
        end

      _ ->
        nil
    end
  end

  @doc """
  Resolve the timestamp recorded under `meta["timestamp"]` and used
  as the trend chart's x-axis position. Defaults to measurement
  wall-clock, but CI overrides via `AWFY_OTP_COMMIT_TIMESTAMP` (the
  OTP commit's committer date) so old OTP benchmarks measured today
  plot at the OTP commit's actual point in time rather than
  clustering at "today" with every other catch-up run. Malformed
  env-var values warn and fall back rather than silently writing
  now — silent fallback hid a months-old config bug in a previous
  iteration.
  """
  @spec trend_timestamp() :: DateTime.t()
  def trend_timestamp do
    case System.get_env("AWFY_OTP_COMMIT_TIMESTAMP") do
      nil ->
        DateTime.utc_now()

      "" ->
        DateTime.utc_now()

      iso ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} ->
            dt

          _ ->
            IO.warn("AWFY_OTP_COMMIT_TIMESTAMP=#{inspect(iso)} is not ISO 8601, using wall-clock")
            DateTime.utc_now()
        end
    end
  end
end
