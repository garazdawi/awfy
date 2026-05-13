# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.MetricSource do
  use ExUnit.Case, async: true

  alias Awfy.Xmpp.DockerStats

  test "DockerStats declares it implements Awfy.MetricSource" do
    behaviours =
      DockerStats.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Awfy.MetricSource in behaviours
  end

  test "DockerStats.supported_metrics/1 returns cpu_pct + mem_mb" do
    assert DockerStats.supported_metrics(["awfy-mongooseim-1"]) == [:cpu_pct, :mem_mb]
  end
end
