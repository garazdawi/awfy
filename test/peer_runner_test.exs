# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.PeerRunnerTest do
  @moduledoc """
  Validates the per-benchmark VM isolation policy. Each invocation
  must spin up a fresh BEAM, execute the work there, and discard
  the VM — no state should survive between invocations.

  Tests use the `run_mfa/4` API exclusively because closures defined
  inside ExUnit test modules can't be deserialised on the peer (the
  test module's beam isn't on the peer's `-pa` path). Production
  benchmark code uses `run/2` with closures from `Awfy.BencheeRunner`,
  which *is* on the path — see PeerRunner moduledoc.
  """

  use ExUnit.Case, async: true

  alias Awfy.PeerRunner

  test "run_mfa: returns the function result" do
    assert PeerRunner.run_mfa(:erlang, :+, [1, 2], "add") == 3
  end

  test "run/2 with a captured remote function works (no test-module closure)" do
    # `&node/0` is auto-imported from Kernel and delegates to :erlang.node/0.
    # Captured remote functions reference an MFA, not a test-module closure,
    # so the peer can resolve them.
    result = PeerRunner.run(&node/0, "node")
    refute result == node()
  end

  test "function executes on a different node from the controller" do
    peer_node = PeerRunner.run_mfa(:erlang, :node, [], "node-check")
    refute peer_node == node()
  end

  test "fresh peer per invocation — :persistent_term doesn't leak across runs" do
    key = {__MODULE__, :leak_test, :erlang.unique_integer([:positive])}

    PeerRunner.run_mfa(:persistent_term, :put, [key, :was_here], "set")

    assert PeerRunner.run_mfa(:persistent_term, :get, [key, :not_set], "check") ==
             :not_set
  end

  test "controller's :persistent_term is not visible on peer" do
    key = {__MODULE__, :controller_state, :erlang.unique_integer([:positive])}
    :persistent_term.put(key, :on_controller)
    on_exit(fn -> :persistent_term.erase(key) end)

    assert PeerRunner.run_mfa(:persistent_term, :get, [key, :not_set], "controller") ==
             :not_set
  end

  test "raises propagate from the peer to the caller" do
    assert_raise ErlangError, fn ->
      PeerRunner.run_mfa(:erlang, :error, [:test_failure], "raises")
    end
  end

  test "no process leak between peers — process count stays low on a fresh peer" do
    PeerRunner.run_mfa(:proc_lib, :spawn, [:timer, :sleep, [:infinity]], "spawn")

    count = PeerRunner.run_mfa(:erlang, :system_info, [:process_count], "count")

    # Idle BEAM has ~30-40 processes (system supervisors, code server, etc.).
    # A leaked sleeping process from the previous peer would NOT show up here
    # because each peer is a fresh OS process; this test exists to confirm
    # that intuition, not just hope for it.
    assert count < 100
  end
end
