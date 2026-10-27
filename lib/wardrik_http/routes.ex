defmodule WardrikHTTP.Routes do
  @moduledoc """
  Finds the operation a request names by its method and path, among the routes `WardrikProtocol`'s
  OpenAPI document gives.
  """

  segment = fn
    "{agent}" -> :agent
    "{" <> name -> {:param, String.trim_trailing(name, "}")}
    literal -> literal
  end

  @routes WardrikProtocol.operations()
          |> Enum.map(fn operation ->
            pattern = operation.path |> String.split("/", trim: true) |> Enum.map(segment)
            {String.upcase(operation.method), pattern, operation}
          end)
          |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))

  @doc """
  Returns the operation `method` and the decoded path `segments` name, with its path parameters, or
  `:error`. An agent's key takes two segments, or three where the second starts with `@`, and one
  of its conversations follows it as `conversations/ID`.

      WardrikHTTP.Routes.match("POST", ["v1", "agents", "acme", "@jon", "triage", "messages"])
      #=> {:ok, %{id: "agent.ask", ...}, %{"agent" => "acme/@jon/triage"}}

      WardrikHTTP.Routes.match("GET", ~w(v1 agents acme triage conversations C1 timeline))
      #=> {:ok, %{id: "agent.timeline", ...}, %{"agent" => "acme/triage/C1"}}
  """
  @spec match(String.t(), [String.t()]) ::
          {:ok, WardrikProtocol.operation(), %{String.t() => String.t()}} | :error
  def match(method, segments) do
    @routes
    |> Map.get(method, [])
    |> Enum.find_value(:error, fn {pattern, operation} ->
      matched(pattern, segments, operation)
    end)
  end

  defp matched(pattern, segments, operation) do
    case params(pattern, segments, %{}) do
      {:ok, params} -> {:ok, operation, params}
      :error -> nil
    end
  end

  defp params([], [], params), do: {:ok, params}

  defp params([:agent | pattern], segments, params) do
    with {:ok, agent, rest} <- agent(segments),
         do: params(pattern, rest, Map.put(params, "agent", agent))
  end

  defp params([{:param, name} | pattern], [value | segments], params),
    do: params(pattern, segments, Map.put(params, name, value))

  defp params([literal | pattern], [literal | segments], params),
    do: params(pattern, segments, params)

  defp params(_pattern, _segments, _params), do: :error

  defp agent([org, "@" <> _ = user, name | rest]), do: conversation([org, user, name], rest)
  defp agent([org, name | rest]), do: conversation([org, name], rest)
  defp agent(_segments), do: :error

  defp conversation(key, ["conversations", id | rest]),
    do: {:ok, Enum.join(key ++ [id], "/"), rest}

  defp conversation(key, rest), do: {:ok, Enum.join(key, "/"), rest}
end
