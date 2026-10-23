defmodule WardrikHTTP do
  @moduledoc """
  Serves a Wardrik over HTTP: every operation of `WardrikProtocol` at its route, each run with
  `Wardrik.run/3`, and the operations that stream as server-sent events.

      children = [
        MyApp.Wardrik,
        {WardrikHTTP, wardrik: MyApp.Wardrik, port: 4000}
      ]

  It's a `Plug` too, for your app's router to forward a path to:

      forward "/agents", WardrikHTTP, wardrik: MyApp.Wardrik

  It takes `:wardrik`, the instance it serves, `:authenticator`, a `WardrikHTTP.Authenticator` as
  `{module, config}` (`WardrikHTTP.Bearer` unless set), and `:keepalive`, how many milliseconds an
  event stream waits on nothing before it sends a comment, 15 seconds unless set. As a child, it
  takes Bandit's options too, like `:port` and `:ip`.

  `GET /v1/openapi.json` answers the OpenAPI document, and `/oauth/` serves the pages a sign-in
  comes back to, where the Wardrik signs people in. Every answer carries a `request-id` header, the
  caller's own where it sent one.

  Reach for this when people or programs outside your app talk to its agents.
  """

  @behaviour Plug

  import Plug.Conn

  alias Wardrik.Error
  alias WardrikHTTP.EventStream
  alias WardrikHTTP.Input
  alias WardrikHTTP.Response
  alias WardrikHTTP.Routes

  @own [:wardrik, :authenticator, :keepalive]
  @request_id Plug.RequestId.init(http_header: "request-id")

  @doc "Returns a child spec that serves the Wardrik with Bandit, which takes the rest of `opts`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    {own, bandit} = Keyword.split(opts, @own)
    Bandit.child_spec([plug: {__MODULE__, own}] ++ bandit)
  end

  @impl Plug
  def init(opts) do
    opts
    |> Keyword.validate!([:wardrik, authenticator: {WardrikHTTP.Bearer, []}, keepalive: 15_000])
    |> Map.new()
    |> wardrik!()
  end

  defp wardrik!(%{wardrik: wardrik} = settings) when is_atom(wardrik), do: settings

  defp wardrik!(_settings),
    do: raise(ArgumentError, "WardrikHTTP serves a Wardrik. Give it wardrik: MyApp.Wardrik.")

  @impl Plug
  def call(conn, settings), do: conn |> Plug.RequestId.call(@request_id) |> serve(settings)

  defp serve(%Plug.Conn{method: "GET", path_info: ["v1", "openapi.json"]} = conn, _settings),
    do: Response.json(conn, 200, WardrikProtocol.openapi())

  defp serve(%Plug.Conn{path_info: ["oauth" | rest]} = conn, %{wardrik: wardrik}),
    do: sign_in(conn, rest, Wardrik.sign_in_pages(wardrik))

  defp serve(conn, settings) do
    with {:ok, segments} <- segments(conn.path_info),
         {:ok, operation, params} <- route(conn.method, segments),
         {:ok, scope} <- authenticate(conn, operation, settings),
         {:ok, input, conn} <- Input.build(conn, operation, params) do
      respond(conn, scope, operation, input, settings)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  defp sign_in(conn, _rest, nil), do: Response.error(conn, no_route())
  defp sign_in(conn, rest, {plug, opts}), do: Plug.forward(conn, rest, plug, opts)

  defp segments(path_info) do
    decoded = Enum.map(path_info, &URI.decode/1)

    case Enum.any?(decoded, &String.contains?(&1, "/")) do
      false -> {:ok, decoded}
      true -> {:error, Error.new(:invalid_request, "A path segment can't hold a /.")}
    end
  end

  defp route(method, segments) do
    case Routes.match(method, segments) do
      {:ok, operation, params} -> {:ok, operation, params}
      :error -> {:error, no_route()}
    end
  end

  defp no_route, do: Error.new(:not_found, "There's no route here.")

  defp authenticate(_conn, %{subject: "hook"}, %{wardrik: wardrik}),
    do: {:ok, Wardrik.as(wardrik, "anonymous")}

  defp authenticate(conn, _operation, %{wardrik: wardrik, authenticator: {module, config}}),
    do: module.authenticate(conn, wardrik, config)

  defp respond(conn, scope, %{stream: true} = operation, input, settings) do
    case event_stream?(conn) do
      true -> stream(conn, scope, operation, resumed(conn, input), settings)
      false -> Response.answer(conn, operation, Wardrik.run(scope, operation.id, input))
    end
  end

  defp respond(conn, scope, operation, input, _settings),
    do: Response.answer(conn, operation, Wardrik.run(scope, operation.id, input))

  defp event_stream?(conn),
    do: conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/event-stream"))

  defp resumed(conn, input) do
    case get_req_header(conn, "last-event-id") do
      [cursor | _rest] -> Map.put_new(input, "after", cursor)
      [] -> input
    end
  end

  defp stream(conn, scope, operation, input, settings) do
    case Wardrik.stream(scope, operation.id, input) do
      {:ok, events} -> EventStream.serve(conn, events, stream_options(conn, input, settings))
      {:error, error} -> Response.error(conn, error)
    end
  end

  defp stream_options(conn, input, %{authenticator: {module, config}} = settings) do
    [
      after: input["after"],
      keepalive: settings.keepalive,
      alive?: fn -> match?({:ok, _scope}, module.authenticate(conn, settings.wardrik, config)) end
    ]
  end
end
