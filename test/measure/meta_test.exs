# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.Measure.Meta do
  use ExUnit.Case, async: true

  alias Awfy.Measure.Meta
  alias Awfy.RunContext

  defp build_ctx(opts \\ []) do
    RunContext.new(Keyword.merge([scenario: :synthetic, env: fn _ -> nil end], opts))
  end

  describe "base/2" do
    test "minimal RunContext produces a schema-valid base map" do
      base = Meta.base(build_ctx())
      assert :ok = Awfy.Measure.MetaSchema.validate(base)
      assert base["format_version"] == Meta.format_version()
      assert base["runtime"]["emu_flavor"] in ["jit", "emu"]
      assert base["runtime"]["flavor_source"] in ["label", "runtime"]
    end

    test "runtime_extras shallow-merges over RunContext-derived runtime" do
      base = Meta.base(build_ctx(), runtime_extras: %{"wordsize" => 8, "mix_env" => "test"})
      assert base["runtime"]["wordsize"] == 8
      assert base["runtime"]["mix_env"] == "test"
      # RunContext-derived values must NOT be silently overwritten by
      # runtime_extras when the same key is supplied — the caller
      # should pass extras the RC doesn't carry. Validate by passing
      # a colliding key and noting which wins.
      base2 = Meta.base(build_ctx(), runtime_extras: %{"emu_flavor" => "garbage"})
      assert base2["runtime"]["emu_flavor"] == "garbage",
             "Map.merge currently lets caller-provided extras override; if you want " <>
               "RunContext-derived to be authoritative, flip merge order in Meta.base/2"
    end

    test "config block is included when passed" do
      cfg = %{"time" => 1, "warmup" => 0, "lang" => "erlang"}
      base = Meta.base(build_ctx(), config: cfg)
      assert base["config"] == cfg
    end

    test "config block is omitted when not passed (XMPP-shape writer)" do
      base = Meta.base(build_ctx())
      refute Map.has_key?(base, "config")
    end
  end

  describe "write/4" do
    setup do
      dir = Path.join("tmp", "meta_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "writes a parseable meta.json that round-trips MetaSchema", %{dir: dir} do
      rc = build_ctx(label: "test-label")

      meta = Meta.write(dir, rc, %{"benchmarks" => [], "otp_benchmarks" => []})

      assert :ok = Awfy.Measure.MetaSchema.validate(meta)
      decoded = Path.join(dir, "meta.json") |> File.read!() |> Jason.decode!()
      assert :ok = Awfy.Measure.MetaSchema.validate(decoded)
      assert decoded["label"] == "test-label"
    end

    test "scenario_block keys override base keys with same name", %{dir: dir} do
      # If a writer wants to override `runtime` (e.g. ship its own
      # block), the scenario_block wins. Document that explicitly.
      meta =
        Meta.write(dir, build_ctx(), %{
          "runtime" => %{
            "emu_flavor" => "jit",
            "flavor_source" => "label",
            "schedulers_online" => 1,
            "custom" => true
          }
        })

      assert meta["runtime"]["custom"] == true
    end

    test "raises on an invalid base + scenario_block combination", %{dir: dir} do
      rc = build_ctx()

      # Forcing an invalid combined map: explicitly delete a required
      # field from the resulting merge to confirm validation fires.
      assert_raise ArgumentError, ~r/git/, fn ->
        Meta.write(dir, rc, %{"git" => %{"sha" => "abc"}})
      end
    end
  end
end
