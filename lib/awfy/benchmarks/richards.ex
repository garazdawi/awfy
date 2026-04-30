defmodule Awfy.Benchmarks.Richards do
  @moduledoc """
  Richards — translated from upstream/benchmarks/Ruby/richards.rb.

  OS task scheduler simulation. The Ruby version is heavily mutation-
  based: linked lists of TaskControlBlocks and Packets, each with
  mutable .link fields, plus per-task private data records that mutate
  during execution. Translating to BEAM: every "object" gets an integer
  id; the scheduler state holds a `tasks` map and a `packets` map;
  "mutation" puts an updated record back in the map.

  Polymorphic dispatch (different per-task closures from the four
  create_* methods) is preserved as fun-valued fields on the
  task-control-block struct — exactly the BEAM analogue of Ruby's
  `function.call(...)`.

  Critical detail: Ruby's TaskState exposes both granular setters
  (attr_writer for each flag) and full state-setter methods
  (running/packet_pending/waiting). Scheduler#wait/hold_self/release
  use the granular setters — they only flip ONE flag. Inside run_task,
  the state-setter methods are used to flip multiple flags. Confusing
  these costs an hour of debugging. (Ask me how I know.)
  """

  use Awfy.Benchmark

  @idler 0
  @worker 1
  @handler_a 2
  @handler_b 3
  @device_a 4
  @device_b 5
  @num_types 6

  @device_packet_kind 0
  @work_packet_kind 1

  @data_size 4

  @no_task nil
  @no_work nil

  defmodule Packet do
    defstruct link: nil, kind: nil, identity: nil, datum: 0, data: {0, 0, 0, 0}
  end

  defmodule TCB do
    defstruct link: nil,
              identity: nil,
              function: nil,
              priority: nil,
              input: nil,
              handle: nil,
              task_holding: false,
              task_waiting: false,
              packet_pending: false
  end

  defmodule DeviceData, do: defstruct(pending: nil)
  defmodule HandlerData, do: defstruct(work_in: nil, device_in: nil)
  defmodule IdleData, do: defstruct(control: 1, count: 10_000)
  defmodule WorkerData, do: defstruct(destination: 2, count: 0)

  defmodule State do
    defstruct task_list: nil,
              current_task: nil,
              current_task_identity: 0,
              task_table: {nil, nil, nil, nil, nil, nil},
              queue_count: 0,
              hold_count: 0,
              tasks: %{},
              packets: %{},
              next_packet_ref: 0
  end

  def name, do: "Richards"

  def verify_result(result), do: result

  def benchmark, do: start_scheduler()

  defp start_scheduler do
    s0 = %State{}
    s1 = create_idler(@idler, 0, @no_work, ts_running(), s0)
    {wkq1, s2} = create_packet_state(@no_work, @worker, @work_packet_kind, s1)
    {wkq2, s3} = create_packet_state(wkq1, @worker, @work_packet_kind, s2)
    s4 = create_worker(@worker, 1000, wkq2, ts_waiting_with_packet(), s3)
    {wkq_a1, s5} = create_packet_state(@no_work, @device_a, @device_packet_kind, s4)
    {wkq_a2, s6} = create_packet_state(wkq_a1, @device_a, @device_packet_kind, s5)
    {wkq_a3, s7} = create_packet_state(wkq_a2, @device_a, @device_packet_kind, s6)
    s8 = create_handler(@handler_a, 2000, wkq_a3, ts_waiting_with_packet(), s7)
    {wkq_b1, s9} = create_packet_state(@no_work, @device_b, @device_packet_kind, s8)
    {wkq_b2, s10} = create_packet_state(wkq_b1, @device_b, @device_packet_kind, s9)
    {wkq_b3, s11} = create_packet_state(wkq_b2, @device_b, @device_packet_kind, s10)
    s12 = create_handler(@handler_b, 3000, wkq_b3, ts_waiting_with_packet(), s11)
    s13 = create_device(@device_a, 4000, @no_work, ts_waiting(), s12)
    s14 = create_device(@device_b, 5000, @no_work, ts_waiting(), s13)
    s15 = schedule(s14)
    s15.queue_count == 23_246 and s15.hold_count == 9297
  end

  defp ts_running, do: {false, false, false}
  defp ts_waiting, do: {false, true, false}
  defp ts_waiting_with_packet, do: {true, true, false}

  defp create_idler(identity, priority, work, state, s) do
    create_task(identity, priority, work, state, %IdleData{}, &idler_step/3, s)
  end

  defp create_worker(identity, priority, work, state, s) do
    create_task(identity, priority, work, state, %WorkerData{destination: @handler_a}, &worker_step/3, s)
  end

  defp create_handler(identity, priority, work, state, s) do
    create_task(identity, priority, work, state, %HandlerData{}, &handler_step/3, s)
  end

  defp create_device(identity, priority, work, state, s) do
    create_task(identity, priority, work, state, %DeviceData{}, &device_step/3, s)
  end

  defp create_task(identity, priority, work, {pp, tw, th}, data, fun, s) do
    tcb = %TCB{
      link: s.task_list,
      identity: identity,
      function: fun,
      priority: priority,
      input: work,
      handle: data,
      packet_pending: pp,
      task_waiting: tw,
      task_holding: th
    }

    %{
      s
      | task_list: identity,
        tasks: Map.put(s.tasks, identity, tcb),
        task_table: put_elem(s.task_table, identity, identity)
    }
  end

  defp create_packet_state(link_ref, identity, kind, s) do
    ref = s.next_packet_ref
    pkt = %Packet{link: link_ref, identity: identity, kind: kind}
    {ref, %{s | packets: Map.put(s.packets, ref, pkt), next_packet_ref: ref + 1}}
  end

  defp schedule(s), do: schedule_loop(s.task_list, s)

  defp schedule_loop(@no_task, s), do: s

  defp schedule_loop(cur, s) do
    tcb = Map.fetch!(s.tasks, cur)

    if is_task_holding_or_waiting(tcb) do
      schedule_loop(tcb.link, s)
    else
      s1 = %{s | current_task: cur, current_task_identity: tcb.identity}
      {next_cur, s2} = run_task(tcb, s1)
      schedule_loop(next_cur, s2)
    end
  end

  defp is_task_holding_or_waiting(%TCB{task_holding: th, task_waiting: tw, packet_pending: pp}) do
    th or (not pp and tw)
  end

  defp is_waiting_with_packet(%TCB{task_holding: th, task_waiting: tw, packet_pending: pp}) do
    pp and tw and not th
  end

  defp run_task(tcb, s) do
    {message, tcb1, s1} =
      if is_waiting_with_packet(tcb) do
        msg = tcb.input
        msg_pkt = Map.fetch!(s.packets, msg)
        new_input = msg_pkt.link

        new_tcb =
          case new_input do
            @no_work -> state_running(%{tcb | input: new_input})
            _ -> state_packet_pending(%{tcb | input: new_input})
          end

        {msg, new_tcb, s}
      else
        {@no_work, tcb, s}
      end

    s2 = put_tcb(tcb1, s1)
    tcb1.function.(message, tcb1.handle, s2)
  end

  # Multi-flag state setters — only used inside run_task.
  defp state_running(tcb), do: %{tcb | packet_pending: false, task_waiting: false, task_holding: false}
  defp state_packet_pending(tcb), do: %{tcb | packet_pending: true, task_waiting: false, task_holding: false}

  defp put_tcb(tcb, s), do: %{s | tasks: Map.put(s.tasks, tcb.identity, tcb)}

  defp put_handle(s, new_handle) do
    cur = s.current_task
    tcb = Map.fetch!(s.tasks, cur)
    %{s | tasks: Map.put(s.tasks, cur, %{tcb | handle: new_handle})}
  end

  # Granular setter — only flip task_waiting=true.
  defp wait(s) do
    cur = s.current_task
    tcb = Map.fetch!(s.tasks, cur)
    {cur, put_tcb(%{tcb | task_waiting: true}, s)}
  end

  # Granular setter — only flip task_holding=true.
  defp hold_self(s) do
    cur = s.current_task
    tcb = Map.fetch!(s.tasks, cur)
    tcb1 = %{tcb | task_holding: true}
    s1 = put_tcb(tcb1, s)
    {tcb1.link, %{s1 | hold_count: s1.hold_count + 1}}
  end

  # Granular setter — only flip task_holding=false.
  defp release(identity, s) do
    case find_task(identity, s) do
      @no_task ->
        {@no_task, s}

      tcb ->
        tcb1 = %{tcb | task_holding: false}
        s1 = put_tcb(tcb1, s)
        cur_tcb = Map.fetch!(s1.tasks, s.current_task)
        next = if tcb1.priority > cur_tcb.priority, do: tcb1.identity, else: s.current_task
        {next, s1}
    end
  end

  defp queue_packet(pkt_ref, s) do
    pkt = Map.fetch!(s.packets, pkt_ref)

    case find_task(pkt.identity, s) do
      @no_task ->
        {@no_task, s}

      tcb ->
        s1 = %{s | queue_count: s.queue_count + 1}
        pkt1 = %{pkt | link: @no_work, identity: s.current_task_identity}
        s2 = %{s1 | packets: Map.put(s1.packets, pkt_ref, pkt1)}
        cur_tcb = Map.fetch!(s2.tasks, s2.current_task)
        add_input_and_check_priority(tcb, pkt_ref, cur_tcb, s2)
    end
  end

  # Granular: only set packet_pending=true (when input was empty).
  defp add_input_and_check_priority(tcb, pkt_ref, old_task, s) do
    case tcb.input do
      @no_work ->
        tcb1 = %{tcb | input: pkt_ref, packet_pending: true}
        s1 = put_tcb(tcb1, s)
        next = if tcb1.priority > old_task.priority, do: tcb1.identity, else: old_task.identity
        {next, s1}

      head ->
        s1 = %{s | packets: append_packet(pkt_ref, head, s.packets)}
        {old_task.identity, s1}
    end
  end

  defp append_packet(pkt_ref, queue_head, packets0) do
    pkt = Map.fetch!(packets0, pkt_ref)
    packets1 = Map.put(packets0, pkt_ref, %{pkt | link: @no_work})

    case queue_head do
      @no_work -> packets1
      _ -> walk_and_append(queue_head, pkt_ref, packets1)
    end
  end

  defp walk_and_append(mouse_ref, new_ref, packets) do
    mouse = Map.fetch!(packets, mouse_ref)

    case mouse.link do
      @no_work -> Map.put(packets, mouse_ref, %{mouse | link: new_ref})
      next_ref -> walk_and_append(next_ref, new_ref, packets)
    end
  end

  defp find_task(identity, s) do
    case elem(s.task_table, identity) do
      @no_task -> @no_task
      id -> Map.fetch!(s.tasks, id)
    end
  end

  # ---------- Per-task step functions ----------

  defp idler_step(_work, idle_data, s) do
    count = idle_data.count - 1

    cond do
      count == 0 ->
        s1 = put_handle(s, %{idle_data | count: count})
        hold_self(s1)

      Bitwise.band(idle_data.control, 1) == 0 ->
        new_control = div(idle_data.control, 2)
        s1 = put_handle(s, %{idle_data | count: count, control: new_control})
        release(@device_a, s1)

      true ->
        new_control = Bitwise.bxor(div(idle_data.control, 2), 53_256)
        s1 = put_handle(s, %{idle_data | count: count, control: new_control})
        release(@device_b, s1)
    end
  end

  defp worker_step(@no_work, _wd, s), do: wait(s)

  defp worker_step(work_pkt_ref, wd0, s0) do
    dest = if wd0.destination == @handler_a, do: @handler_b, else: @handler_a
    wd1 = %{wd0 | destination: dest}
    pkt0 = Map.fetch!(s0.packets, work_pkt_ref)
    pkt1 = %{pkt0 | identity: dest, datum: 0}
    {wd2, pkt2} = fill_work_data(0, wd1, pkt1)
    s1 = %{s0 | packets: Map.put(s0.packets, work_pkt_ref, pkt2)}
    s2 = put_handle(s1, wd2)
    queue_packet(work_pkt_ref, s2)
  end

  defp fill_work_data(@data_size, wd, pkt), do: {wd, pkt}

  defp fill_work_data(i, wd0, pkt0) do
    count1 = wd0.count + 1
    count2 = if count1 > 26, do: 1, else: count1
    datum = 65 + count2 - 1
    data1 = put_elem(pkt0.data, i, datum)
    fill_work_data(i + 1, %{wd0 | count: count2}, %{pkt0 | data: data1})
  end

  defp handler_step(work_pkt_ref, hd0, s0) do
    {hd1, s1} =
      case work_pkt_ref do
        @no_work ->
          {hd0, s0}

        _ ->
          pkt = Map.fetch!(s0.packets, work_pkt_ref)

          case pkt.kind do
            @work_packet_kind ->
              {new_head, packets1} = append_to_queue(work_pkt_ref, hd0.work_in, s0.packets)
              {%{hd0 | work_in: new_head}, %{s0 | packets: packets1}}

            _ ->
              {new_head, packets1} = append_to_queue(work_pkt_ref, hd0.device_in, s0.packets)
              {%{hd0 | device_in: new_head}, %{s0 | packets: packets1}}
          end
      end

    case hd1.work_in do
      @no_work ->
        s2 = put_handle(s1, hd1)
        wait(s2)

      work_ref ->
        work_pkt = Map.fetch!(s1.packets, work_ref)
        count = work_pkt.datum

        cond do
          count >= @data_size ->
            hd2 = %{hd1 | work_in: work_pkt.link}
            s2 = put_handle(s1, hd2)
            queue_packet(work_ref, s2)

          hd1.device_in == @no_work ->
            s2 = put_handle(s1, hd1)
            wait(s2)

          true ->
            dev_ref = hd1.device_in
            dev_pkt = Map.fetch!(s1.packets, dev_ref)
            hd2 = %{hd1 | device_in: dev_pkt.link}
            dev_pkt1 = %{dev_pkt | datum: elem(work_pkt.data, count)}
            work_pkt1 = %{work_pkt | datum: count + 1}

            s2 = %{
              s1
              | packets: Map.put(Map.put(s1.packets, work_ref, work_pkt1), dev_ref, dev_pkt1)
            }

            s3 = put_handle(s2, hd2)
            queue_packet(dev_ref, s3)
        end
    end
  end

  defp append_to_queue(pkt_ref, queue_head, packets0) do
    pkt = Map.fetch!(packets0, pkt_ref)
    packets1 = Map.put(packets0, pkt_ref, %{pkt | link: @no_work})

    case queue_head do
      @no_work -> {pkt_ref, packets1}
      _ -> {queue_head, walk_and_append(queue_head, pkt_ref, packets1)}
    end
  end

  defp device_step(@no_work, dd, s) do
    case dd.pending do
      @no_work ->
        wait(s)

      pending ->
        s1 = put_handle(s, %{dd | pending: @no_work})
        queue_packet(pending, s1)
    end
  end

  defp device_step(work_pkt_ref, dd, s) do
    s1 = put_handle(s, %{dd | pending: work_pkt_ref})
    hold_self(s1)
  end

  # Suppress unused-attribute warning for @num_types — kept as documentation.
  _ = @num_types
end
