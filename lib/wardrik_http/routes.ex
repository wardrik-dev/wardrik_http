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
  `:error`. An agent's key takes two segments, or three where the second starts with `@`.

      WardrikHTTP.Routes.match("POST", ["v1", "agents", "acme", "@jon", "triage", "messages"])
      #=> {:ok, %{id: "agent.ask", ...}, %{"agent" => "acme/@jon/triage"}}
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

  defp params([:agent | pattern], [org, "@" <> _ = user, name | segments], params),
    do: params(pattern, segments, Map.put(params, "agent", Enum.join([org, user, name], "/")))

  defp params([:agent | pattern], [org, name | segments], params),
    do: params(pattern, segments, Map.put(params, "agent", org <> "/" <> name))

  defp params([{:param, name} | pattern], [value | segments], params),
    do: params(pattern, segments, Map.put(params, name, value))

  defp params([literal | pattern], [literal | segments], params),
    do: params(pattern, segments, params)

  defp params(_pattern, _segments, _params), do: :error
end
