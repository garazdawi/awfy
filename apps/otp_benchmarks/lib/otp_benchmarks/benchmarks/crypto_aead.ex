# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.CryptoAead do
  @moduledoc """
  AEAD cipher throughput via `:crypto.crypto_one_time_aead/6` —
  three production-relevant ciphers at two block sizes:

    * AES-128-GCM   — block-oriented; small key
    * AES-256-GCM   — block-oriented; larger key (extra rounds)
    * ChaCha20-Poly1305 — stream-oriented; constant-time
                        software path

  Each at 256-byte block (the upstream `crypto_bench_SUITE`
  `textblock_256` group for symmetry) and 4 KB block (sustained
  throughput where vectorisation matters).

  `:crypto.crypto_one_time_aead/6` is one NIF call per encrypt;
  per-call cost dominates over algorithm cost for the small input,
  algorithm cost dominates for the large. The split surfaces NIF
  dispatch regressions separately from cipher-implementation
  regressions.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "crypto_aead"

  # `:crypto.crypto_one_time_aead/6` was added in OTP 22.0; on
  # OTP-20 and OTP-21 the BIF is undef and Benchee's calibration
  # loop aborts the whole target VM with an init-terminating
  # crash. Runtime gate so the runner skips the family on those
  # legacy refs rather than taking down the measurement run.
  def supported?, do: function_exported?(:crypto, :crypto_one_time_aead, 6)

  @aad <<"awfy">>
  @iv_12 :binary.copy(<<0>>, 12)
  @key_16 :binary.copy(<<1>>, 16)
  @key_32 :binary.copy(<<1>>, 32)

  def inputs do
    %{
      "aes128gcm_256b" => {:aes_128_gcm, @key_16, :binary.copy(<<"x">>, 256)},
      "aes128gcm_4k" => {:aes_128_gcm, @key_16, :binary.copy(<<"x">>, 4096)},
      "aes256gcm_256b" => {:aes_256_gcm, @key_32, :binary.copy(<<"x">>, 256)},
      "aes256gcm_4k" => {:aes_256_gcm, @key_32, :binary.copy(<<"x">>, 4096)},
      "chacha20poly1305_256b" => {:chacha20_poly1305, @key_32, :binary.copy(<<"x">>, 256)},
      "chacha20poly1305_4k" => {:chacha20_poly1305, @key_32, :binary.copy(<<"x">>, 4096)}
    }
  end

  def run({cipher, key, plaintext}) do
    :crypto.crypto_one_time_aead(cipher, key, @iv_12, plaintext, @aad, true)
  end
end
