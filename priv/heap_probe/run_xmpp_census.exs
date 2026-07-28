# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
# Reuse the awfy XMPP orchestration (Topology + Amoc) to bring up the
# MongooseIM + Amoc rig and start a scenario with REAL connected clients
# (online c2s sessions — the thing a local box can't do because the Amoc
# rig has to be built from source, which hits the vz/apt corruption). Then
# attach heap_probe to awfy-mongooseim-1 and census the internal send-shape
# DURING the message phase. This is #75 Stage 0's definitive XMPP fan-out
# data point.
alias Awfy.Xmpp.{ScenarioConfig, Topology, Amoc}

scenario = System.get_env("HP_SCENARIO", "dynamic_domains_pm")
{:ok, config} = ScenarioConfig.load(scenario, :local)
IO.puts("[hp] scenario=#{config.scenario} users=#{config.users} domains=#{config.domains}")

{:ok, state} = Topology.deploy(:local, config)

try do
  :ok = Topology.wait_ready(state, 300_000)
  IO.puts("[hp] broker ready; starting scenario (clients connect → online sessions)")
  :ok = Amoc.start_scenario(state, config)

  wait = config.pre_sampling_wait_s + 15
  IO.puts("[hp] ramp-up: sleeping #{wait}s so sessions connect + messages flow")
  Process.sleep(wait * 1000)

  IO.puts("[hp] attaching heap_probe + censusing awfy-mongooseim-1")
  {out, code} = System.cmd("bash", ["priv/heap_probe/attach_and_census.sh"], stderr_to_stdout: true)
  IO.puts(out)
  IO.puts("[hp] attach_and_census exit=#{code}")
after
  IO.puts("[hp] teardown")
  Topology.teardown(state)
end
