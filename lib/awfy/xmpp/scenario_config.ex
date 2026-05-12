# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Xmpp.ScenarioConfig do
  @moduledoc """
  Reads `priv/scenario-config/<scenario>.<topology>.json` and
  exposes the per-topology parameters as a typed struct. Single
  source of truth for "what numbers do we run `dynamic_domains_pm`
  at on `:local` vs `:aws_clt`?" — same set of knobs in both
  places, only the values differ.
  """

  @enforce_keys [
    :scenario,
    :topology,
    :users,
    :domains,
    :interarrival_ms,
    :message_count,
    :message_interval_s,
    :delay_before_s,
    :delay_after_s,
    :measurement_duration_s,
    :pre_sampling_wait_s
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          scenario: String.t(),
          topology: String.t(),
          users: pos_integer(),
          domains: pos_integer(),
          interarrival_ms: non_neg_integer(),
          message_count: non_neg_integer(),
          message_interval_s: pos_integer(),
          # Sent to the scenario as AMOC_DELAY_BEFORE_SENDING_MESSAGES —
          # how long each user waits after connecting before sending its
          # first message. Per-user value, controls when traffic starts
          # at the user level.
          delay_before_s: non_neg_integer(),
          delay_after_s: non_neg_integer(),
          measurement_duration_s: pos_integer(),
          # Used by Awfy.Xmpp.Runner — how long to wait *after* starting
          # the scenario before opening the sampling window. Distinct
          # from delay_before_s: this skips the spawn+connect ramp so
          # the throughput series captures steady state rather than the
          # ramp-up. Tune per-topology to match expected ramp duration.
          pre_sampling_wait_s: non_neg_integer()
        }

  @priv_dir Path.expand("../../../priv/scenario-config", __DIR__)

  @doc "Load `<scenario>.<topology>.json` from priv/scenario-config/."
  @spec load(String.t(), :local | :aws_clt) :: {:ok, t()} | {:error, term()}
  def load(scenario, topology) when is_binary(scenario) and topology in [:local, :aws_clt] do
    path = Path.join(@priv_dir, "#{scenario}.#{topology}.json")

    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      build(json)
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:invalid_json, path, e}}
      {:error, :enoent} -> {:error, {:config_not_found, path}}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp build(%{} = json) do
    {:ok,
     %__MODULE__{
       scenario: Map.fetch!(json, "scenario"),
       topology: Map.fetch!(json, "topology"),
       users: Map.fetch!(json, "users"),
       domains: Map.fetch!(json, "domains"),
       interarrival_ms: Map.fetch!(json, "interarrival_ms"),
       message_count: Map.fetch!(json, "message_count"),
       message_interval_s: Map.fetch!(json, "message_interval_s"),
       delay_before_s: Map.fetch!(json, "delay_before_s"),
       delay_after_s: Map.fetch!(json, "delay_after_s"),
       measurement_duration_s: Map.fetch!(json, "measurement_duration_s"),
       pre_sampling_wait_s: Map.fetch!(json, "pre_sampling_wait_s")
     }}
  rescue
    e in KeyError ->
      {:error, {:missing_key, e.key}}
  end

  @doc """
  Render the config as a flat env-var map for the compose file
  (matches the variable names in priv/topology/local.compose.yml).
  """
  @spec to_env(t()) :: %{String.t() => String.t()}
  def to_env(%__MODULE__{} = c) do
    %{
      "USERS" => Integer.to_string(c.users),
      "DOMAINS" => Integer.to_string(c.domains),
      "INTERARRIVAL_MS" => Integer.to_string(c.interarrival_ms),
      "MESSAGE_COUNT" => Integer.to_string(c.message_count),
      "MESSAGE_INTERVAL_S" => Integer.to_string(c.message_interval_s),
      "DELAY_BEFORE_S" => Integer.to_string(c.delay_before_s),
      "DELAY_AFTER_S" => Integer.to_string(c.delay_after_s)
    }
  end
end
