defmodule Awfy.Benchmarks.DeltaBlue do
  @moduledoc """
  DeltaBlue — translated from upstream/benchmarks/Ruby/deltablue.rb.

  Constraint propagation solver. Mirror of `awfy_deltablue.erl`: every
  "object" gets an integer id, a `world` map holds vars and constraints
  by id, and threads through every operation. Polymorphic constraint
  dispatch goes through tagged tuples.

  Verification: chain_test and projection_test both raise on assertion
  failure, so reaching the end means correct.
  """

  use Awfy.Benchmark

  # The eight named strengths from the Ruby; only those used by
  # chain_test/projection_test get module-attribute names.
  @str_required -800
  @str_preferred -400
  @str_strong_default -200
  @str_default 0
  @str_abs_weakest 10_000

  defmodule Var do
    defstruct id: nil,
              value: 0,
              constraints: [],
              determined_by: nil,
              walk_strength: 10_000,
              stay: true,
              mark: 0
  end

  defmodule World do
    defstruct next_id: 0, vars: %{}, cons: %{}, current_mark: 1
  end

  def name, do: "DeltaBlue"

  def benchmark, do: :ok

  def inner_benchmark_loop(n) do
    chain_test(n)
    projection_test(n)
    verify_result(true)
  end

  def verify_result(true), do: true
  def verify_result(_), do: false

  # ---------- Strength helpers ----------
  defp strength_stronger(a, b), do: a < b
  defp strength_weaker(a, b), do: a > b
  defp strength_weakest(a, b), do: if(strength_weaker(b, a), do: b, else: a)

  # ---------- World / Variable / Constraint primitives ----------
  defp new_world, do: %World{}

  defp new_var(%World{next_id: n, vars: m} = w) do
    var = %Var{id: n}
    {n, %{w | next_id: n + 1, vars: Map.put(m, n, var)}}
  end

  defp new_var_with(value, w) do
    {id, w1} = new_var(w)
    {id, set_var_field(id, :value, value, w1)}
  end

  defp get_var(id, %World{vars: m}), do: Map.fetch!(m, id)
  defp put_var(%Var{id: id} = v, w), do: %{w | vars: Map.put(w.vars, id, v)}

  defp set_var_field(id, field, value, w) do
    v = get_var(id, w)
    put_var(Map.put(v, field, value), w)
  end

  defp var_add_constraint(var_id, c_id, w) do
    v = get_var(var_id, w)
    put_var(%{v | constraints: v.constraints ++ [c_id]}, w)
  end

  defp var_remove_constraint(var_id, c_id, w) do
    v = get_var(var_id, w)
    cs1 = List.delete(v.constraints, c_id)
    db1 = if v.determined_by == c_id, do: nil, else: v.determined_by
    put_var(%{v | constraints: cs1, determined_by: db1}, w)
  end

  defp new_id(%World{next_id: n} = w), do: {n, %{w | next_id: n + 1}}

  defp get_con(id, %World{cons: m}), do: Map.fetch!(m, id)
  defp put_con(c, w), do: %{w | cons: Map.put(w.cons, con_id(c), c)}

  defp con_id({:stay_c, id, _, _, _}), do: id
  defp con_id({:edit_c, id, _, _, _}), do: id
  defp con_id({:eq_c, id, _, _, _, _}), do: id
  defp con_id({:scale_c, id, _, _, _, _, _, _}), do: id

  defp con_strength({:stay_c, _, s, _, _}), do: s
  defp con_strength({:edit_c, _, s, _, _}), do: s
  defp con_strength({:eq_c, _, s, _, _, _}), do: s
  defp con_strength({:scale_c, _, s, _, _, _, _, _}), do: s

  defp new_mark(%World{current_mark: m} = w) do
    m1 = m + 1
    {m1, %{w | current_mark: m1}}
  end

  # ---------- Polymorphic ops ----------
  defp is_input({:edit_c, _, _, _, _}), do: true
  defp is_input(_), do: false

  defp is_satisfied({:stay_c, _, _, _, s}), do: s
  defp is_satisfied({:edit_c, _, _, _, s}), do: s
  defp is_satisfied({:eq_c, _, _, _, _, d}), do: d != nil
  defp is_satisfied({:scale_c, _, _, _, _, _, _, d}), do: d != nil

  defp mark_unsatisfied({:stay_c, id, s, o, _}), do: {:stay_c, id, s, o, false}
  defp mark_unsatisfied({:edit_c, id, s, o, _}), do: {:edit_c, id, s, o, false}
  defp mark_unsatisfied({:eq_c, id, s, v1, v2, _}), do: {:eq_c, id, s, v1, v2, nil}

  defp mark_unsatisfied({:scale_c, id, s, v1, v2, sc, of, _}),
    do: {:scale_c, id, s, v1, v2, sc, of, nil}

  defp output({:stay_c, _, _, o, _}), do: o
  defp output({:edit_c, _, _, o, _}), do: o
  defp output({:eq_c, _, _, v1, v2, d}), do: if(d == :forward, do: v2, else: v1)
  defp output({:scale_c, _, _, v1, v2, _, _, d}), do: if(d == :forward, do: v2, else: v1)

  defp add_to_graph({:stay_c, id, s, o, _}, w) do
    w1 = var_add_constraint(o, id, w)
    put_con({:stay_c, id, s, o, false}, w1)
  end

  defp add_to_graph({:edit_c, id, s, o, _}, w) do
    w1 = var_add_constraint(o, id, w)
    put_con({:edit_c, id, s, o, false}, w1)
  end

  defp add_to_graph({:eq_c, id, s, v1, v2, _}, w) do
    w1 = var_add_constraint(v1, id, w)
    w2 = var_add_constraint(v2, id, w1)
    put_con({:eq_c, id, s, v1, v2, nil}, w2)
  end

  defp add_to_graph({:scale_c, id, s, v1, v2, sc, of, _}, w) do
    w1 = var_add_constraint(v1, id, w)
    w2 = var_add_constraint(v2, id, w1)
    w3 = var_add_constraint(sc, id, w2)
    w4 = var_add_constraint(of, id, w3)
    put_con({:scale_c, id, s, v1, v2, sc, of, nil}, w4)
  end

  defp remove_from_graph({:stay_c, id, s, o, _}, w) do
    w1 = var_remove_constraint(o, id, w)
    put_con({:stay_c, id, s, o, false}, w1)
  end

  defp remove_from_graph({:edit_c, id, s, o, _}, w) do
    w1 = var_remove_constraint(o, id, w)
    put_con({:edit_c, id, s, o, false}, w1)
  end

  defp remove_from_graph({:eq_c, id, s, v1, v2, _}, w) do
    w1 = var_remove_constraint(v1, id, w)
    w2 = var_remove_constraint(v2, id, w1)
    put_con({:eq_c, id, s, v1, v2, nil}, w2)
  end

  defp remove_from_graph({:scale_c, id, s, v1, v2, sc, of, _}, w) do
    w1 = var_remove_constraint(v1, id, w)
    w2 = var_remove_constraint(v2, id, w1)
    w3 = var_remove_constraint(sc, id, w2)
    w4 = var_remove_constraint(of, id, w3)
    put_con({:scale_c, id, s, v1, v2, sc, of, nil}, w4)
  end

  defp choose_method({:stay_c, id, s, o, _}, mark, w) do
    out_v = get_var(o, w)
    sat = out_v.mark != mark and strength_stronger(s, out_v.walk_strength)
    put_con({:stay_c, id, s, o, sat}, w)
  end

  defp choose_method({:edit_c, id, s, o, _}, mark, w) do
    out_v = get_var(o, w)
    sat = out_v.mark != mark and strength_stronger(s, out_v.walk_strength)
    put_con({:edit_c, id, s, o, sat}, w)
  end

  defp choose_method({:eq_c, _, s, v1, v2, _} = c, mark, w),
    do: choose_binary(c, s, v1, v2, mark, w)

  defp choose_method({:scale_c, _, s, v1, v2, _, _, _} = c, mark, w),
    do: choose_binary(c, s, v1, v2, mark, w)

  defp choose_binary(c, s, v1, v2, mark, w) do
    v1v = get_var(v1, w)
    v2v = get_var(v2, w)

    direction =
      cond do
        v1v.mark == mark ->
          if v2v.mark != mark and strength_stronger(s, v2v.walk_strength),
            do: :forward,
            else: nil

        v2v.mark == mark ->
          if v1v.mark != mark and strength_stronger(s, v1v.walk_strength),
            do: :backward,
            else: nil

        strength_weaker(v1v.walk_strength, v2v.walk_strength) ->
          if strength_stronger(s, v1v.walk_strength), do: :backward, else: nil

        true ->
          if strength_stronger(s, v2v.walk_strength), do: :forward, else: nil
      end

    put_con(set_direction(c, direction), w)
  end

  defp set_direction({:eq_c, id, s, v1, v2, _}, d), do: {:eq_c, id, s, v1, v2, d}

  defp set_direction({:scale_c, id, s, v1, v2, sc, of, _}, d),
    do: {:scale_c, id, s, v1, v2, sc, of, d}

  defp inputs_list({:stay_c, _, _, _, _}), do: []
  defp inputs_list({:edit_c, _, _, _, _}), do: []

  defp inputs_list({:eq_c, _, _, v1, v2, d}),
    do: if(d == :forward, do: [v1], else: [v2])

  defp inputs_list({:scale_c, _, _, v1, v2, sc, of, d}),
    do: if(d == :forward, do: [v1, sc, of], else: [v2, sc, of])

  defp inputs_known(c, mark, w) do
    not Enum.any?(inputs_list(c), fn var_id ->
      v = get_var(var_id, w)
      not (v.mark == mark or v.stay or v.determined_by == nil)
    end)
  end

  defp recalculate({:stay_c, _, s, o, _} = c, w) do
    w1 = set_var_field(o, :walk_strength, s, w)
    w2 = set_var_field(o, :stay, not is_input(c), w1)
    out_v = get_var(o, w2)
    if out_v.stay, do: execute(get_con(con_id(c), w2), w2), else: w2
  end

  defp recalculate({:edit_c, _, s, o, _} = c, w) do
    w1 = set_var_field(o, :walk_strength, s, w)
    w2 = set_var_field(o, :stay, not is_input(c), w1)
    out_v = get_var(o, w2)
    if out_v.stay, do: execute(get_con(con_id(c), w2), w2), else: w2
  end

  defp recalculate({:eq_c, _, s, v1, v2, d} = c, w) do
    {ihn, out_id} = if d == :forward, do: {v1, v2}, else: {v2, v1}
    ihn_v = get_var(ihn, w)
    new_ws = strength_weakest(s, ihn_v.walk_strength)
    w1 = set_var_field(out_id, :walk_strength, new_ws, w)
    w2 = set_var_field(out_id, :stay, ihn_v.stay, w1)
    out_v = get_var(out_id, w2)
    if out_v.stay, do: execute(get_con(con_id(c), w2), w2), else: w2
  end

  defp recalculate({:scale_c, _, s, v1, v2, sc, of, d} = c, w) do
    {ihn, out_id} = if d == :forward, do: {v1, v2}, else: {v2, v1}
    ihn_v = get_var(ihn, w)
    new_ws = strength_weakest(s, ihn_v.walk_strength)
    w1 = set_var_field(out_id, :walk_strength, new_ws, w)
    sc_v = get_var(sc, w1)
    of_v = get_var(of, w1)
    stay = ihn_v.stay and sc_v.stay and of_v.stay
    w2 = set_var_field(out_id, :stay, stay, w1)
    out_v = get_var(out_id, w2)
    if out_v.stay, do: execute(get_con(con_id(c), w2), w2), else: w2
  end

  defp execute({:stay_c, _, _, _, _}, w), do: w
  defp execute({:edit_c, _, _, _, _}, w), do: w

  defp execute({:eq_c, _, _, v1, v2, d}, w) do
    if d == :forward do
      v1v = get_var(v1, w)
      set_var_field(v2, :value, v1v.value, w)
    else
      v2v = get_var(v2, w)
      set_var_field(v1, :value, v2v.value, w)
    end
  end

  defp execute({:scale_c, _, _, v1, v2, sc, of, d}, w) do
    v1v = get_var(v1, w)
    v2v = get_var(v2, w)
    sc_v = get_var(sc, w)
    of_v = get_var(of, w)

    if d == :forward do
      val = v1v.value * sc_v.value + of_v.value
      set_var_field(v2, :value, val, w)
    else
      val = div(v2v.value - of_v.value, sc_v.value)
      set_var_field(v1, :value, val, w)
    end
  end

  # ---------- Constraint constructors ----------
  defp new_stay(var_id, strength, w) do
    {id, w1} = new_id(w)
    c = {:stay_c, id, strength, var_id, false}
    w2 = put_con(c, w1)
    add_constraint(c, w2)
  end

  defp new_edit(var_id, strength, w) do
    {id, w1} = new_id(w)
    c = {:edit_c, id, strength, var_id, false}
    w2 = put_con(c, w1)
    {c, add_constraint(c, w2)}
  end

  defp new_equality(v1, v2, strength, w) do
    {id, w1} = new_id(w)
    c = {:eq_c, id, strength, v1, v2, nil}
    w2 = put_con(c, w1)
    add_constraint(c, w2)
  end

  defp new_scale(src, sc, of, dst, strength, w) do
    {id, w1} = new_id(w)
    c = {:scale_c, id, strength, src, dst, sc, of, nil}
    w2 = put_con(c, w1)
    add_constraint(c, w2)
  end

  # ---------- Planner operations ----------
  defp add_constraint(c, w0) do
    w1 = add_to_graph(c, w0)
    incremental_add(c, w1)
  end

  defp incremental_add(c, w0) do
    {mark, w1} = new_mark(w0)
    {overridden, w2} = satisfy(c, mark, w1)
    incremental_add_loop(overridden, mark, w2)
  end

  defp incremental_add_loop(nil, _mark, w), do: w

  defp incremental_add_loop(c, mark, w0) do
    {overridden, w1} = satisfy(c, mark, w0)
    incremental_add_loop(overridden, mark, w1)
  end

  defp satisfy(c, mark, w0) do
    w1 = choose_method(c, mark, w0)
    c1 = get_con(con_id(c), w1)

    if is_satisfied(c1) do
      inputs = inputs_list(c1)

      w2 =
        Enum.reduce(inputs, w1, fn vid, w_a ->
          set_var_field(vid, :mark, mark, w_a)
        end)

      out_id = output(c1)
      out_v = get_var(out_id, w2)
      overridden = out_v.determined_by

      w3 =
        case overridden do
          nil ->
            w2

          ov_id ->
            ov_c = get_con(ov_id, w2)
            put_con(mark_unsatisfied(ov_c), w2)
        end

      w4 = set_var_field(out_id, :determined_by, con_id(c1), w3)
      {ok?, w5} = add_propagate(c1, mark, w4)

      if ok? do
        w6 = set_var_field(out_id, :mark, mark, w5)

        ov_final =
          case overridden do
            nil -> nil
            ov_id2 -> get_con(ov_id2, w6)
          end

        {ov_final, w6}
      else
        raise "Cycle encountered adding: Constraint removed"
      end
    else
      if con_strength(c1) == @str_required do
        raise "Failed to satisfy a required constraint"
      else
        {nil, w1}
      end
    end
  end

  defp add_propagate(c, mark, w), do: add_propagate_loop([c], c, mark, w)

  defp add_propagate_loop([], _orig, _mark, w), do: {true, w}

  defp add_propagate_loop([d | rest], orig, mark, w0) do
    d_id = con_id(d)
    d_cur = get_con(d_id, w0)
    out_id = output(d_cur)
    out_v = get_var(out_id, w0)

    if out_v.mark == mark do
      w1 = incremental_remove(orig, w0)
      {false, w1}
    else
      w1 = recalculate(d_cur, w0)
      d_cur_after = get_con(d_id, w1)
      out_after = output(d_cur_after)
      more = constraints_consuming(out_after, w1)
      add_propagate_loop(rest ++ more, orig, mark, w1)
    end
  end

  defp incremental_remove(c, w0) do
    out_id = output(c)
    cur = get_con(con_id(c), w0)
    cur1 = mark_unsatisfied(cur)
    w1 = put_con(cur1, w0)
    w2 = remove_from_graph(cur1, w1)
    {unsat, w3} = remove_propagate_from(out_id, w2)
    unsat_sorted = Enum.sort(unsat, &strength_stronger(con_strength(&1), con_strength(&2)))
    Enum.reduce(unsat_sorted, w3, fn u, w_a -> incremental_add(u, w_a) end)
  end

  defp remove_propagate_from(out_v_id, w0) do
    w1 = set_var_field(out_v_id, :determined_by, nil, w0)
    w2 = set_var_field(out_v_id, :walk_strength, @str_abs_weakest, w1)
    w3 = set_var_field(out_v_id, :stay, true, w2)
    remove_prop_loop([out_v_id], [], w3)
  end

  defp remove_prop_loop([], unsat, w), do: {unsat, w}

  defp remove_prop_loop([vid | rest], unsat, w0) do
    v = get_var(vid, w0)

    unsat1 =
      Enum.reduce(v.constraints, unsat, fn cid, acc ->
        c = get_con(cid, w0)
        if is_satisfied(c), do: acc, else: acc ++ [c]
      end)

    cons = constraints_consuming_for_var(vid, w0)

    {new_todo, w1} =
      Enum.reduce(cons, {[], w0}, fn c, {t_acc, w_a} ->
        w_b = recalculate(c, w_a)
        c_after = get_con(con_id(c), w_b)
        {t_acc ++ [output(c_after)], w_b}
      end)

    remove_prop_loop(rest ++ new_todo, unsat1, w1)
  end

  defp constraints_consuming_for_var(vid, w) do
    v = get_var(vid, w)
    dc = v.determined_by

    Enum.flat_map(v.constraints, fn cid ->
      c = get_con(cid, w)
      if cid != dc and is_satisfied(c), do: [c], else: []
    end)
  end

  defp constraints_consuming(out_v_id, w), do: constraints_consuming_for_var(out_v_id, w)

  # ---------- Plans ----------
  defp extract_plan_from_constraints(cs, w) when is_list(cs) do
    sources =
      Enum.flat_map(cs, fn c0 ->
        c = get_con(con_id(c0), w)
        if is_input(c) and is_satisfied(c), do: [c], else: []
      end)

    make_plan(sources, w)
  end

  defp make_plan(sources, w0) do
    {mark, w1} = new_mark(w0)
    make_plan_loop(sources, [], mark, w1)
  end

  defp make_plan_loop([], plan, _mark, w), do: {plan, w}

  defp make_plan_loop([c | rest], plan, mark, w0) do
    out_id = output(c)
    out_v = get_var(out_id, w0)

    if out_v.mark != mark and inputs_known(c, mark, w0) do
      plan1 = plan ++ [c]
      w1 = set_var_field(out_id, :mark, mark, w0)
      more = constraints_consuming(out_id, w1)
      make_plan_loop(rest ++ more, plan1, mark, w1)
    else
      make_plan_loop(rest, plan, mark, w0)
    end
  end

  defp execute_plan(plan, w) do
    Enum.reduce(plan, w, fn c, w_a ->
      c_cur = get_con(con_id(c), w_a)
      execute(c_cur, w_a)
    end)
  end

  # ---------- change_var, destroy_constraint ----------
  defp change_var(var_id, val, w0) do
    {edit_c, w1} = new_edit(var_id, @str_preferred, w0)
    {plan, w2} = extract_plan_from_constraints([edit_c], w1)

    w3 =
      Enum.reduce(1..10, w2, fn _, w_a ->
        w_b = set_var_field(var_id, :value, val, w_a)
        execute_plan(plan, w_b)
      end)

    destroy_constraint(edit_c, w3)
  end

  defp destroy_constraint(c, w0) do
    cur = get_con(con_id(c), w0)
    w1 = if is_satisfied(cur), do: incremental_remove(cur, w0), else: w0
    cur1 = get_con(con_id(c), w1)
    remove_from_graph(cur1, w1)
  end

  # ---------- Tests ----------
  defp chain_test(n) do
    w0 = new_world()
    {var_ids, w1} = create_vars(n + 1, w0)
    w2 = add_chain_eqs(var_ids, w1)
    last = List.last(var_ids)
    first = hd(var_ids)
    w3 = new_stay(last, @str_strong_default, w2)
    {edit, w4} = new_edit(first, @str_preferred, w3)
    {plan, w5} = extract_plan_from_constraints([edit], w4)

    w6 =
      Enum.reduce(1..100, w5, fn v, w_a ->
        w_b = set_var_field(first, :value, v, w_a)
        w_c = execute_plan(plan, w_b)
        last_v = get_var(last, w_c)

        if last_v.value == v do
          w_c
        else
          raise "Chain test failed: expected #{v}, got #{last_v.value}"
        end
      end)

    _ = destroy_constraint(edit, w6)
    :ok
  end

  defp create_vars(0, w), do: {[], w}

  defp create_vars(n, w0) do
    {id, w1} = new_var(w0)
    {rest, w2} = create_vars(n - 1, w1)
    {[id | rest], w2}
  end

  # Pairwise walk over the chain — O(N) instead of O(N²) with Enum.at.
  defp add_chain_eqs([_], w), do: w

  defp add_chain_eqs([v1, v2 | rest], w0) do
    w1 = new_equality(v1, v2, @str_required, w0)
    add_chain_eqs([v2 | rest], w1)
  end

  defp projection_test(n) do
    w0 = new_world()
    {scale, w1} = new_var_with(10, w0)
    {offset, w2} = new_var_with(1000, w1)
    {dests, src, dst, w3} = create_proj_loop(1, n, [], nil, nil, scale, offset, w2)

    w4 = change_var(src, 17, w3)
    dst_v1 = get_var(dst, w4)
    if dst_v1.value != 1170, do: raise("Projection 1 failed: #{dst_v1.value}")

    w5 = change_var(dst, 1050, w4)
    src_v1 = get_var(src, w5)
    if src_v1.value != 5, do: raise("Projection 2 failed: #{src_v1.value}")

    w6 = change_var(scale, 5, w5)
    dests_list = Enum.reverse(dests)
    check_dests(dests_list, 0, n - 1, fn i -> (i + 1) * 5 + 1000 end, "Projection 3", w6)

    w7 = change_var(offset, 2000, w6)
    check_dests(dests_list, 0, n - 1, fn i -> (i + 1) * 5 + 2000 end, "Projection 4", w7)

    :ok
  end

  defp create_proj_loop(i, n, dests, src, dst, _scale, _offset, w) when i > n do
    {dests, src, dst, w}
  end

  defp create_proj_loop(i, n, dests, _src_old, _dst_old, scale, offset, w0) do
    {src, w1} = new_var_with(i, w0)
    {dst, w2} = new_var_with(i, w1)
    dests1 = [dst | dests]
    w3 = new_stay(src, @str_default, w2)
    w4 = new_scale(src, scale, offset, dst, @str_required, w3)
    create_proj_loop(i + 1, n, dests1, src, dst, scale, offset, w4)
  end

  # Walk the dests list directly — O(N) instead of O(N²).
  defp check_dests(_dests, i, stop, _exp_fn, _tag, _w) when i >= stop, do: :ok

  defp check_dests([dst | rest], i, stop, exp_fn, tag, w) do
    dst_v = get_var(dst, w)
    expected = exp_fn.(i)

    if dst_v.value == expected do
      check_dests(rest, i + 1, stop, exp_fn, tag, w)
    else
      raise "#{tag} failed at i=#{i}: expected #{expected}, got #{dst_v.value}"
    end
  end

end
