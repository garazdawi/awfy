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
  """
  @spec run((-> result), String.t()) :: result when result: any()
  def run(fun, name_hint) when is_function(fun, 0) and is_binary(name_hint) do
    {:ok, pid, _node} = start_peer(name_hint)

    try do
      :peer.call(pid, :erlang, :apply, [fun, []], :infinity)
    after
      :peer.stop(pid)
    end
  end

  defp start_peer(name_hint) do
    safe_hint = String.replace(name_hint, ~r/[^a-zA-Z0-9_]/, "_")

    name =
      String.to_charlist(
        "awfy_#{safe_hint}_#{:erlang.unique_integer([:positive])}"
      )

    code_path_args =
      :code.get_path()
      |> Enum.flat_map(fn path -> [~c"-pa", path] end)

    :peer.start_link(%{
      name: name,
      args: code_path_args,
      connection: :standard_io
    })
  end
end
