# SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: MIT

defmodule Awfy.Benchmarks.Bounce do
  @moduledoc """
  Bounce — translated from upstream/benchmarks/Ruby/bounce.rb.

  100 balls bouncing inside a 500x500 box for 50 ticks. Returns the
  number of times any ball hit a wall.
  """

  use Awfy.Benchmark

  defmodule Ball do
    defstruct [:x, :y, :vx, :vy]
  end

  def name, do: "Bounce"

  def verify_result(bounces), do: bounces == 1331

  def benchmark do
    seed0 = Awfy.Random.new()
    {balls, _seed1} = init_balls(100, [], seed0)
    run(50, balls, 0)
  end

  defp init_balls(0, acc, seed), do: {Enum.reverse(acc), seed}

  defp init_balls(n, acc, seed) do
    {ball, seed1} = new_ball(seed)
    init_balls(n - 1, [ball | acc], seed1)
  end

  defp new_ball(seed0) do
    {x, seed1} = Awfy.Random.next(seed0)
    {y, seed2} = Awfy.Random.next(seed1)
    {vx, seed3} = Awfy.Random.next(seed2)
    {vy, seed4} = Awfy.Random.next(seed3)

    ball = %Ball{
      x: rem(x, 500),
      y: rem(y, 500),
      vx: rem(vx, 300) - 150,
      vy: rem(vy, 300) - 150
    }

    {ball, seed4}
  end

  defp run(0, _balls, bounces), do: bounces

  defp run(tick, balls, bounces) do
    {new_balls, tick_bounces} = tick(balls, [], 0)
    run(tick - 1, new_balls, bounces + tick_bounces)
  end

  defp tick([], acc, bounced), do: {Enum.reverse(acc), bounced}

  defp tick([ball | rest], acc, bounced) do
    {new_ball, did_bounce} = bounce(ball)
    inc = if did_bounce, do: 1, else: 0
    tick(rest, [new_ball | acc], bounced + inc)
  end

  defp bounce(%Ball{x: x0, y: y0, vx: vx0, vy: vy0}) do
    limit = 500
    x1 = x0 + vx0
    y1 = y0 + vy0
    {x2, vx1, b1} = clamp(x1, vx0, limit, false)
    {y2, vy1, b2} = clamp(y1, vy0, limit, b1)
    {%Ball{x: x2, y: y2, vx: vx1, vy: vy1}, b2}
  end

  defp clamp(v, vel, limit, _bounced) when v > limit, do: {limit, -abs(vel), true}
  defp clamp(v, vel, _limit, _bounced) when v < 0, do: {0, abs(vel), true}
  defp clamp(v, vel, _limit, bounced), do: {v, vel, bounced}
end
