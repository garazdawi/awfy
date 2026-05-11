# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Runner do
  @moduledoc """
  Host-side caller for the target-Elixir bundle.

  Phase 2 of `PLAN/TARGET_ELIXIR_RUNNER_PLAN.md` introduces this as
  the bundle-path replacement for `Awfy.TargetRunner`. Phase 3
  flips `Awfy.BencheeRunner`'s dispatch to use it by default for
  pre-OTP-24 measurements; until then, it's selected via
  `mix awfy.measure --runner=bundle`.

  The host calls into a pre-built `target_bundle.tar.gz` extracted
  on-disk: a self-contained Elixir runtime + vendored Benchee +
  pre-compiled `Awfy.TargetRunner` script. Per benchmark, this
  module shells out to `erl -s 'Elixir.Awfy.TargetRunner' main` and
  reads back the `.benchee` file that `apps/awfy_target_runner/`
  writes — `binary_to_term/1` round-trips the suite cleanly because
  the host and target Benchee versions are pinned to the same major
  (1.5).

  ## Why shell out, same reasoning as the legacy harness

  Same as `Awfy.TargetRunner`'s moduledoc: shell-out via
  `System.cmd/3` keeps the controller and target VM ETF-decoupled,
  makes the harness invocation trivially swappable, and the
  per-benchmark fork cost (~30-50 ms on Linux) is paid outside the
  timed window — Benchee on the target uses
  `:erlang.monotonic_time/1` for the actual measurement.

  ## Configuration

    * `AWFY_TARGET_ERL`    — path to the target `erl` binary.
      Required.
    * `AWFY_TARGET_BUNDLE` — path to the extracted bundle directory
      (one with `bin/`, `lib/elixir/ebin/`, etc.). Required for
      bundle mode.

  Both can be passed as `:erl` / `:bundle_dir` options to
  `run/4` instead, which is what the BencheeRunner dispatch uses
  in Phase 3 once env-var sniffing goes away.
  """

  @type module_name :: atom() | String.t()

  @type opts :: [
          erl: String.t() | nil,
          bundle_dir: String.t() | nil,
          time: number(),
          warmup: number(),
          out: String.t(),
          extra_paths: [String.t()],
          extra_env: [{String.t(), String.t()}]
        ]

  @doc """
  Run one benchmark against the target bundle. Returns the loaded
  `%Benchee.Suite{}` on success, or `{:error, reason}` if the env
  isn't configured or the target erl exits non-zero.

  Defaults: `time: 5`, `warmup: 2`, `out: <tmp>/awfy-runner-<n>.benchee`.
  """
  @spec run(String.t() | nil, module_name(), pos_integer(), opts()) ::
          {:ok, Benchee.Suite.t()} | {:error, term()}
  def run(bundle_dir, module, inner_iter, opts \\ []) do
    bundle_dir = bundle_dir || opts[:bundle_dir] || System.get_env("AWFY_TARGET_BUNDLE")
    erl = opts[:erl] || System.get_env("AWFY_TARGET_ERL")

    cond do
      erl in [nil, ""] ->
        {:error, :no_target_erl}

      bundle_dir in [nil, ""] ->
        {:error, :no_target_bundle}

      not File.exists?(erl) ->
        {:error, {:erl_not_found, erl}}

      not File.dir?(bundle_dir) ->
        {:error, {:bundle_not_found, bundle_dir}}

      true ->
        case bundle_runner_beam(bundle_dir) do
          {:ok, _} -> do_run(bundle_dir, erl, module, inner_iter, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Build the argv list `Awfy.Runner` would pass to `System.cmd/3`
  for a given configuration. Public so callers (and tests) can
  inspect what the bundle invocation looks like without actually
  spawning erl.
  """
  @spec argv_for(String.t(), module_name(), pos_integer(), opts()) :: [String.t()]
  def argv_for(bundle_dir, module, inner_iter, opts \\ []) do
    time = Keyword.get(opts, :time, 5)
    warmup = Keyword.get(opts, :warmup, 2)
    out = Keyword.get(opts, :out, default_out_path())

    bundle_argv_prefix(bundle_dir, opts) ++
      [
        module_arg(module),
        Integer.to_string(inner_iter),
        seconds_arg(time),
        seconds_arg(warmup),
        out
      ]
  end

  @doc """
  Run one OtpBenchmarks family against the target bundle. Returns
  the loaded `%Benchee.Suite{}` on success, `{:error, reason}` on
  any failure (env not configured, target erl exits non-zero,
  bundle didn't write a suite file, etc.).

  Mirror of `run/4` for the multi-input scenario shape — see the
  AWFY-shape branch's docstring for the env-var contract; the only
  argv differences are the leading `--otp-benchmarks` flag and the
  absence of the `inner_iter` positional. Defaults: `time: 3`,
  `warmup: 1`.
  """
  @spec run_otp_family(String.t() | nil, module(), opts()) ::
          {:ok, Benchee.Suite.t()} | {:error, term()}
  def run_otp_family(bundle_dir, family, opts \\ []) when is_atom(family) do
    bundle_dir = bundle_dir || opts[:bundle_dir] || System.get_env("AWFY_TARGET_BUNDLE")
    erl = opts[:erl] || System.get_env("AWFY_TARGET_ERL")

    cond do
      erl in [nil, ""] ->
        {:error, :no_target_erl}

      bundle_dir in [nil, ""] ->
        {:error, :no_target_bundle}

      not File.exists?(erl) ->
        {:error, {:erl_not_found, erl}}

      not File.dir?(bundle_dir) ->
        {:error, {:bundle_not_found, bundle_dir}}

      true ->
        case bundle_runner_beam(bundle_dir) do
          {:ok, _} -> do_run_otp_family(bundle_dir, erl, family, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  argv for `run_otp_family/3`. Public for inspection / testing
  symmetric with `argv_for/4`.
  """
  @spec otp_argv_for(String.t(), module(), opts()) :: [String.t()]
  def otp_argv_for(bundle_dir, family, opts \\ []) when is_atom(family) do
    time = Keyword.get(opts, :time, 3)
    warmup = Keyword.get(opts, :warmup, 1)
    out = Keyword.get(opts, :out, default_out_path())

    bundle_argv_prefix(bundle_dir, opts) ++
      [
        "--otp-benchmarks",
        module_arg(family),
        seconds_arg(time),
        seconds_arg(warmup),
        out
      ]
  end

  defp bundle_argv_prefix(bundle_dir, opts) do
    extra_paths = Keyword.get(opts, :extra_paths, [])

    pa_flags =
      (bundle_ebins(bundle_dir) ++ extra_paths)
      |> Enum.flat_map(fn path -> ["-pa", path] end)

    pa_flags ++
      [
        "-noshell",
        "-s",
        "Elixir.Awfy.TargetRunner",
        "main",
        # `-extra` (modern erl) and `--` (older erl) both route the
        # tail into `:init.get_plain_arguments/0`. Use `-extra`
        # explicitly so older OTP 19/20 emulators that treated `--`
        # ambiguously stay on the unambiguous path.
        "-extra"
      ]
  end

  defp do_run(bundle_dir, erl, module, inner_iter, opts) do
    out = Keyword.get_lazy(opts, :out, &default_out_path/0)
    File.mkdir_p!(Path.dirname(out))
    opts = Keyword.put(opts, :out, out)

    args = argv_for(bundle_dir, module, inner_iter, opts)
    env = Keyword.get(opts, :extra_env, [])
    log_erl_invocation(erl, args, bundle_dir)

    case System.cmd(erl, args, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        decode_suite(out)

      {output, status} ->
        File.rm(out)
        {:error, {:erl_exit, status, output}}
    end
  end

  defp do_run_otp_family(bundle_dir, erl, family, opts) do
    out = Keyword.get_lazy(opts, :out, &default_out_path/0)
    File.mkdir_p!(Path.dirname(out))
    opts = Keyword.put(opts, :out, out)

    args = otp_argv_for(bundle_dir, family, opts)
    env = Keyword.get(opts, :extra_env, [])
    log_erl_invocation(erl, args, bundle_dir)

    case System.cmd(erl, args, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        decode_suite(out)

      {output, status} ->
        File.rm(out)
        {:error, {:erl_exit, status, output}}
    end
  end

  # One-time diagnostic per process: log the first erl invocation so a
  # missing `-pa` or mis-quoted bundle path is visible in CI without
  # spamming every per-scenario call. Gated on a process-dictionary
  # flag so the per-bundle-dir line lands once even when called from
  # the AWFY+OTP entry-point pair within the same VM.
  defp log_erl_invocation(erl, args, bundle_dir) do
    if Process.get(:awfy_runner_logged_invocation) != true do
      Process.put(:awfy_runner_logged_invocation, true)

      pa_paths =
        args
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.flat_map(fn
          ["-pa", p] -> [p]
          _ -> []
        end)

      IO.puts(:stderr, "[bundle] erl=#{erl}")
      IO.puts(:stderr, "[bundle] bundle_dir=#{bundle_dir}")
      IO.puts(:stderr, "[bundle] -pa paths (#{length(pa_paths)}):")
      Enum.each(pa_paths, &IO.puts(:stderr, "  #{&1}"))
    end
  end

  defp decode_suite(out) do
    case File.read(out) do
      {:ok, bin} ->
        File.rm(out)

        try do
          {:ok, :erlang.binary_to_term(bin)}
        rescue
          e -> {:error, {:corrupt_suite, Exception.message(e)}}
        end

      {:error, reason} ->
        # Target wrote nothing. Common for "no compatible scenarios"
        # cases where the runner returned without saving — surface
        # as a soft failure so the caller can skip rather than abort.
        {:error, {:no_suite_file, reason}}
    end
  end

  defp bundle_ebins(bundle_dir) do
    Path.wildcard(Path.join(bundle_dir, "lib/*/ebin"))
  end

  # Pre-flight: the canonical TargetRunner beam must be present under
  # `lib/awfy_target_runner/ebin/`. A broken bundle layout (tar extract
  # not stripping the top `bundle/` prefix; sub-app missing from the
  # build; corrupted artifact) would otherwise let `erl -s
  # Elixir.Awfy.TargetRunner main` boot, hit `undef`, and unwind into
  # an `:erl_exit` per scenario that callers tend to log-and-skip.
  # Returning a distinct error tag here lets the suite-level caller
  # raise (it's a setup failure, not a per-benchmark crash).
  defp bundle_runner_beam(bundle_dir) do
    path =
      Path.join([
        bundle_dir,
        "lib",
        "awfy_target_runner",
        "ebin",
        "Elixir.Awfy.TargetRunner.beam"
      ])

    if File.exists?(path) do
      {:ok, path}
    else
      ebins = bundle_ebins(bundle_dir)
      {:error, {:bundle_missing_runner, %{expected: path, ebins_found: ebins}}}
    end
  end

  defp default_out_path do
    Path.join(
      System.tmp_dir!(),
      "awfy-runner-#{System.unique_integer([:positive])}.benchee"
    )
  end

  # Module atoms render as either "Elixir.Mod" (Elixir) or "mod"
  # (Erlang) via `Atom.to_string/1`. The target's
  # `Awfy.TargetRunner.parse_args/1` calls `String.to_atom/1`, so
  # we must hand it the exact form atom-round-trip needs to land on
  # the same module.
  defp module_arg(module) when is_atom(module), do: Atom.to_string(module)
  defp module_arg(module) when is_binary(module), do: module

  defp seconds_arg(n) when is_integer(n), do: Integer.to_string(n)
  defp seconds_arg(n) when is_float(n), do: Float.to_string(n)
end
