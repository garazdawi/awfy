# SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: MIT

defmodule Awfy.Benchmarks.Havlak do
  @moduledoc """
  Havlak — translated from upstream/benchmarks/Ruby/havlak.rb.

  Loop recognition algorithm: build a control-flow graph, then identify
  loops via a union-find based reducibility analysis. The implementation
  shape mirrors the Erlang port (`awfy_havlak.erl`): every "object"
  becomes a record/struct with an integer id, mutation becomes
  state-threaded updates through maps keyed by id.

  Verification thresholds:

      inner_iter=1     -> [1605, 5213]
      inner_iter=15    -> [1647, 5213]
      inner_iter=150   -> [2052, 5213]
  """

  use Awfy.Benchmark

  @unvisited 2_147_483_647
  @max_non_back_preds 32 * 1024

  defmodule BB do
    defstruct name: nil, in_edges: [], out_edges: []
  end

  defmodule SimpleLoop do
    defstruct id: nil,
              is_reducible: nil,
              is_root: false,
              nesting_level: 0,
              depth_level: 0,
              counter: 0,
              parent: nil,
              children: %{},
              basic_blocks: %{},
              header: nil
  end

  defmodule Uf do
    defstruct id: nil, bb: nil, dfs_number: 0, parent_id: nil, loop_id: nil
  end

  defmodule Cfg do
    defstruct start_node: nil, basic_block_map: %{}, bb_order: []
  end

  defmodule Lsg do
    defstruct loop_counter: 0, loops: [], loops_by_id: %{}, root_id: nil
  end

  defmodule Hf do
    defstruct cfg: nil,
              lsg: nil,
              non_back_preds: %{},
              back_preds: %{},
              number: %{},
              max_size: 0,
              header: nil,
              type: nil,
              last: nil,
              nodes: %{},
              nodes_by_w: %{}
  end

  def name, do: "Havlak"

  def benchmark, do: :ok

  def inner_benchmark_loop(inner_iter) do
    result = run_loop_tester(inner_iter, 50, 10, 10, 5)
    verify_result(result, inner_iter)
  end

  def verify_result([1605, 5213], 1), do: true
  def verify_result([1647, 5213], 15), do: true
  def verify_result([2052, 5213], 150), do: true
  def verify_result([6102, 5213], 1500), do: true
  def verify_result([46602, 5213], 15000), do: true
  def verify_result(_, _), do: false

  defp run_loop_tester(inner_iter, _sz1, par_loops, ppar_loops, pppar_loops) do
    cfg0 = %Cfg{}
    cfg1 = create_node(0, cfg0)
    lsg0 = lsg_new()

    {cfg2, _} = build_base_loop(0, cfg1)
    cfg3 = create_node(1, cfg2)
    {cfg4, _} = make_edge(0, 2, cfg3)

    lsg1 = add_dummy_loops(inner_iter, cfg4, lsg0)

    {cfg5, _} = construct_cfg(cfg4, par_loops, ppar_loops, pppar_loops)

    lsg2 = find_loops_into(cfg5, lsg1)

    discard_loops(50, cfg5)

    lsg3 = calculate_nesting_level(lsg2)
    [num_loops(lsg3), num_nodes(cfg5)]
  end

  # ---------- CFG ----------
  defp create_node(name, %Cfg{basic_block_map: m, bb_order: o} = cfg) do
    if Map.has_key?(m, name) do
      cfg
    else
      bb = %BB{name: name}
      m1 = Map.put(m, name, bb)
      cfg1 = %{cfg | basic_block_map: m1, bb_order: o ++ [name]}

      if map_size(m1) == 1 do
        %{cfg1 | start_node: name}
      else
        cfg1
      end
    end
  end

  defp num_nodes(%Cfg{basic_block_map: m}), do: map_size(m)

  defp make_edge(from, to, cfg0) do
    cfg1 = create_node(from, cfg0)
    cfg2 = create_node(to, cfg1)
    bb_from = Map.fetch!(cfg2.basic_block_map, from)
    bb_to = Map.fetch!(cfg2.basic_block_map, to)
    bb_from1 = %{bb_from | out_edges: bb_from.out_edges ++ [to]}
    bb_to1 = %{bb_to | in_edges: bb_to.in_edges ++ [from]}

    m =
      cfg2.basic_block_map
      |> Map.put(from, bb_from1)
      |> Map.put(to, bb_to1)

    {%{cfg2 | basic_block_map: m}, :ok}
  end

  # ---------- LoopTesterApp helpers ----------
  defp build_diamond(start, cfg0) do
    {cfg1, _} = make_edge(start, start + 1, cfg0)
    {cfg2, _} = make_edge(start, start + 2, cfg1)
    {cfg3, _} = make_edge(start + 1, start + 3, cfg2)
    {cfg4, _} = make_edge(start + 2, start + 3, cfg3)
    {cfg4, start + 3}
  end

  defp build_straight(start, n, cfg0) do
    cfg1 = build_straight_loop(0, n, start, cfg0)
    {cfg1, start + n}
  end

  defp build_straight_loop(i, n, _start, cfg) when i >= n, do: cfg

  defp build_straight_loop(i, n, start, cfg0) do
    {cfg1, _} = make_edge(start + i, start + i + 1, cfg0)
    build_straight_loop(i + 1, n, start, cfg1)
  end

  defp build_base_loop(from, cfg0) do
    {cfg1, header} = build_straight(from, 1, cfg0)
    {cfg2, diamond1} = build_diamond(header, cfg1)
    {cfg3, d11} = build_straight(diamond1, 1, cfg2)
    {cfg4, diamond2} = build_diamond(d11, cfg3)
    {cfg5, footer} = build_straight(diamond2, 1, cfg4)
    {cfg6, _} = make_edge(diamond2, d11, cfg5)
    {cfg7, _} = make_edge(diamond1, header, cfg6)
    {cfg8, _} = make_edge(footer, from, cfg7)
    build_straight(footer, 1, cfg8)
  end

  defp construct_cfg(cfg0, par, ppar, pppar) do
    construct_cfg_par(0, par, ppar, pppar, 2, cfg0)
  end

  defp construct_cfg_par(i, par, _ppar, _pppar, n, cfg) when i >= par, do: {cfg, n}

  defp construct_cfg_par(i, par, ppar, pppar, n, cfg0) do
    cfg1 = create_node(n + 1, cfg0)
    {cfg2, _} = make_edge(2, n + 1, cfg1)
    n2 = n + 1
    {cfg3, n3} = construct_cfg_ppar(0, ppar, pppar, n2, cfg2)
    {cfg4, _} = make_edge(n3, 1, cfg3)
    construct_cfg_par(i + 1, par, ppar, pppar, n3, cfg4)
  end

  defp construct_cfg_ppar(i, ppar, _pppar, n, cfg) when i >= ppar, do: {cfg, n}

  defp construct_cfg_ppar(i, ppar, pppar, n, cfg0) do
    top = n
    {cfg1, n1} = build_straight(n, 1, cfg0)
    {cfg2, n2} = construct_cfg_pppar(0, pppar, n1, cfg1)
    {cfg3, bottom} = build_straight(n2, 1, cfg2)
    {cfg4, _} = make_edge(n2, top, cfg3)
    construct_cfg_ppar(i + 1, ppar, pppar, bottom, cfg4)
  end

  defp construct_cfg_pppar(i, pppar, n, cfg) when i >= pppar, do: {cfg, n}

  defp construct_cfg_pppar(i, pppar, n, cfg0) do
    {cfg1, n1} = build_base_loop(n, cfg0)
    construct_cfg_pppar(i + 1, pppar, n1, cfg1)
  end

  # ---------- LoopStructureGraph ----------
  defp lsg_new do
    root = %SimpleLoop{
      id: 0,
      is_reducible: true,
      nesting_level: 0,
      depth_level: 0,
      counter: 0,
      is_root: true
    }

    %Lsg{
      loop_counter: 1,
      loops: [root],
      loops_by_id: %{0 => root},
      root_id: 0
    }
  end

  defp create_new_loop(bb, is_reducible, %Lsg{loop_counter: c, loops: ls, loops_by_id: m} = lsg) do
    loop = %SimpleLoop{
      id: c,
      is_reducible: is_reducible,
      counter: c,
      header: bb,
      basic_blocks:
        case bb do
          nil -> %{}
          _ -> %{bb => true}
        end
    }

    {loop,
     %{lsg | loop_counter: c + 1, loops: [loop | ls], loops_by_id: Map.put(m, c, loop)}}
  end

  defp put_loop(%SimpleLoop{id: id} = loop, lsg) do
    %{lsg | loops_by_id: Map.put(lsg.loops_by_id, id, loop)}
  end

  defp num_loops(%Lsg{loops_by_id: m}), do: map_size(m)

  defp calculate_nesting_level(lsg) do
    root_id = lsg.root_id

    lsg1 =
      Enum.reduce(Map.values(lsg.loops_by_id), lsg, fn
        %SimpleLoop{id: id, is_root: false, parent: nil}, acc ->
          set_parent(id, root_id, acc)

        _, acc ->
          acc
      end)

    calc_nest_rec(root_id, 0, lsg1)
  end

  defp calc_nest_rec(loop_id, depth, lsg) do
    loop0 = Map.fetch!(lsg.loops_by_id, loop_id)
    loop1 = %{loop0 | depth_level: depth}
    lsg1 = put_loop(loop1, lsg)
    children = Map.keys(loop1.children)

    {lsg2, max_nl} =
      Enum.reduce(children, {lsg1, 0}, fn ch_id, {lsg_a, max_nl_a} ->
        lsg_b = calc_nest_rec(ch_id, depth + 1, lsg_a)
        ch_loop = Map.fetch!(lsg_b.loops_by_id, ch_id)
        {lsg_b, max(max_nl_a, 1 + ch_loop.nesting_level)}
      end)

    loop2 = Map.fetch!(lsg2.loops_by_id, loop_id)
    loop3 = %{loop2 | nesting_level: max_nl, is_root: max_nl == 0}
    put_loop(loop3, lsg2)
  end

  defp set_parent(child_id, parent_id, lsg) do
    child0 = Map.fetch!(lsg.loops_by_id, child_id)
    child1 = %{child0 | parent: parent_id}
    parent0 = Map.fetch!(lsg.loops_by_id, parent_id)
    parent1 = %{parent0 | children: Map.put(parent0.children, child_id, true)}

    m =
      lsg.loops_by_id
      |> Map.put(child_id, child1)
      |> Map.put(parent_id, parent1)

    %{lsg | loops_by_id: m}
  end

  # ---------- Loop finder ----------
  defp add_dummy_loops(0, _cfg, lsg), do: lsg

  defp add_dummy_loops(n, cfg, lsg) do
    lsg1 = find_loops_into(cfg, lsg)
    add_dummy_loops(n - 1, cfg, lsg1)
  end

  defp discard_loops(0, _cfg), do: :ok

  defp discard_loops(n, cfg) do
    _ = find_loops_into(cfg, lsg_new())
    discard_loops(n - 1, cfg)
  end

  defp find_loops_into(cfg, lsg) do
    case cfg.start_node do
      nil ->
        lsg

      _ ->
        hf0 = %Hf{cfg: cfg, lsg: lsg}
        hf1 = find_loops(hf0)
        hf1.lsg
    end
  end

  defp find_loops(hf0) do
    cfg = hf0.cfg
    size = num_nodes(cfg)
    hf1 = %{hf0 | non_back_preds: %{}, back_preds: %{}, number: %{}}

    hf2 =
      if size > hf1.max_size do
        %{
          hf1
          | header: :array.new(size, default: 0),
            type: :array.new(size, default: :BB_NONHEADER),
            last: :array.new(size, default: 0),
            max_size: size
        }
      else
        hf1
      end

    hf3 = init_size_arrays(0, size, hf2)
    hf4 = init_all_nodes(hf3)
    hf5 = identify_edges(0, size, hf4)
    hf6 = %{hf5 | header: :array.set(0, 0, hf5.header)}
    main_loop(size - 1, hf6)
  end

  defp init_size_arrays(i, size, hf) when i >= size, do: hf

  defp init_size_arrays(i, size, hf) do
    nbp1 = Map.put(hf.non_back_preds, i, :sets.new(version: 2))
    bp1 = Map.put(hf.back_preds, i, [])
    uf_id = i
    uf = %Uf{id: uf_id, parent_id: uf_id}
    nodes1 = Map.put(hf.nodes, uf_id, uf)
    nodes_by_w1 = Map.put(hf.nodes_by_w, i, uf_id)

    init_size_arrays(i + 1, size, %{
      hf
      | non_back_preds: nbp1,
        back_preds: bp1,
        nodes: nodes1,
        nodes_by_w: nodes_by_w1
    })
  end

  defp init_all_nodes(hf) do
    number0 =
      Enum.reduce(hf.cfg.bb_order, hf.number, fn name, acc ->
        Map.put(acc, name, @unvisited)
      end)

    hf1 = %{hf | number: number0}
    start = hf1.cfg.start_node
    {_, hf2} = do_dfs(start, 0, hf1)
    hf2
  end

  defp do_dfs(bb_name, current, hf0) do
    uf_id = Map.fetch!(hf0.nodes_by_w, current)
    uf0 = Map.fetch!(hf0.nodes, uf_id)
    uf1 = %{uf0 | parent_id: uf_id, bb: bb_name, dfs_number: current, loop_id: nil}
    hf1 = %{hf0 | nodes: Map.put(hf0.nodes, uf_id, uf1)}
    hf2 = %{hf1 | number: Map.put(hf1.number, bb_name, current)}
    bb = Map.fetch!(hf2.cfg.basic_block_map, bb_name)

    {last_id, hf3} =
      Enum.reduce(bb.out_edges, {current, hf2}, fn target, {last_id_a, hf_a} ->
        case Map.fetch!(hf_a.number, target) do
          @unvisited -> do_dfs(target, last_id_a + 1, hf_a)
          _ -> {last_id_a, hf_a}
        end
      end)

    hf4 = %{hf3 | last: :array.set(current, last_id, hf3.last)}
    {last_id, hf4}
  end

  defp identify_edges(w, size, hf) when w >= size, do: hf

  defp identify_edges(w, size, hf0) do
    hf1 = %{
      hf0
      | header: :array.set(w, 0, hf0.header),
        type: :array.set(w, :BB_NONHEADER, hf0.type)
    }

    uf_id = Map.fetch!(hf1.nodes_by_w, w)
    uf = Map.fetch!(hf1.nodes, uf_id)

    hf2 =
      case uf.bb do
        nil -> %{hf1 | type: :array.set(w, :BB_DEAD, hf1.type)}
        bb_name -> process_edges(bb_name, w, hf1)
      end

    identify_edges(w + 1, size, hf2)
  end

  defp process_edges(bb_name, w, hf) do
    bb = Map.fetch!(hf.cfg.basic_block_map, bb_name)

    case bb.in_edges do
      [] ->
        hf

      _ ->
        Enum.reduce(bb.in_edges, hf, fn node_v, hf_a ->
          v = Map.fetch!(hf_a.number, node_v)

          case v do
            @unvisited ->
              hf_a

            _ ->
              if is_ancestor(w, v, hf_a) do
                bp_w = Map.fetch!(hf_a.back_preds, w)
                %{hf_a | back_preds: Map.put(hf_a.back_preds, w, bp_w ++ [v])}
              else
                nbp_w = Map.fetch!(hf_a.non_back_preds, w)

                %{
                  hf_a
                  | non_back_preds:
                      Map.put(hf_a.non_back_preds, w, :sets.add_element(v, nbp_w))
                }
              end
          end
        end)
    end
  end

  defp is_ancestor(w, v, hf), do: w <= v and v <= :array.get(w, hf.last)

  defp main_loop(w, hf) when w < 0, do: hf

  defp main_loop(w, hf0) do
    uf_id = Map.fetch!(hf0.nodes_by_w, w)
    uf = Map.fetch!(hf0.nodes, uf_id)

    hf1 =
      case uf.bb do
        nil -> hf0
        _ -> process_w(w, hf0)
      end

    main_loop(w - 1, hf1)
  end

  defp process_w(w, hf0) do
    {node_pool0, hf1} = step_d(w, [], hf0)
    work_list0 = node_pool0

    hf2 =
      if node_pool0 == [] do
        hf1
      else
        %{hf1 | type: :array.set(w, :BB_REDUCIBLE, hf1.type)}
      end

    {node_pool1, hf3} = drain_worklist(w, node_pool0, work_list0, hf2)
    uf_w_id = Map.fetch!(hf3.nodes_by_w, w)
    uf_w = Map.fetch!(hf3.nodes, uf_w_id)

    if length(node_pool1) > 0 or :array.get(w, hf3.type) == :BB_SELF do
      {loop, lsg1} =
        create_new_loop(uf_w.bb, :array.get(w, hf3.type) != :BB_IRREDUCIBLE, hf3.lsg)

      hf4 = %{hf3 | lsg: lsg1}
      set_loop_attrs(w, node_pool1, loop, hf4)
    else
      hf3
    end
  end

  defp drain_worklist(_w, node_pool, [], hf), do: {node_pool, hf}

  defp drain_worklist(w, node_pool0, [x | rest], hf0) do
    non_back_size = :sets.size(Map.fetch!(hf0.non_back_preds, x.dfs_number))

    if non_back_size > @max_non_back_preds do
      {node_pool0, hf0}
    else
      {node_pool1, new_work, hf1} = step_e(w, x, node_pool0, hf0)
      drain_worklist(w, node_pool1, rest ++ new_work, hf1)
    end
  end

  defp step_e(w, x, node_pool0, hf0) do
    nbp_set = Map.fetch!(hf0.non_back_preds, x.dfs_number)
    iter = :sets.to_list(nbp_set)

    Enum.reduce(iter, {node_pool0, [], hf0}, fn i, {np, nw, hf_a} ->
      y_id = Map.fetch!(hf_a.nodes_by_w, i)
      {y_dash, hf_b} = find_set(y_id, hf_a)

      if is_ancestor(w, y_dash.dfs_number, hf_b) do
        if y_dash.dfs_number != w do
          if Enum.any?(np, fn n -> n.id == y_dash.id end) do
            {np, nw, hf_b}
          else
            {np ++ [y_dash], nw ++ [y_dash], hf_b}
          end
        else
          {np, nw, hf_b}
        end
      else
        hf_c = %{
          hf_b
          | type: :array.set(w, :BB_IRREDUCIBLE, hf_b.type),
            non_back_preds:
              Map.put(
                hf_b.non_back_preds,
                w,
                :sets.add_element(y_dash.dfs_number, Map.fetch!(hf_b.non_back_preds, w))
              )
        }

        {np, nw, hf_c}
      end
    end)
  end

  defp step_d(w, node_pool, hf) do
    bps = Map.fetch!(hf.back_preds, w)

    Enum.reduce(bps, {node_pool, hf}, fn v, {np, hf_a} ->
      if v != w do
        uf_v_id = Map.fetch!(hf_a.nodes_by_w, v)
        {found, hf_b} = find_set(uf_v_id, hf_a)
        {np ++ [found], hf_b}
      else
        {np, %{hf_a | type: :array.set(w, :BB_SELF, hf_a.type)}}
      end
    end)
  end

  defp find_set(node_id, hf) do
    node = Map.fetch!(hf.nodes, node_id)
    {path, root, hf1} = climb(node, [], hf)

    hf2 =
      Enum.reduce(path, hf1, fn n, hf_a ->
        n1 = %{n | parent_id: node.parent_id}
        %{hf_a | nodes: Map.put(hf_a.nodes, n1.id, n1)}
      end)

    {root, hf2}
  end

  defp climb(node, path, hf) do
    if node.parent_id == node.id do
      {path, node, hf}
    else
      parent = Map.fetch!(hf.nodes, node.parent_id)

      path1 =
        if parent.parent_id != parent.id do
          path ++ [node]
        else
          path
        end

      climb(parent, path1, hf)
    end
  end

  defp set_loop_attrs(w, node_pool, loop, hf) do
    uf_w_id = Map.fetch!(hf.nodes_by_w, w)
    uf_w0 = Map.fetch!(hf.nodes, uf_w_id)
    uf_w1 = %{uf_w0 | loop_id: loop.id}
    hf1 = %{hf | nodes: Map.put(hf.nodes, uf_w_id, uf_w1)}

    Enum.reduce(node_pool, hf1, fn node, hf_a ->
      dfs = node.dfs_number
      hf_a1 = %{hf_a | header: :array.set(dfs, w, hf_a.header)}
      cur_node = Map.fetch!(hf_a1.nodes, node.id)
      node1 = %{cur_node | parent_id: uf_w_id}
      hf_a2 = %{hf_a1 | nodes: Map.put(hf_a1.nodes, node1.id, node1)}

      case node1.loop_id do
        nil ->
          cur_loop = Map.fetch!(hf_a2.lsg.loops_by_id, loop.id)
          loop1 = %{cur_loop | basic_blocks: Map.put(cur_loop.basic_blocks, node1.bb, true)}
          %{hf_a2 | lsg: put_loop(loop1, hf_a2.lsg)}

        child_id ->
          lsg1 = set_parent(child_id, loop.id, hf_a2.lsg)
          %{hf_a2 | lsg: lsg1}
      end
    end)
  end
end
