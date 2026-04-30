defmodule Awfy.Benchmarks.CD do
  @moduledoc """
  CD — translated from upstream/benchmarks/Ruby/cd.rb.

  Aircraft collision detection. Mirror of `awfy_cd.erl`: a custom
  red-black tree with mutable Node objects becomes an integer-id
  store carried in a tree state record; every "mutation" rewrites
  the node back into the map.

  Verification thresholds (num_aircrafts -> collision count):

      1000 -> 14484, 500 -> 14484, 250 -> 10830, 200 -> 8655,
      100 -> 4305, 10 -> 390, 2 -> 42

  Bug found during port: when motion has zero x- or y-velocity, Ruby
  divides by 0 and uses ±Infinity in the predicate, which makes the
  range tests cleanly false outside the motion's static coordinate.
  Erlang's `/` crashes on /0 and substituting `0.0` corrupts the
  predicate (LowX <= 0 <= HighX becomes vacuously true). Each branch
  of the predicate is now guarded so we only evaluate the non-zero
  arithmetic when there's actual motion in that axis.
  """

  use Awfy.Benchmark

  @min_x 0.0
  @max_x 1000.0
  @min_y 0.0
  @max_y 1000.0
  @min_z 0.0
  @max_z 10.0
  @proximity_radius 1.0
  @good_voxel_size 2.0
  @horizontal {:v2, @good_voxel_size, 0.0}
  @vertical {:v2, 0.0, @good_voxel_size}

  defmodule Node do
    defstruct id: nil, key: nil, value: nil, left: nil, right: nil, parent: nil, color: :red
  end

  defmodule Rbt do
    defstruct root: nil, next_id: 0, nodes: %{}
  end

  def name, do: "CD"

  def benchmark, do: :ok

  def inner_benchmark_loop(n) do
    result = run_benchmark(n)
    verify_result(result, n)
  end

  def verify_result(c, 1000), do: c == 14_484
  def verify_result(c, 500), do: c == 14_484
  def verify_result(c, 250), do: c == 10_830
  def verify_result(c, 200), do: c == 8_655
  def verify_result(c, 100), do: c == 4_305
  def verify_result(c, 10), do: c == 390
  def verify_result(c, 2), do: c == 42
  def verify_result(_, _), do: false

  defp run_benchmark(num_aircrafts) do
    num_frames = 200
    sim = {:sim, num_aircrafts}
    state = %Rbt{}
    run_frames(0, num_frames, sim, state, 0)
  end

  defp run_frames(i, n, _sim, _state, acc) when i >= n, do: acc

  defp run_frames(i, n, sim, state, acc) do
    time = i / 10.0
    frame = simulate(sim, time)
    {collisions, state1} = handle_new_frame(frame, state)
    run_frames(i + 1, n, sim, state1, acc + length(collisions))
  end

  # ---------- Vector ops ----------
  defp v2_plus({:v2, x1, y1}, {:v2, x2, y2}), do: {:v2, x1 + x2, y1 + y2}
  defp v2_minus({:v2, x1, y1}, {:v2, x2, y2}), do: {:v2, x1 - x2, y1 - y2}

  defp v3_plus({:v3, x1, y1, z1}, {:v3, x2, y2, z2}),
    do: {:v3, x1 + x2, y1 + y2, z1 + z2}

  defp v3_minus({:v3, x1, y1, z1}, {:v3, x2, y2, z2}),
    do: {:v3, x1 - x2, y1 - y2, z1 - z2}

  defp v3_dot({:v3, x1, y1, z1}, {:v3, x2, y2, z2}),
    do: x1 * x2 + y1 * y2 + z1 * z2

  defp v3_squared_magnitude(v), do: v3_dot(v, v)
  defp v3_magnitude(v), do: :math.sqrt(v3_squared_magnitude(v))
  defp v3_times({:v3, x, y, z}, a), do: {:v3, x * a, y * a, z * a}

  # ---------- RedBlackTree ----------
  defp rbt_get_node(id, %Rbt{nodes: m}), do: Map.fetch!(m, id)
  defp rbt_put_node(%Node{id: id} = n, t), do: %{t | nodes: Map.put(t.nodes, id, n)}

  defp rbt_new_node(key, value, t) do
    id = t.next_id
    n = %Node{id: id, key: key, value: value}
    {n, %{t | next_id: id + 1, nodes: Map.put(t.nodes, id, n)}}
  end

  defp set_field(node_id, field, val, t) do
    n = rbt_get_node(node_id, t)
    rbt_put_node(Map.put(n, field, val), t)
  end

  defp get_field(node_id, field, t) do
    n = rbt_get_node(node_id, t)
    Map.fetch!(n, field)
  end

  defp color_of(nil, _t), do: :black
  defp color_of(id, t), do: get_field(id, :color, t)

  defp rbt_put(key, value, t0) do
    {result, t1} = tree_insert(key, value, t0)

    case result do
      {:existing, old_value} ->
        {old_value, t1}

      {:new, new_node_id} ->
        t2 = put_fixup(new_node_id, t1)
        t3 = set_field(t2.root, :color, :black, t2)
        {nil, t3}
    end
  end

  defp tree_insert(key, value, %Rbt{root: nil} = t0) do
    {n, t1} = rbt_new_node(key, value, t0)
    {{:new, n.id}, %{t1 | root: n.id}}
  end

  defp tree_insert(key, value, t0), do: tree_insert_walk(t0.root, key, value, t0)

  defp tree_insert_walk(cur, key, value, t) do
    x_key = get_field(cur, :key, t)

    cond do
      key < x_key ->
        case get_field(cur, :left, t) do
          nil -> insert_at(cur, :left, key, value, t)
          l -> tree_insert_walk(l, key, value, t)
        end

      key > x_key ->
        case get_field(cur, :right, t) do
          nil -> insert_at(cur, :right, key, value, t)
          r -> tree_insert_walk(r, key, value, t)
        end

      true ->
        old_value = get_field(cur, :value, t)
        t1 = set_field(cur, :value, value, t)
        {{:existing, old_value}, t1}
    end
  end

  defp insert_at(parent_id, side, key, value, t0) do
    {n, t1} = rbt_new_node(key, value, t0)
    new_id = n.id
    t2 = set_field(new_id, :parent, parent_id, t1)
    t3 = set_field(parent_id, side, new_id, t2)
    {{:new, new_id}, t3}
  end

  defp put_fixup(x, t) do
    case fixup_step(x, t) do
      {:done, t1} -> t1
      {:cont, x1, t1} -> put_fixup(x1, t1)
    end
  end

  defp fixup_step(x, t) do
    cond do
      x == t.root ->
        {:done, t}

      true ->
        p = get_field(x, :parent, t)

        case color_of(p, t) do
          :black ->
            {:done, t}

          :red ->
            pp = get_field(p, :parent, t)

            cond do
              pp == nil ->
                {:done, t}

              p == get_field(pp, :left, t) ->
                fixup_step_left(x, p, pp, t)

              true ->
                fixup_step_right(x, p, pp, t)
            end
        end
    end
  end

  defp fixup_step_left(x, p, pp, t) do
    y = get_field(pp, :right, t)

    if y != nil and color_of(y, t) == :red do
      t1 = set_field(p, :color, :black, t)
      t2 = set_field(y, :color, :black, t1)
      t3 = set_field(pp, :color, :red, t2)
      {:cont, pp, t3}
    else
      {x1, t1} =
        if x == get_field(p, :right, t) do
          {p, left_rotate(p, t)}
        else
          {x, t}
        end

      p1 = get_field(x1, :parent, t1)
      t2 = set_field(p1, :color, :black, t1)
      pp1 = get_field(p1, :parent, t2)
      t3 = set_field(pp1, :color, :red, t2)
      t4 = right_rotate(pp1, t3)
      {:cont, x1, t4}
    end
  end

  defp fixup_step_right(x, p, pp, t) do
    y = get_field(pp, :left, t)

    if y != nil and color_of(y, t) == :red do
      t1 = set_field(p, :color, :black, t)
      t2 = set_field(y, :color, :black, t1)
      t3 = set_field(pp, :color, :red, t2)
      {:cont, pp, t3}
    else
      {x1, t1} =
        if x == get_field(p, :left, t) do
          {p, right_rotate(p, t)}
        else
          {x, t}
        end

      p1 = get_field(x1, :parent, t1)
      t2 = set_field(p1, :color, :black, t1)
      pp1 = get_field(p1, :parent, t2)
      t3 = set_field(pp1, :color, :red, t2)
      t4 = left_rotate(pp1, t3)
      {:cont, x1, t4}
    end
  end

  defp left_rotate(x, t0) do
    y = get_field(x, :right, t0)
    y_left = get_field(y, :left, t0)
    t1 = set_field(x, :right, y_left, t0)
    t2 = if y_left == nil, do: t1, else: set_field(y_left, :parent, x, t1)
    x_parent = get_field(x, :parent, t2)
    t3 = set_field(y, :parent, x_parent, t2)

    t4 =
      cond do
        x_parent == nil -> %{t3 | root: y}
        x == get_field(x_parent, :left, t3) -> set_field(x_parent, :left, y, t3)
        true -> set_field(x_parent, :right, y, t3)
      end

    t5 = set_field(y, :left, x, t4)
    set_field(x, :parent, y, t5)
  end

  defp right_rotate(y, t0) do
    x = get_field(y, :left, t0)
    x_right = get_field(x, :right, t0)
    t1 = set_field(y, :left, x_right, t0)
    t2 = if x_right == nil, do: t1, else: set_field(x_right, :parent, y, t1)
    y_parent = get_field(y, :parent, t2)
    t3 = set_field(x, :parent, y_parent, t2)

    t4 =
      cond do
        y_parent == nil -> %{t3 | root: x}
        y == get_field(y_parent, :left, t3) -> set_field(y_parent, :left, x, t3)
        true -> set_field(y_parent, :right, x, t3)
      end

    t5 = set_field(x, :right, y, t4)
    set_field(y, :parent, x, t5)
  end

  defp rbt_get(key, t) do
    case find_node(key, t.root, t) do
      nil -> nil
      id -> get_field(id, :value, t)
    end
  end

  defp find_node(_key, nil, _t), do: nil

  defp find_node(key, cur, t) do
    x_key = get_field(cur, :key, t)

    cond do
      key == x_key -> cur
      key < x_key -> find_node(key, get_field(cur, :left, t), t)
      true -> find_node(key, get_field(cur, :right, t), t)
    end
  end

  defp rbt_remove(key, t0) do
    case find_node(key, t0.root, t0) do
      nil ->
        {nil, t0}

      z ->
        z_left = get_field(z, :left, t0)
        z_right = get_field(z, :right, t0)
        z_value = get_field(z, :value, t0)
        y = if z_left == nil or z_right == nil, do: z, else: tree_minimum(z_right, t0)
        y_left = get_field(y, :left, t0)
        y_right = get_field(y, :right, t0)
        x = if y_left == nil, do: y_right, else: y_left
        y_parent = get_field(y, :parent, t0)

        {t1, x_parent} =
          if x == nil do
            {t0, y_parent}
          else
            {set_field(x, :parent, y_parent, t0), y_parent}
          end

        t2 =
          cond do
            y_parent == nil -> %{t1 | root: x}
            y == get_field(y_parent, :left, t1) -> set_field(y_parent, :left, x, t1)
            true -> set_field(y_parent, :right, x, t1)
          end

        y_color = get_field(y, :color, t2)

        t3 =
          if y != z do
            t_a = if y_color == :black, do: remove_fixup(x, x_parent, t2), else: t2
            z_parent = get_field(z, :parent, t_a)
            z_color = get_field(z, :color, t_a)
            z_left1 = get_field(z, :left, t_a)
            z_right1 = get_field(z, :right, t_a)
            t_b = set_field(y, :parent, z_parent, t_a)
            t_c = set_field(y, :color, z_color, t_b)
            t_d = set_field(y, :left, z_left1, t_c)
            t_e = set_field(y, :right, z_right1, t_d)
            t_f = if z_left1 == nil, do: t_e, else: set_field(z_left1, :parent, y, t_e)

            t_g =
              if z_right1 == nil, do: t_f, else: set_field(z_right1, :parent, y, t_f)

            cond do
              z_parent == nil ->
                %{t_g | root: y}

              z == get_field(z_parent, :left, t_g) ->
                set_field(z_parent, :left, y, t_g)

              true ->
                set_field(z_parent, :right, y, t_g)
            end
          else
            if y_color == :black, do: remove_fixup(x, x_parent, t2), else: t2
          end

        {z_value, t3}
    end
  end

  defp tree_minimum(cur, t) do
    case get_field(cur, :left, t) do
      nil -> cur
      l -> tree_minimum(l, t)
    end
  end

  defp remove_fixup(x, x_parent, t) do
    if (x != t.root and (x == nil or color_of(x, t) == :black)) do
      if x == get_field(x_parent, :left, t) do
        fixup_left(x, x_parent, t)
      else
        fixup_right(x, x_parent, t)
      end
    else
      if x == nil, do: t, else: set_field(x, :color, :black, t)
    end
  end

  defp fixup_left(_x, x_parent, t) do
    {w1, t1} = fixup_left_case1(get_field(x_parent, :right, t), x_parent, t)
    w_left = get_field(w1, :left, t1)
    w_right = get_field(w1, :right, t1)
    l_black = w_left == nil or color_of(w_left, t1) == :black
    r_black = w_right == nil or color_of(w_right, t1) == :black

    if l_black and r_black do
      t2 = set_field(w1, :color, :red, t1)
      xp1 = get_field(x_parent, :parent, t2)
      remove_fixup(x_parent, xp1, t2)
    else
      {w2, t2} = fixup_left_case3(w1, w_left, w_right, x_parent, t1)
      xp_color = get_field(x_parent, :color, t2)
      t3 = set_field(w2, :color, xp_color, t2)
      t4 = set_field(x_parent, :color, :black, t3)
      w_right1 = get_field(w2, :right, t4)
      t5 = if w_right1 == nil, do: t4, else: set_field(w_right1, :color, :black, t4)
      t6 = left_rotate(x_parent, t5)
      x1 = t6.root
      xp1 = get_field(x1, :parent, t6)
      remove_fixup(x1, xp1, t6)
    end
  end

  defp fixup_left_case1(w, x_parent, t) do
    case color_of(w, t) do
      :red ->
        ta = set_field(w, :color, :black, t)
        tb = set_field(x_parent, :color, :red, ta)
        tc = left_rotate(x_parent, tb)
        {get_field(x_parent, :right, tc), tc}

      _ ->
        {w, t}
    end
  end

  defp fixup_left_case3(w1, w_left, w_right, x_parent, t1) do
    if w_right == nil or color_of(w_right, t1) == :black do
      ta = set_field(w_left, :color, :black, t1)
      tb = set_field(w1, :color, :red, ta)
      tc = right_rotate(w1, tb)
      {get_field(x_parent, :right, tc), tc}
    else
      {w1, t1}
    end
  end

  defp fixup_right(_x, x_parent, t) do
    {w1, t1} = fixup_right_case1(get_field(x_parent, :left, t), x_parent, t)
    w_left = get_field(w1, :left, t1)
    w_right = get_field(w1, :right, t1)
    r_black = w_right == nil or color_of(w_right, t1) == :black
    l_black = w_left == nil or color_of(w_left, t1) == :black

    if r_black and l_black do
      t2 = set_field(w1, :color, :red, t1)
      xp1 = get_field(x_parent, :parent, t2)
      remove_fixup(x_parent, xp1, t2)
    else
      {w2, t2} = fixup_right_case3(w1, w_left, w_right, x_parent, t1)
      xp_color = get_field(x_parent, :color, t2)
      t3 = set_field(w2, :color, xp_color, t2)
      t4 = set_field(x_parent, :color, :black, t3)
      w_left1 = get_field(w2, :left, t4)
      t5 = if w_left1 == nil, do: t4, else: set_field(w_left1, :color, :black, t4)
      t6 = right_rotate(x_parent, t5)
      x1 = t6.root
      xp1 = get_field(x1, :parent, t6)
      remove_fixup(x1, xp1, t6)
    end
  end

  defp fixup_right_case1(w, x_parent, t) do
    case color_of(w, t) do
      :red ->
        ta = set_field(w, :color, :black, t)
        tb = set_field(x_parent, :color, :red, ta)
        tc = right_rotate(x_parent, tb)
        {get_field(x_parent, :left, tc), tc}

      _ ->
        {w, t}
    end
  end

  defp fixup_right_case3(w1, w_left, w_right, x_parent, t1) do
    if w_left == nil or color_of(w_left, t1) == :black do
      ta = set_field(w_right, :color, :black, t1)
      tb = set_field(w1, :color, :red, ta)
      tc = left_rotate(w1, tb)
      {get_field(x_parent, :left, tc), tc}
    else
      {w1, t1}
    end
  end

  defp rbt_for_each(t, fun, acc0) do
    case t.root do
      nil -> acc0
      root -> for_each_loop(tree_minimum(root, t), t, fun, acc0)
    end
  end

  defp for_each_loop(nil, _t, _fun, acc), do: acc

  defp for_each_loop(cur, t, fun, acc) do
    entry = {:entry, get_field(cur, :key, t), get_field(cur, :value, t)}
    acc1 = fun.(entry, acc)
    next = successor(cur, t)
    for_each_loop(next, t, fun, acc1)
  end

  defp successor(x, t) do
    case get_field(x, :right, t) do
      nil -> succ_walk_up(x, t)
      r -> tree_minimum(r, t)
    end
  end

  defp succ_walk_up(x, t) do
    case get_field(x, :parent, t) do
      nil ->
        nil

      y ->
        if x == get_field(y, :right, t), do: succ_walk_up(y, t), else: y
      end
  end

  # ---------- Simulator ----------
  defp simulate({:sim, n}, time), do: sim_step(0, n, time, [])

  defp sim_step(i, n, _time, acc) when i >= n, do: Enum.reverse(acc)

  defp sim_step(i, n, time, acc) do
    a1 =
      {:aircraft, {:cs, i},
       {:v3, time, :math.cos(time) * 2.0 + i * 3.0, 10.0}}

    a2 =
      {:aircraft, {:cs, i + 1},
       {:v3, time, :math.sin(time) * 2.0 + i * 3.0, 10.0}}

    sim_step(i + 2, n, time, [a2, a1 | acc])
  end

  # ---------- CollisionDetector ----------
  defp handle_new_frame(frame, state0) do
    seen0 = %Rbt{}
    {motions, state1, seen1} = build_motions(frame, [], state0, seen0)
    state2 = remove_unseen(state1, seen1)
    reduced = reduce_collision_set(motions)
    collisions = find_collisions(reduced)
    {collisions, state2}
  end

  defp build_motions([], motions, state, seen), do: {Enum.reverse(motions), state, seen}

  defp build_motions([{:aircraft, cs, pos} | rest], acc, state0, seen0) do
    {old_pos_opt, state1} = rbt_put(cs, pos, state0)
    {_, seen1} = rbt_put(cs, true, seen0)
    old_pos = if old_pos_opt == nil, do: pos, else: old_pos_opt
    motion = {:motion, cs, old_pos, pos}
    build_motions(rest, [motion | acc], state1, seen1)
  end

  defp remove_unseen(state, seen) do
    to_remove =
      rbt_for_each(state, fn {:entry, k, _v}, acc ->
        case rbt_get(k, seen) do
          nil -> [k | acc]
          _ -> acc
        end
      end, [])

    Enum.reduce(to_remove, state, fn k, s ->
      {_, s1} = rbt_remove(k, s)
      s1
    end)
  end

  defp reduce_collision_set(motions) do
    voxel_map = Enum.reduce(motions, %Rbt{}, &draw_motion_on_voxel_map(&2, &1))

    rbt_for_each(voxel_map, fn {:entry, _k, v}, acc ->
      if length(v) > 1, do: [v | acc], else: acc
    end, [])
  end

  defp draw_motion_on_voxel_map(voxel_map, {:motion, _cs, p1, _p2} = motion) do
    seen0 = %Rbt{}
    {voxel_map1, _seen1} = recurse(voxel_map, seen0, voxel_hash(p1), motion)
    voxel_map1
  end

  defp recurse(voxel_map, seen, next_voxel, motion) do
    if is_in_voxel(next_voxel, motion) do
      {old, seen1} = rbt_put(next_voxel, true, seen)

      case old do
        nil ->
          voxel_map1 = put_into_map(voxel_map, next_voxel, motion)

          {voxel_map2, seen2} =
            recurse(voxel_map1, seen1, v2_minus(next_voxel, @horizontal), motion)

          {voxel_map3, seen3} =
            recurse(voxel_map2, seen2, v2_plus(next_voxel, @horizontal), motion)

          {voxel_map4, seen4} =
            recurse(voxel_map3, seen3, v2_minus(next_voxel, @vertical), motion)

          {voxel_map5, seen5} =
            recurse(voxel_map4, seen4, v2_plus(next_voxel, @vertical), motion)

          {voxel_map6, seen6} =
            recurse(voxel_map5, seen5,
              v2_minus(v2_minus(next_voxel, @horizontal), @vertical), motion)

          {voxel_map7, seen7} =
            recurse(voxel_map6, seen6,
              v2_plus(v2_minus(next_voxel, @horizontal), @vertical), motion)

          {voxel_map8, seen8} =
            recurse(voxel_map7, seen7,
              v2_minus(v2_plus(next_voxel, @horizontal), @vertical), motion)

          recurse(voxel_map8, seen8,
            v2_plus(v2_plus(next_voxel, @horizontal), @vertical), motion)

        _ ->
          {voxel_map, seen1}
      end
    else
      {voxel_map, seen}
    end
  end

  defp put_into_map(voxel_map, voxel, motion) do
    case rbt_get(voxel, voxel_map) do
      nil ->
        {_, vm1} = rbt_put(voxel, [motion], voxel_map)
        vm1

      existing ->
        {_, vm1} = rbt_put(voxel, [motion | existing], voxel_map)
        vm1
    end
  end

  defp voxel_hash({:v3, x, y, _z}) do
    x_div = trunc(x / @good_voxel_size)
    y_div = trunc(y / @good_voxel_size)
    xv = @good_voxel_size * x_div
    yv = @good_voxel_size * y_div
    xv1 = if x < 0.0, do: xv - @good_voxel_size, else: xv
    yv1 = if y < 0.0, do: yv - @good_voxel_size, else: yv
    {:v2, xv1, yv1}
  end

  defp is_in_voxel({:v2, vx, _vy}, _) when vx > @max_x or vx < @min_x, do: false
  defp is_in_voxel({:v2, _vx, vy}, _) when vy > @max_y or vy < @min_y, do: false

  defp is_in_voxel({:v2, vx, vy}, {:motion, _cs, {:v3, x0, y0, _}, {:v3, fin_x, fin_y, _}}) do
    vs = @good_voxel_size
    r = @proximity_radius / 2.0
    xv = fin_x - x0
    yv = fin_y - y0

    x_cond(xv, vx, x0, vs, r) and
      y_cond(yv, vy, y0, vs, r) and
      diag_cond(xv, yv, vx, vy, x0, y0, vs, r)
  end

  defp x_cond(+0.0, vx, x0, vs, r), do: vx <= x0 + r and x0 - r <= vx + vs

  defp x_cond(xv, vx, x0, vs, r) do
    low_x0 = (vx - r - x0) / xv
    high_x0 = (vx + vs + r - x0) / xv

    {low_x, high_x} =
      if xv < 0.0, do: {high_x0, low_x0}, else: {low_x0, high_x0}

    (low_x <= 1.0 and 1.0 <= high_x) or
      (low_x <= 0.0 and 0.0 <= high_x) or
      (0.0 <= low_x and high_x <= 1.0)
  end

  defp y_cond(+0.0, vy, y0, vs, r), do: vy <= y0 + r and y0 - r <= vy + vs

  defp y_cond(yv, vy, y0, vs, r) do
    low_y0 = (vy - r - y0) / yv
    high_y0 = (vy + vs + r - y0) / yv

    {low_y, high_y} =
      if yv < 0.0, do: {high_y0, low_y0}, else: {low_y0, high_y0}

    (low_y <= 1.0 and 1.0 <= high_y) or
      (low_y <= 0.0 and 0.0 <= high_y) or
      (0.0 <= low_y and high_y <= 1.0)
  end

  defp diag_cond(+0.0, _yv, _vx, _vy, _x0, _y0, _vs, _r), do: true
  defp diag_cond(_xv, +0.0, _vx, _vy, _x0, _y0, _vs, _r), do: true

  defp diag_cond(xv, yv, vx, vy, x0, y0, vs, r) do
    low_x0 = (vx - r - x0) / xv
    high_x0 = (vx + vs + r - x0) / xv

    {low_x, high_x} =
      if xv < 0.0, do: {high_x0, low_x0}, else: {low_x0, high_x0}

    low_y0 = (vy - r - y0) / yv
    high_y0 = (vy + vs + r - y0) / yv

    {low_y, high_y} =
      if yv < 0.0, do: {high_y0, low_y0}, else: {low_y0, high_y0}

    (low_y <= high_x and high_x <= high_y) or
      (low_y <= low_x and low_x <= high_y) or
      (low_x <= low_y and high_y <= high_x)
  end

  # ---------- Collision finding ----------
  defp find_collisions(reduced), do: Enum.reduce(reduced, [], &find_in_group/2)

  defp find_in_group(group, acc), do: pair_outer(group, acc)

  defp pair_outer([], acc), do: acc
  defp pair_outer([_], acc), do: acc

  defp pair_outer([m1 | rest], acc) do
    acc1 = pair_inner(m1, rest, acc)
    pair_outer(rest, acc1)
  end

  defp pair_inner(_m1, [], acc), do: acc

  defp pair_inner(m1, [m2 | rest], acc) do
    acc1 =
      case find_intersection(m1, m2) do
        nil ->
          acc

        pos ->
          {:motion, cs_a, _, _} = m1
          {:motion, cs_b, _, _} = m2
          [{:collision, cs_a, cs_b, pos} | acc]
      end

    pair_inner(m1, rest, acc1)
  end

  defp find_intersection({:motion, _, init1, p1_two}, {:motion, _, init2, p2_two}) do
    vec1 = v3_minus(p1_two, init1)
    vec2 = v3_minus(p2_two, init2)
    radius = @proximity_radius
    a = v3_squared_magnitude(v3_minus(vec2, vec1))

    if a != 0.0 do
      b = 2.0 * v3_dot(v3_minus(init1, init2), v3_minus(vec1, vec2))
      c = -radius * radius + v3_squared_magnitude(v3_minus(init2, init1))
      discr = b * b - 4.0 * a * c

      if discr < 0.0 do
        nil
      else
        sqrt_d = :math.sqrt(discr)
        v1 = (-b - sqrt_d) / (2.0 * a)
        v2 = (-b + sqrt_d) / (2.0 * a)

        if v1 <= v2 and
             ((v1 <= 1.0 and 1.0 <= v2) or (v1 <= 0.0 and 0.0 <= v2) or
                (0.0 <= v1 and v2 <= 1.0)) do
          v = if v1 <= 0.0, do: 0.0, else: v1
          r1 = v3_plus(init1, v3_times(vec1, v))
          r2 = v3_plus(init2, v3_times(vec2, v))
          result = v3_times(v3_plus(r1, r2), 0.5)
          {:v3, rx, ry, rz} = result

          if rx >= @min_x and rx <= @max_x and
               ry >= @min_y and ry <= @max_y and
               rz >= @min_z and rz <= @max_z do
            result
          else
            nil
          end
        else
          nil
        end
      end
    else
      dist = v3_magnitude(v3_minus(init2, init1))
      if dist <= radius, do: v3_times(v3_plus(init1, init2), 0.5), else: nil
    end
  end
end
