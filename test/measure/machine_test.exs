# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.Measure.Machine do
  use ExUnit.Case, async: true

  alias Awfy.Measure.Machine

  test "describe/0 returns the meta.json machine block shape" do
    m = Machine.describe()

    assert is_binary(m["hostname"]) and byte_size(m["hostname"]) > 0
    assert is_binary(m["os"]) and byte_size(m["os"]) > 0
    assert is_binary(m["cpu"]) and byte_size(m["cpu"]) > 0
    assert is_binary(m["arch"]) and byte_size(m["arch"]) > 0
    assert is_integer(m["cores"]) and m["cores"] > 0
    assert is_binary(m["platform"]) and byte_size(m["platform"]) > 0
  end

  test "platform/0 returns a canonical <os>-<arch> string" do
    p = Machine.platform()
    assert p in known_platforms() or String.starts_with?(p, "unknown-"),
           "platform=#{inspect(p)} not in the known set"
  end

  test "describe/0's machine block passes MetaSchema's machine validation" do
    # Build a minimal meta with just enough fields + the real machine
    # probe; validate the whole thing. Catches a regression in
    # Machine.describe that omits a field MetaSchema requires.
    meta = %{
      "format_version" => 1,
      "label" => "test",
      "otp" => "28",
      "elixir" => "1.19.5",
      "timestamp" => "2026-05-13T10:00:00Z",
      "git" => %{"sha" => "abc", "dirty" => false},
      "machine" => Machine.describe()
    }

    assert :ok = Awfy.Measure.MetaSchema.validate(meta)
  end

  defp known_platforms do
    ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64",
     "windows-x86_64", "windows-arm64"]
  end
end
