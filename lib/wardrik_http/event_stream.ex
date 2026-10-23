defmodule WardrikHTTP.EventStream do
  @moduledoc """
  Sends what an operation streams as server-sent events, until the client goes or its credential
  stops working.

      id: eyJhY21lL3RyaWFnZSI6NDF9
      data: {"specversion":"1.0","type":"wardrik.run.completed",...}

  An event that moves the reader's cursor is sent with that cursor as its `id`, so a client's
  `Last-Event-ID` resumes after it. One that leaves it where it was, like a delta, is sent without
  one. A comment is sent every `:keepalive` milliseconds while nothing happens, which keeps the
  stream open through proxies and finds a client that's gone. Each time, `:alive?` is asked whether
  the stream may go on.
  """

  import Plug.Conn

  @doc """
  Streams `events`, as `{event, cursor}`, on `conn`. Takes `:after`, the cursor they're read after,
  `:keepalive` and `:alive?`.
  """
  @spec serve(Plug.Conn.t(), Enumerable.t(), keyword()) :: Plug.Conn.t()
  def serve(conn, events, opts) do
    stream = self()
    taker = Task.async(fn -> take(events, stream) end)
    opened(taker.pid)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)
      |> follow(taker.pid, opts[:after], opts)

    Task.shutdown(taker, :brutal_kill)
    conn
  end

  defp take(events, stream) do
    {:suspended, nil, take} = Enumerable.reduce(events, {:suspend, nil}, &hand(stream, &1, &2))
    send(stream, {self(), :open})
    take.({:cont, nil})
  end

  defp hand(stream, event, nil) do
    send(stream, {self(), event})

    receive do
      :taken -> {:cont, nil}
    end
  end

  defp opened(taker) do
    receive do
      {^taker, :open} -> :ok
    end
  end

  defp follow(conn, taker, cursor, opts) do
    receive do
      {^taker, {event, moved}} ->
        send(taker, :taken)
        sent(conn, frame(event, cursor, moved), taker, moved, opts)
    after
      Keyword.fetch!(opts, :keepalive) -> kept_alive(conn, taker, cursor, opts)
    end
  end

  defp kept_alive(conn, taker, cursor, opts) do
    case Keyword.fetch!(opts, :alive?).() do
      true -> sent(conn, ": keepalive\n\n", taker, cursor, opts)
      false -> conn
    end
  end

  defp sent(conn, data, taker, cursor, opts) do
    case chunk(conn, data) do
      {:ok, conn} -> follow(conn, taker, cursor, opts)
      {:error, _closed} -> conn
    end
  end

  defp frame(event, cursor, cursor), do: data(event)
  defp frame(event, _cursor, moved), do: ["id: ", moved, "\n" | data(event)]

  defp data(event), do: ["data: ", JSON.encode!(event), "\n\n"]
end
