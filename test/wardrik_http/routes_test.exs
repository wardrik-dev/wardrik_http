defmodule WardrikHTTP.RoutesTest do
  use ExUnit.Case, async: true

  alias WardrikHTTP.Routes

  test "routes every operation by its method and path" do
    for operation <- WardrikProtocol.operations(),
        agent <- ["acme/triage", "acme/@jon/triage", "acme/triage/C1", "acme/@jon/triage/C1"] do
      {path, params} = filled(operation.path, agent)
      method = String.upcase(operation.method)

      assert {:ok, %{id: id}, ^params} = Routes.match(method, String.split(path, "/", trim: true))
      assert id == operation.id, "#{method} #{path} routed to #{id}, not #{operation.id}"
    end
  end

  test "finds no route for a path no operation has" do
    assert Routes.match("GET", ["v1", "nothing"]) == :error
    assert Routes.match("PATCH", ["v1", "agents"]) == :error
    assert Routes.match("POST", ~w(v1 agents acme triage C1 messages)) == :error
    assert Routes.match("POST", ~w(v1 agents acme triage conversations messages)) == :error
  end

  defp filled(template, agent) do
    template
    |> String.split("/", trim: true)
    |> Enum.map_reduce(%{}, fn
      "{agent}", params -> {path(agent), Map.put(params, "agent", agent)}
      "{" <> name, params -> param(String.trim_trailing(name, "}"), params)
      literal, params -> {literal, params}
    end)
    |> then(fn {segments, params} -> {"/" <> Enum.join(segments, "/"), params} end)
  end

  defp path(agent) do
    case String.split(agent, "/") do
      [org, "@" <> _ = user, name] -> Enum.join([org, user, name], "/")
      [org, "@" <> _ = user, name, id] -> Enum.join([org, user, name, "conversations", id], "/")
      [org, name, id] -> Enum.join([org, name, "conversations", id], "/")
      [_org, _name] -> agent
    end
  end

  defp param(name, params), do: {"x" <> name, Map.put(params, name, "x" <> name)}
end
