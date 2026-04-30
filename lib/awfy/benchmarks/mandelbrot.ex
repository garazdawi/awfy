defmodule Awfy.Benchmarks.Mandelbrot do
  @moduledoc """
  Mandelbrot — translated from upstream/benchmarks/Ruby/mandelbrot.rb.

  Bit-packed Mandelbrot escape-time computation. Verification depends
  on inner_iterations (the size N): N=500 -> 191, N=750 -> 50, N=1 -> 128.
  Pure float arithmetic in the inner loop with bit-shifting on a byte
  accumulator.
  """

  use Awfy.Benchmark

  def name, do: "Mandelbrot"

  def inner_benchmark_loop(inner_iter) do
    verify_result(mandelbrot(inner_iter), inner_iter)
  end

  def verify_result(result, 500), do: result == 191
  def verify_result(result, 750), do: result == 50
  def verify_result(result, 1), do: result == 128
  def verify_result(_result, _), do: false

  defp mandelbrot(size), do: y_loop(0, size, 0)

  defp y_loop(y, size, sum) when y >= size, do: sum

  defp y_loop(y, size, sum) do
    ci = 2.0 * y / size - 1.0
    sum1 = x_loop(0, size, ci, 0, 0, sum)
    y_loop(y + 1, size, sum1)
  end

  defp x_loop(x, size, _ci, _byte_acc, _bit_num, sum) when x >= size, do: sum

  defp x_loop(x, size, ci, byte_acc, bit_num, sum) do
    cr = 2.0 * x / size - 1.5
    escape = iterate(0, 0.0, 0.0, 0.0, cr, ci)
    byte_acc1 = Bitwise.bsl(byte_acc, 1) + escape
    bit_num1 = bit_num + 1

    {byte_acc2, bit_num2, sum1} =
      cond do
        bit_num1 == 8 ->
          {0, 0, Bitwise.bxor(sum, byte_acc1)}

        x == size - 1 ->
          shifted = Bitwise.bsl(byte_acc1, 8 - bit_num1)
          {0, 0, Bitwise.bxor(sum, shifted)}

        true ->
          {byte_acc1, bit_num1, sum}
      end

    x_loop(x + 1, size, ci, byte_acc2, bit_num2, sum1)
  end

  # Iterate up to 50 times. Returns 1 if escaped, 0 otherwise.
  defp iterate(50, _zrzr, _zizi, _zi, _cr, _ci), do: 0

  defp iterate(_z, zrzr, zizi, _zi, _cr, _ci) when zrzr + zizi > 4.0, do: 1

  defp iterate(z, zrzr, zizi, zi, cr, ci) do
    zr = zrzr - zizi + cr
    zi1 = 2.0 * zr * zi + ci
    zrzr1 = zr * zr
    zizi1 = zi1 * zi1

    if zrzr1 + zizi1 > 4.0 do
      1
    else
      iterate(z + 1, zrzr1, zizi1, zi1, cr, ci)
    end
  end
end
