# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.Measure.MetaSchema do
  use ExUnit.Case, async: true

  alias Awfy.Measure.MetaSchema

  @valid_minimal %{
    "format_version" => 1,
    "label" => "test-label",
    "otp" => "28.5",
    "elixir" => "1.19.5",
    "timestamp" => "2026-05-13T10:00:00Z",
    "git" => %{"sha" => "deadbeef", "dirty" => false},
    "machine" => %{
      "hostname" => "host",
      "os" => "Darwin 25",
      "cpu" => "Apple M5",
      "arch" => "aarch64",
      "cores" => 10
    }
  }

  test "accepts a minimal valid meta" do
    assert :ok = MetaSchema.validate(@valid_minimal)
  end

  test "accepts an AWFY-shape meta with runtime + benchmarks block" do
    meta =
      Map.merge(@valid_minimal, %{
        "runtime" => %{"emu_flavor" => "jit", "schedulers_online" => 10},
        "config" => %{"time" => 1, "warmup" => 0, "lang" => "erlang"},
        "benchmarks" => [
          %{
            "name" => "Bounce",
            "inner_iter" => 1500,
            "languages" => %{
              "erlang" => %{
                "module" => "awfy_bounce",
                "source_sha256" => String.duplicate("a", 64),
                "verified" => true
              }
            }
          }
        ],
        "otp_benchmarks" => []
      })

    assert :ok = MetaSchema.validate(meta)
  end

  test "accepts an XMPP-shape meta with applications + xmpp blocks" do
    meta =
      Map.merge(@valid_minimal, %{
        "xmpp" => %{
          "scenario" => "dynamic_domains_pm",
          "topology" => "local",
          "users" => 1000,
          "cpu_pct" => [10.0, 11.5, 12.1],
          "mem_mb" => [360.0, 361.0, 362.0],
          "throughput" => [500, 540, 580]
        },
        "applications" => [
          %{"name" => "xmpp", "metrics" => ["cpu", "mem", "speed"]}
        ]
      })

    assert :ok = MetaSchema.validate(meta)
  end

  describe "rejects malformed input" do
    test "missing format_version" do
      {:error, [msg]} = MetaSchema.validate(Map.delete(@valid_minimal, "format_version"))
      assert msg =~ "format_version"
    end

    test "zero or negative format_version" do
      {:error, [msg]} = MetaSchema.validate(%{@valid_minimal | "format_version" => 0})
      assert msg =~ "format_version"
    end

    test "missing label" do
      {:error, errs} = MetaSchema.validate(Map.delete(@valid_minimal, "label"))
      assert Enum.any?(errs, &(&1 =~ "label"))
    end

    test "empty label" do
      {:error, errs} = MetaSchema.validate(%{@valid_minimal | "label" => ""})
      assert Enum.any?(errs, &(&1 =~ "label"))
    end

    test "malformed timestamp" do
      {:error, errs} = MetaSchema.validate(%{@valid_minimal | "timestamp" => "yesterday"})
      assert Enum.any?(errs, &(&1 =~ "timestamp"))
    end

    test "git block missing dirty" do
      {:error, errs} =
        MetaSchema.validate(%{@valid_minimal | "git" => %{"sha" => "abc"}})

      assert Enum.any?(errs, &(&1 =~ "git"))
    end

    test "git.dirty as string instead of boolean" do
      {:error, errs} =
        MetaSchema.validate(%{
          @valid_minimal
          | "git" => %{"sha" => "abc", "dirty" => "false"}
        })

      assert Enum.any?(errs, &(&1 =~ "git"))
    end

    test "machine missing cpu" do
      bad = put_in(@valid_minimal, ["machine", "cpu"], "")
      {:error, errs} = MetaSchema.validate(bad)
      assert Enum.any?(errs, &(&1 =~ "machine.cpu"))
    end

    test "machine.cores zero or negative" do
      bad = put_in(@valid_minimal, ["machine", "cores"], 0)
      {:error, errs} = MetaSchema.validate(bad)
      assert Enum.any?(errs, &(&1 =~ "machine.cores"))
    end

    test "runtime as list instead of map" do
      bad = Map.put(@valid_minimal, "runtime", ["jit"])
      {:error, errs} = MetaSchema.validate(bad)
      assert Enum.any?(errs, &(&1 =~ "runtime"))
    end

    test "non-map input" do
      {:error, [msg]} = MetaSchema.validate("not a map")
      assert msg =~ "not a map"
    end

    test "reports multiple errors in one pass" do
      bad =
        @valid_minimal
        |> Map.delete("label")
        |> Map.delete("otp")
        |> Map.put("timestamp", "garbage")

      {:error, errs} = MetaSchema.validate(bad)
      assert length(errs) >= 3
    end
  end

  describe "validate!" do
    test "returns :ok on a valid meta" do
      assert :ok = MetaSchema.validate!(@valid_minimal)
    end

    test "raises with all errors concatenated on failure" do
      bad = Map.delete(@valid_minimal, "label")

      assert_raise ArgumentError, ~r/label/, fn ->
        MetaSchema.validate!(bad)
      end
    end
  end
end
