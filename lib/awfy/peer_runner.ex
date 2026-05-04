# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.PeerRunner do
  @moduledoc """
  Runs a function on a fresh BEAM peer node, returns the result, stops
  the peer. Used by `Awfy.BencheeRunner` to give every benchmark an
  isolated VM — see `ISOLATION_POLICY.md` at the repo root.

  ## Why

  Cross-benchmark interference (Mnesia leaving its supervisor tree
  warm, crypto NIFs initialising once, ETS table-type lazy-init,
  etc.) leaks "warmup" between scenarios in subtle ways that depend
  on benchmark execution order. Running each benchmark in a fresh
  peer eliminates that variance: every measurement starts from a
  cold BEAM, and any warmup the benchmark needs is its explicit
  responsibility (Benchee `:warmup` window or `:before_scenario`).

  ## Cost

  ~300-500 ms per peer startup. With ~50 benchmarks across the
  full plan, that's ~15-25 s added per platform leg, easily lost in
  the cron noise. See ISOLATION_POLICY.md for the cost analysis.
  """

  @doc """
  Start a peer, call `fun` on it, stop the peer. Returns whatever
  `fun` returned. Raises on RPC error or peer-startup failure.

  `name_hint` is used to build a human-readable peer node name so
  crash dumps can identify which benchmark a peer belonged to.

  Code paths are inherited from the controller via `-pa`, so any
  module already loaded on the controller can be loaded on the peer
  without further setup.

  Communication uses `:standard_io` (no Erlang distribution) so
  peers don't need `epmd` or DNS — important for hermetic CI runs
  inside Docker containers where distribution would require extra
  network setup. Calls go through `:peer.call/4`, which serialises
  args (including funs) over the stdio pipe.

  ### OTP < 25 fallback

  `:peer` landed in OTP 25. On OTP 24 we fall back to the legacy
  `:slave` module (driven over Erlang distribution via `:rpc.call/4`
  and dynamically-started `:net_kernel`). The numbers are still
  same-OTP isolated; only the transport differs. Distribution
  requires `epmd` to be running, which OTP boots on demand for
  short-name nodes.
  """
  @spec run((-> result), String.t()) :: result when result: any()
  def run(fun, name_hint) when is_function(fun, 0) and is_binary(name_hint) do
    case start_peer(name_hint) do
      {:peer, pid} ->
        try do
          :peer.call(pid, :erlang, :apply, [fun, []], :infinity)
        after
          :peer.stop(pid)
        end

      {:slave, node} ->
        try do
          case :rpc.call(node, :erlang, :apply, [fun, []], :infinity) do
            {:badrpc, reason} -> raise "rpc to slave #{inspect(node)} failed: #{inspect(reason)}"
            result -> result
          end
        after
          # apply/3 to keep `:slave` out of the compiler's deprecation
          # warning surface — the use is intentional (OTP 24 has no peer).
          apply(:slave, :stop, [node])
        end
    end
  end

  @doc """
  Variant of `run/2` that takes an MFA tuple instead of a closure.
  Useful when the caller's module isn't on the peer's code path
  (e.g. ExUnit test modules) — closures defined in such modules
  can't be deserialised on the peer, but a `module:function/arity`
  reference to a module that *is* on the path always works.

  Production benchmark code uses `run/2` with closures defined in
  `Awfy.BencheeRunner` (which IS on the path). This variant is
  intended for tests and any future caller in the same boat.
  """
  @spec run_mfa(module(), atom(), [any()], String.t()) :: any()
  def run_mfa(module, function, args, name_hint)
      when is_atom(module) and is_atom(function) and is_list(args) and is_binary(name_hint) do
    case start_peer(name_hint) do
      {:peer, pid} ->
        try do
          :peer.call(pid, module, function, args, :infinity)
        after
          :peer.stop(pid)
        end

      {:slave, node} ->
        try do
          case :rpc.call(node, module, function, args, :infinity) do
            {:badrpc, reason} -> raise "rpc to slave #{inspect(node)} failed: #{inspect(reason)}"
            result -> result
          end
        after
          # apply/3 to keep `:slave` out of the compiler's deprecation
          # warning surface — the use is intentional (OTP 24 has no peer).
          apply(:slave, :stop, [node])
        end
    end
  end

  # Pick `:peer` (OTP 25+) or `:slave` (OTP 24) based on what's
  # available at runtime. The legacy `:slave` path needs Erlang
  # distribution; we lazily start `:net_kernel` in shortname mode
  # the first time we need it (OTP boots epmd on demand).
  defp start_peer(name_hint) do
    safe_hint = String.replace(name_hint, ~r/[^a-zA-Z0-9_]/, "_")
    base = "awfy_#{safe_hint}_#{:erlang.unique_integer([:positive])}"

    if Code.ensure_loaded?(:peer) do
      code_path_args =
        :code.get_path()
        |> Enum.flat_map(fn path -> [~c"-pa", path] end)

      {:ok, pid, _node} =
        :peer.start_link(%{
          name: String.to_charlist(base),
          args: code_path_args,
          connection: :standard_io
        })

      {:peer, pid}
    else
      ensure_distribution_started()
      {:ok, host} = :inet.gethostname()
      slave_name = String.to_atom(base)

      code_path_arg =
        :code.get_path()
        |> Enum.map(&List.to_string/1)
        |> Enum.map_join(" ", &"-pa #{&1}")

      # apply/3: see comment on :slave.stop/1 above.
      {:ok, node} = apply(:slave, :start_link, [host, slave_name, String.to_charlist(code_path_arg)])
      {:slave, node}
    end
  end

  defp ensure_distribution_started do
    case :erlang.node() do
      :nonode@nohost ->
        ctrl_name = String.to_atom("awfy_ctrl_#{:erlang.unique_integer([:positive])}")
        {:ok, _} = :net_kernel.start([ctrl_name, :shortnames])
        :ok

      _ ->
        :ok
    end
  end
end
