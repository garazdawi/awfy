# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Fill.ShellTestHelper do
  @moduledoc """
  Shared harness for the two `bin/*` shell-script tests under
  `test/fill/`. Both `resolve_fill_needs_test.exs` and
  `expand_otp_refs_test.exs` need to:

    * mint a per-test temp directory under `System.tmp_dir!()`,
    * prepend it to `PATH` so PATH-stubbed binaries take priority,
    * clean up on exit,
    * write `#!/usr/bin/env bash` stubs with the executable bit set.

  Keeping the stub bodies in the test files themselves — the harness
  just wires them up.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Create a per-test temp dir, register cleanup, return the path.
  Caller writes stubs into it via `write_stub/3` and prepends it
  to `PATH` when invoking the script under test.
  """
  @spec setup_stub_dir(String.t()) :: String.t()
  def setup_stub_dir(prefix) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  @doc """
  Write a bash stub to `dir/name` with `#!/usr/bin/env bash` and
  `set -eu` prepended, and make it executable.
  """
  @spec write_stub(String.t(), String.t(), String.t()) :: :ok
  def write_stub(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/usr/bin/env bash\nset -eu\n" <> body)
    File.chmod!(path, 0o755)
    :ok
  end
end
