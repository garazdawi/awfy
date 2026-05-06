# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.MnesiaTpcbRam do
  @moduledoc """
  Mnesia TPC-B (debit-credit) workload, single-node `local_only`,
  `ram_copies` storage. Models the standalone
  `lib/mnesia/examples/bench/bench.erl` driver as a Benchee
  scenario: per-iteration runs one TPC-B transaction (read +
  update a random account / teller / branch, append a history
  row); setup pre-populates the schema so transaction-loop
  latency is what's timed, not schema build.

  Schema is intentionally tiny vs upstream TPC-B sizes — 1 branch
  × 10 tellers × 1000 accounts. We're tracking BEAM-level
  regressions in Mnesia's transaction manager, lock manager, and
  allocator; absolute-throughput-vs-other-DBs comparison isn't the
  point here. Multi-node + replication are explicitly out of
  scope (Tier 2 network work, see PLAN).

  The schema directory lives under `System.tmp_dir!` so the
  benchmark doesn't pollute the working tree, and gets removed in
  `teardown/1`. Mnesia's app env `:dir` is set before
  `:mnesia.start/0` so the schema lands where we point it.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "mnesia_tpcb_ram"

  @branches 1
  @tellers_per_branch 10
  @accounts_per_branch 1000

  def inputs do
    %{"single_txn" => :ram_copies}
  end

  def setup(storage_type) do
    dir = mnesia_dir()
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))

    :mnesia.stop()
    _ = :mnesia.delete_schema([node()])
    :ok = :mnesia.create_schema([node()])
    :ok = :mnesia.start()

    create_table(:branch, [:id, :balance], storage_type)
    create_table(:teller, [:id, :balance], storage_type)
    create_table(:account, [:id, :balance], storage_type)
    create_table(:history, [:id, :teller, :account, :branch, :delta], storage_type)

    populate()

    {:ok, dir}
  end

  def run(_state) do
    branch_id = :rand.uniform(@branches)
    teller_id = :rand.uniform(@branches * @tellers_per_branch)
    account_id = :rand.uniform(@branches * @accounts_per_branch)
    delta = :rand.uniform(2000) - 1000

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        [{:account, ^account_id, a_balance}] = :mnesia.read(:account, account_id)
        :mnesia.write({:account, account_id, a_balance + delta})

        [{:teller, ^teller_id, t_balance}] = :mnesia.read(:teller, teller_id)
        :mnesia.write({:teller, teller_id, t_balance + delta})

        [{:branch, ^branch_id, b_balance}] = :mnesia.read(:branch, branch_id)
        :mnesia.write({:branch, branch_id, b_balance + delta})

        :mnesia.write(
          {:history, :erlang.unique_integer([:positive]), teller_id, account_id, branch_id,
           delta}
        )

        :ok
      end)

    :ok
  end

  def teardown({:ok, dir}) do
    :mnesia.stop()
    _ = :mnesia.delete_schema([node()])
    File.rm_rf!(dir)
    :ok
  end

  defp create_table(name, attrs, storage_type) do
    {:atomic, :ok} =
      :mnesia.create_table(
        name,
        attributes: attrs,
        storage_properties: [{storage_type, [node()]}]
      )

    :ok = :mnesia.add_table_index(name, hd(tl(attrs)))
  rescue
    # add_table_index raises if the index already exists (re-running
    # the benchmark in the same VM during local development) — tolerate.
    _ -> :ok
  end

  defp populate do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        for b <- 1..@branches, do: :mnesia.write({:branch, b, 0})

        for t <- 1..(@branches * @tellers_per_branch),
            do: :mnesia.write({:teller, t, 0})

        for a <- 1..(@branches * @accounts_per_branch),
            do: :mnesia.write({:account, a, 0})

        :ok
      end)

    :ok
  end

  defp mnesia_dir do
    Path.join(
      System.tmp_dir!(),
      "awfy_mnesia_tpcb_ram_#{:erlang.unique_integer([:positive])}"
    )
  end
end
