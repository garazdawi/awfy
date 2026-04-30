defmodule Awfy.Benchmarks.NBody do
  @moduledoc """
  NBody — translated from upstream/benchmarks/Ruby/nbody.rb.

  5-body planetary simulation. Verification depends on inner_iterations:
    1      -> -0.16907495402506745
    250000 -> -0.1690859889909308

  Bodies are stored in a 5-tuple of body structs. The advance and
  energy loops are nested recursion over indices i and j>i, mirroring
  the Ruby's nested each_index loops.
  """

  use Awfy.Benchmark

  defmodule Body do
    defstruct [:x, :y, :z, :vx, :vy, :vz, :mass]
  end

  @pi 3.141592653589793
  @solar_mass 4.0 * @pi * @pi
  @days_per_year 365.24
  @n_bodies 5

  def name, do: "NBody"

  def inner_benchmark_loop(inner_iter) do
    bodies = create_bodies()
    bodies1 = run_steps(inner_iter, bodies, 0.01)
    verify_result(energy(bodies1), inner_iter)
  end

  def verify_result(result, 1), do: result == -0.16907495402506745
  def verify_result(result, 250_000), do: result == -0.1690859889909308
  def verify_result(_result, _), do: false

  defp run_steps(0, bodies, _dt), do: bodies
  defp run_steps(n, bodies, dt), do: run_steps(n - 1, advance(bodies, dt), dt)

  defp create_bodies do
    bodies = {sun(), jupiter(), saturn(), uranus(), neptune()}
    {px, py, pz} = momentum_loop(0, bodies, 0.0, 0.0, 0.0)
    put_elem(bodies, 0, offset_momentum(elem(bodies, 0), px, py, pz))
  end

  defp body(x, y, z, vx, vy, vz, mass) do
    %Body{
      x: x,
      y: y,
      z: z,
      vx: vx * @days_per_year,
      vy: vy * @days_per_year,
      vz: vz * @days_per_year,
      mass: mass * @solar_mass
    }
  end

  defp sun, do: body(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0)

  defp jupiter do
    body(
      4.8414314424647209,
      -1.16032004402742839,
      -0.103622044471123109,
      0.00166007664274403694,
      0.00769901118419740425,
      -0.0000690460016972063023,
      0.000954791938424326609
    )
  end

  defp saturn do
    body(
      8.34336671824457987,
      4.12479856412430479,
      -0.403523417114321381,
      -0.00276742510726862411,
      0.00499852801234917238,
      0.0000230417297573763929,
      0.000285885980666130812
    )
  end

  defp uranus do
    body(
      12.894369562139131,
      -15.1111514016986312,
      -0.223307578892655734,
      0.00296460137564761618,
      0.0023784717395948095,
      -0.0000296589568540237556,
      0.0000436624404335156298
    )
  end

  defp neptune do
    body(
      15.3796971148509165,
      -25.9193146099879641,
      0.179258772950371181,
      0.00268067772490389322,
      0.00162824170038242295,
      -0.000095159225451971587,
      0.0000515138902046611451
    )
  end

  defp offset_momentum(b, px, py, pz) do
    %{b | vx: 0.0 - px / @solar_mass, vy: 0.0 - py / @solar_mass, vz: 0.0 - pz / @solar_mass}
  end

  defp momentum_loop(i, _bodies, px, py, pz) when i >= @n_bodies, do: {px, py, pz}

  defp momentum_loop(i, bodies, px, py, pz) do
    b = elem(bodies, i)

    momentum_loop(
      i + 1,
      bodies,
      px + b.vx * b.mass,
      py + b.vy * b.mass,
      pz + b.vz * b.mass
    )
  end

  defp advance(bodies, dt) do
    bodies1 = advance_i(0, bodies, dt)
    move_loop(0, bodies1, dt)
  end

  defp advance_i(i, bodies, _dt) when i >= @n_bodies - 1, do: bodies

  defp advance_i(i, bodies, dt) do
    bodies1 = advance_j(i, i + 1, bodies, dt)
    advance_i(i + 1, bodies1, dt)
  end

  defp advance_j(_i, j, bodies, _dt) when j >= @n_bodies, do: bodies

  defp advance_j(i, j, bodies, dt) do
    bodies1 = update_pair(i, j, bodies, dt)
    advance_j(i, j + 1, bodies1, dt)
  end

  defp update_pair(i, j, bodies, dt) do
    ib = elem(bodies, i)
    jb = elem(bodies, j)
    dx = ib.x - jb.x
    dy = ib.y - jb.y
    dz = ib.z - jb.z
    d_sq = dx * dx + dy * dy + dz * dz
    distance = :math.sqrt(d_sq)
    mag = dt / (d_sq * distance)
    j_mass_mag = jb.mass * mag
    i_mass_mag = ib.mass * mag

    ib1 = %{
      ib
      | vx: ib.vx - dx * j_mass_mag,
        vy: ib.vy - dy * j_mass_mag,
        vz: ib.vz - dz * j_mass_mag
    }

    jb1 = %{
      jb
      | vx: jb.vx + dx * i_mass_mag,
        vy: jb.vy + dy * i_mass_mag,
        vz: jb.vz + dz * i_mass_mag
    }

    bodies |> put_elem(i, ib1) |> put_elem(j, jb1)
  end

  defp move_loop(i, bodies, _dt) when i >= @n_bodies, do: bodies

  defp move_loop(i, bodies, dt) do
    b = elem(bodies, i)
    b1 = %{b | x: b.x + dt * b.vx, y: b.y + dt * b.vy, z: b.z + dt * b.vz}
    move_loop(i + 1, put_elem(bodies, i, b1), dt)
  end

  defp energy(bodies), do: energy_loop(0, bodies, 0.0)

  defp energy_loop(i, _bodies, e) when i >= @n_bodies, do: e

  defp energy_loop(i, bodies, e) do
    ib = elem(bodies, i)
    self_e = 0.5 * ib.mass * (ib.vx * ib.vx + ib.vy * ib.vy + ib.vz * ib.vz)
    e1 = e + self_e
    e2 = energy_inner(i, i + 1, bodies, e1)
    energy_loop(i + 1, bodies, e2)
  end

  defp energy_inner(_i, j, _bodies, e) when j >= @n_bodies, do: e

  defp energy_inner(i, j, bodies, e) do
    ib = elem(bodies, i)
    jb = elem(bodies, j)
    dx = ib.x - jb.x
    dy = ib.y - jb.y
    dz = ib.z - jb.z
    distance = :math.sqrt(dx * dx + dy * dy + dz * dz)
    energy_inner(i, j + 1, bodies, e - ib.mass * jb.mass / distance)
  end
end
