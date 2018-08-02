defmodule Csvm do
  @moduledoc """
  Manages many FarmProcs
  """

  use GenServer
  use Bitwise, only: [bsl: 2]
  alias Csvm.{AST, FarmProc, ProcStorage}
  import Csvm.Utils
  alias AST.Heap
  require Logger

  # Frequency of vm ticks.
  @tick_timeout 20

  @kinds_that_need_fw [
    :config_update,
    :_if,
    :write_pin,
    :read_pin,
    :move_absolute,
    :set_servo_angle,
    :move_relative,
    :home,
    :find_home,
    :toggle_pin,
    :zero,
    :calibrate,
    :sequence,
    :rpc_request
  ]

  @kinds_aloud_while_locked [
    :check_updates,
    :config_update,
    :uninstall_farmware,
    :update_farmware,
    :rpc_request,
    :rpc_ok,
    :rpc_error,
    :install,
    :read_status,
    :sync,
    :power_off,
    :reboot,
    :factory_reset,
    :set_user_env,
    :install_first_party_farmware,
    :change_ownership,
    :dump_info,
    :_if,
    :send_message,
    :sequence,
    :wait,
    :execute,
    :execute_script,
    :emergency_lock,
    :emergency_unlock
  ]

  defstruct [
    :proc_storage,
    :hyper_state,
    :fw_proc,
    :process_io_layer,
    :hyper_io_layer,
    :tick_timer
  ]

  @opaque job_id :: CircularList.index()

  @doc "Execute an rpc_request, this is sync."
  def rpc_request(pid \\ __MODULE__, %{} = map, fun)
      when is_function(fun) do
    %AST{} = ast = AST.decode(map)
    label = ast.args[:label] || raise(ArgumentError)
    job = queue(pid, map, -1)

    if job do
      proc = await(pid, job)

      case FarmProc.get_status(proc) do
        :done ->
          results = ast(:rpc_ok, %{label: label}, [])
          apply_callback(fun, [results])

        :crashed ->
          message = FarmProc.get_crash_reason(proc)
          explanation = ast(:explanation, %{message: message})
          results = ast(:rpc_error, %{label: label}, [explanation])
          apply_callback(fun, [results])
      end
    else
      # if no job is returned, this was a hyper function, which
      # can never fail.
      results = ast(:rpc_ok, %{label: label}, [])
      apply_callback(fun, [results])
    end
  end

  @doc "Execute a sequence. This is async."
  def sequence(pid \\ __MODULE__, %{} = map, id, fun) when is_function(fun) do
    job = queue(pid, map, id)

    spawn(fn ->
      proc = await(pid, job)

      case FarmProc.get_status(proc) do
        :done ->
          apply_callback(fun, [:ok])

        :crashed ->
          apply_callback(fun, [{:error, FarmProc.get_crash_reason(proc)}])
      end
    end)
  end

  # Queues some data for execution.
  # If kind == :emergency_lock or :emergency_unlock
  # (or this is an rpc request with the first item being one of those.)
  # this ast will immediately execute the `hyper_io_layer` function.
  @spec queue(GenServer.server(), map, integer) :: job_id | nil
  defp queue(pid, %{} = map, page_id) when is_integer(page_id) do
    case AST.decode(map) do
      %AST{kind: :rpc_request, body: [%AST{kind: :emergency_lock}]} ->
        :emergency_lock = GenServer.call(pid, :emergency_lock)
        nil

      %AST{kind: :rpc_request, body: [%AST{kind: :emergency_unlock}]} ->
        :emergency_unlock = GenServer.call(pid, :emergency_unlock)
        nil

      %AST{} = ast ->
        %Heap{} = heap = AST.slice(ast)
        %Address{} = page = addr(page_id)

        case GenServer.call(pid, {:queue, heap, page}) do
          {:error, :busy} -> queue(pid, map, page_id)
          job -> job
        end
    end
  end

  # Polls the GenServer until it returns a FarmProc with a stopped status
  @spec await(GenServer.server(), job_id) :: FarmProc.t()
  defp await(pid, job_id) do
    case GenServer.call(pid, {:lookup, job_id}) do
      {:error, :busy} ->
        await(pid, job_id)

      %FarmProc{} = proc ->
        case FarmProc.get_status(proc) do
          status when status in [:ok, :waiting] ->
            Process.sleep(@tick_timeout * 2)
            await(pid, job_id)

          _ ->
            proc
        end

      _ ->
        raise(ArgumentError, "no job by that identifier")
    end
  end

  @doc """
  Start a CSVM monitor.

  ## Required params:
  * `process_io_layer` ->
    function that takes an AST whenever a FarmProc needs IO operations.
  * `hyper_io_layer`
    function that takes one of the hyper calls
  """
  @spec start_link(Keyword.t(), GenServer.name()) :: GenServer.server()
  def start_link(args, name \\ __MODULE__) do
    GenServer.start_link(__MODULE__, Keyword.put(args, :name, name), name: name)
  end

  def init(args) do
    timer = start_tick(self())
    storage = ProcStorage.new(Keyword.fetch!(args, :name))
    io_fun = Keyword.fetch!(args, :process_io_layer)
    hyper_fun = Keyword.fetch!(args, :hyper_io_layer)
    unless is_function(io_fun), do: raise(ArgumentError)
    unless is_function(hyper_fun), do: raise(ArgumentError)

    {:ok,
     %Csvm{
       process_io_layer: io_fun,
       hyper_io_layer: hyper_fun,
       tick_timer: timer,
       proc_storage: storage
     }}
  end

  def handle_call(:emergency_lock, _from, %Csvm{} = state) do
    apply_callback(state.hyper_io_layer, [:emergency_lock])
    {:reply, :emergency_lock, %{state | hyper_state: :emergency_lock}}
  end

  def handle_call(:emergency_unlock, _from, %Csvm{} = state) do
    apply_callback(state.hyper_io_layer, [:emergency_unlock])
    {:reply, :emergency_unlock, %{state | hyper_state: nil}}
  end

  def handle_call(_, _from, {:busy, state}) do
    {:reply, {:error, :busy}, {:busy, state}}
  end

  def handle_call({:queue, %Heap{} = h, %Address{} = p}, _, %Csvm{} = state) do
    %FarmProc{} = new_proc = FarmProc.new(state.process_io_layer, p, h)
    index = ProcStorage.insert(state.proc_storage, new_proc)
    {:reply, index, state}
  end

  def handle_call({:lookup, id}, _from, %Csvm{} = state) do
    cleanup = fn proc, state ->
      ProcStorage.delete(state.proc_storage, id)

      if proc.ref == state.fw_proc do
        {:reply, proc, %{state | fw_proc: nil}}
      else
        {:reply, proc, state}
      end
    end

    # Looks up a FarmProc, causes a few different side affects.
    # if the status is :done or :crashed, delete it from ProcStorage.
    # if deleted, and this proc owns the firmware,
    # delete it from there also.
    case ProcStorage.lookup(state.proc_storage, id) do
      %FarmProc{status: :crashed} = proc ->
        cleanup.(proc, state)

      %FarmProc{status: :done} = proc ->
        cleanup.(proc, state)

      reply ->
        {:reply, reply, state}
    end
  end

  def handle_info(:tick, %Csvm{} = state) do
    pid = self()
    # Calls `do_tick/3` with either
    # * a FarmProc that needs updating
    # * a :noop atom
    # state is set to {:busy, old_state}
    # until `do_step` calls
    # send(pid, %Csvm{})
    ProcStorage.update(state.proc_storage, &do_step(&1, pid, state))
    {:noreply, {:busy, state}}
  end

  # make sure to update the timer _AFTER_ we tick.
  # This message comes from the do_step/3 function that gets called
  # When updating a FarmProc.
  def handle_info(%Csvm{} = state, {:busy, _old}) do
    new_timer = start_tick(self())
    {:noreply, %Csvm{state | tick_timer: new_timer}}
  end

  defp start_tick(pid, timeout \\ @tick_timeout),
    do: Process.send_after(pid, :tick, timeout)

  @doc false
  # If there are no procs
  def do_step(:noop, pid, state), do: send(pid, state)

  # If the proc is crashed or done, don't step.
  def do_step(%FarmProc{status: :crashed} = farm_proc, pid, state) do
    IO.puts("crash tick.")
    send(pid, state)
    farm_proc
  end

  def do_step(%FarmProc{status: :done} = farm_proc, pid, state) do
    IO.puts("done tick.")
    send(pid, state)
    farm_proc
  end

  # If nothing currently owns the firmware,
  # Check kind needs fw,
  # Check kind is aloud while the bot is locked,
  # Check if bot is unlocked
  # If kind needs fw, update state.
  def do_step(%FarmProc{} = farm_proc, pid, %{fw_proc: nil} = state) do
    pc_ptr = FarmProc.get_pc_ptr(farm_proc)
    kind = FarmProc.get_kind(farm_proc, pc_ptr)
    b0 = (kind in @kinds_aloud_while_locked) |> bit()
    b1 = (kind in @kinds_that_need_fw) |> bit()
    b2 = true |> bit()
    b3 = (state.hyper_state == :emergency_lock) |> bit()
    bits = bsl(b0, 3) + bsl(b1, 2) + bsl(b2, 1) + b3

    if should_step(bits) do
      # Update state if this kind needs fw.
      if bool(b1),
        do: send(pid, %{state | fw_proc: farm_proc.ref}),
        else: send(pid, state)

      actual_step(farm_proc)
    else
      send(pid, state)
      farm_proc
    end
  end

  def do_step(%FarmProc{} = farm_proc, pid, state) do
    pc_ptr = FarmProc.get_pc_ptr(farm_proc)
    kind = FarmProc.get_kind(farm_proc, pc_ptr)
    b0 = (kind in @kinds_aloud_while_locked) |> bit()
    b1 = (kind in @kinds_that_need_fw) |> bit()
    b2 = (farm_proc.ref == state.fw_proc) |> bit()
    b3 = (state.hyper_state == :emergency_lock) |> bit()
    bits = bsl(b0, 3) + bsl(b1, 2) + bsl(b2, 1) + b3
    send(pid, state)

    if should_step(bits),
      do: actual_step(farm_proc),
      else: farm_proc
  end

  defp should_step(0b0000), do: true
  defp should_step(0b0001), do: false
  defp should_step(0b0010), do: true
  defp should_step(0b0011), do: false
  defp should_step(0b0100), do: false
  defp should_step(0b0101), do: false
  defp should_step(0b0110), do: true
  defp should_step(0b0111), do: false
  defp should_step(0b1000), do: true
  defp should_step(0b1001), do: true
  defp should_step(0b1010), do: true
  defp should_step(0b1011), do: true
  defp should_step(0b1100), do: false
  defp should_step(0b1101), do: false
  defp should_step(0b1110), do: true
  defp should_step(0b1111), do: true

  defp bit(true), do: 1
  defp bit(false), do: 0
  defp bool(1), do: true
  defp bool(0), do: false

  @spec actual_step(FarmProc.t()) :: FarmProc.t()
  defp actual_step(farm_proc) do
    try do
      FarmProc.step(farm_proc)
    rescue
      ex in FarmProc.Error ->
        ex.farm_proc

      ex ->
        farm_proc
        |> FarmProc.set_status(:crashed)
        |> FarmProc.set_crash_reason(Exception.message(ex))
    end
  end

  defp apply_callback(fun, results) when is_function(fun) do
    try do
      _ = apply(fun, results)
    rescue
      ex ->
        Logger.error("Error executing csvm callback: #{Exception.message(ex)}")
    end
  end
end
