defmodule WardrikHTTP.Worker do
  @moduledoc """
  A tool worker's WebSocket at `GET /v1/workers`, and Wardrik as the MCP client over it. A worker is
  an MCP server that dials in, with a token whose scope may `agent.serve` the agents it serves.

  It speaks JSON-RPC 2.0, one message to a text frame, as MCP `2025-06-18` says:

    1. Wardrik sends `initialize`, then `notifications/initialized` once the worker answers.
    2. Wardrik sends `tools/list`, and offers what the worker lists with `Wardrik.Workers.offer/2`.
       The worker sends `notifications/tools/list_changed` to be listed again.
    3. Wardrik sends `tools/call` for each call an agent makes, with the call's `_meta`, and the
       worker answers with a `CallToolResult`, and what the call cost as `_meta.costUsd`.
    4. A call Wardrik stops waiting on, or that's stopped, is sent `notifications/cancelled`.

  It answers a worker's `ping`, and pings it every `:keepalive` milliseconds. Each time, it asks
  whether the token still works, and closes with `1008` once it doesn't.
  """

  @behaviour WebSock

  @protocol "2025-06-18"

  @enforce_keys [:scope, :alive?, :keepalive]
  defstruct [:scope, :alive?, :keepalive, next: 1, pending: %{}]

  @impl WebSock
  def init(%{scope: scope, alive?: alive?, keepalive: keepalive}) do
    state = %__MODULE__{scope: scope, alive?: alive?, keepalive: keepalive}
    keep_alive(state)

    params = %{
      "protocolVersion" => @protocol,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "wardrik", "version" => version()}
    }

    {frame, state} = request(state, "initialize", params, :initialize)
    {:push, frame, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case JSON.decode(text) do
      {:ok, message} -> received(message, state)
      {:error, _reason} -> {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({Wardrik.Workers, :call, {caller, _ref} = call, name, arguments, meta}, state) do
    params = %{"name" => name, "arguments" => arguments, "_meta" => meta}
    {frame, state} = request(state, "tools/call", params, {call, Process.monitor(caller)})
    {:push, frame, state}
  end

  def handle_info({Wardrik.Workers, :cancel, call}, state),
    do: cancel(state, &match?({^call, _monitor}, &1), "Wardrik stopped waiting for it.")

  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state),
    do: cancel(state, &match?({_call, ^monitor}, &1), "The call was stopped.")

  def handle_info(:keepalive, state) do
    case state.alive?.() do
      true -> pinged(state)
      false -> {:stop, :normal, {1008, "The token no longer works."}, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp pinged(state) do
    keep_alive(state)
    {:push, {:ping, ""}, state}
  end

  defp received(%{"method" => "notifications/tools/list_changed"}, state) do
    {frame, state} = request(state, "tools/list", %{}, :list)
    {:push, frame, state}
  end

  defp received(%{"method" => "ping", "id" => id}, state),
    do: {:push, response(id, %{"result" => %{}}), state}

  defp received(%{"method" => _method, "id" => id}, state),
    do:
      {:push, response(id, %{"error" => %{"code" => -32_601, "message" => "Method not found"}}),
       state}

  defp received(%{"id" => id} = message, state) when is_map_key(state.pending, id) do
    {purpose, pending} = Map.pop(state.pending, id)
    answered(purpose, message, %{state | pending: pending})
  end

  defp received(_message, state), do: {:ok, state}

  defp answered(:initialize, %{"result" => _result}, state) do
    {list, state} = request(state, "tools/list", %{}, :list)
    {:push, [notification("notifications/initialized", %{}), list], state}
  end

  defp answered(:initialize, _refused, state), do: {:stop, :normal, state}

  defp answered(:list, %{"result" => %{"tools" => tools}}, state) when is_list(tools) do
    :ok = Wardrik.Workers.offer(state.scope, tools)
    {:ok, state}
  end

  defp answered(:list, _refused, state), do: {:ok, state}

  defp answered({call, monitor}, message, state) do
    Process.demonitor(monitor, [:flush])
    :ok = Wardrik.Workers.answer(call, message)
    {:ok, state}
  end

  defp cancel(state, call?, reason) do
    case Enum.find(state.pending, fn {_id, purpose} -> call?.(purpose) end) do
      {id, {_call, monitor}} ->
        Process.demonitor(monitor, [:flush])

        cancelled =
          notification("notifications/cancelled", %{"requestId" => id, "reason" => reason})

        {:push, cancelled, %{state | pending: Map.delete(state.pending, id)}}

      nil ->
        {:ok, state}
    end
  end

  defp request(state, method, params, purpose) do
    id = state.next
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    {{:text, JSON.encode!(message)},
     %{state | next: id + 1, pending: Map.put(state.pending, id, purpose)}}
  end

  defp notification(method, params),
    do: {:text, JSON.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})}

  defp response(id, body),
    do: {:text, JSON.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => id}, body))}

  defp keep_alive(state), do: Process.send_after(self(), :keepalive, state.keepalive)

  defp version, do: :wardrik_http |> Application.spec(:vsn) |> to_string()
end
