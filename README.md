# WardrikHTTP

[Wardrik](https://hexdocs.pm/wardrik) over HTTP. Every operation is a JSON route, and agents'
events stream as server-sent events that a client resumes after any disconnect.

## Install

```elixir
def deps do
  [
    {:wardrik, "~> 0.1"},
    {:wardrik_http, "~> 0.1"}
  ]
end
```

## Serve it

Add it to your supervision tree after your Wardrik, and give it a port:

```elixir
defmodule MyApp.Wardrik do
  use Wardrik, otp_app: :my_app
end

# config/runtime.exs
config :my_app, MyApp.Wardrik,
  data_dir: "/var/lib/my_app",
  keys: [System.fetch_env!("WARDRIK_KEY")]

# application.ex
children = [
  MyApp.Wardrik,
  {WardrikHTTP, wardrik: MyApp.Wardrik, port: 4000}
]
```

It takes Bandit's options too, like `ip:`. It speaks plain HTTP, so put something that ends TLS in
front of it to reach it across a network.

## Make a token

Every request sends an API token as `Authorization: Bearer`. Make one from IEx:

```elixir
scope = MyApp.Wardrik.as("acme/@maria", roles: [:owner], resources: ["*"])
{:ok, issued} = Wardrik.Tokens.create(scope, name: "laptop", roles: ["owner"], resources: ["acme/*"])

issued.secret
#=> "wrk_3f9a61c0d4e2_Vb7..."
```

The token acts for Maria, allowed what its roles and resources say. See
[Who may do what](https://hexdocs.pm/wardrik/access.html).

## Talk to agents

Define an agent, ask it something, and follow its log:

```sh
export TOKEN=wrk_3f9a61c0d4e2_Vb7...

curl -X PUT localhost:4000/v1/agents/acme/triage \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"model": "anthropic:claude-haiku-4-5", "instructions": "You watch the incident queue."}'

curl -X POST localhost:4000/v1/agents/acme/triage/messages \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"content": "What is on fire?"}'
#=> {"message": {"id": "msg_Xq3f...", "cursor": "eyJhY21lL3RyaWFnZSI6NDF9"}}

curl -N localhost:4000/v1/agents/acme/triage/events?after=eyJhY21lL3RyaWFnZSI6NDF9 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: text/event-stream"
#=> id: eyJhY21lL3RyaWFnZSI6NDN9
#=> data: {"specversion":"1.0","type":"wardrik.run.completed",...}
```

An agent's key is its path: `acme/triage` for an org's own agent, and `acme/@maria/notes` for one
that works for a person. Send each segment percent-encoded on its own.

Each event's `id` is a cursor. A stream starts after `Last-Event-ID` or `?after=`, and at what's
written next without either. Without `Accept: text/event-stream`, the same route answers a page as
JSON. A stream sends a comment every 15 seconds while nothing happens, and ends once its token is
revoked.

Every route is in `GET /v1/openapi.json`, which a client generator reads. An error is the protocol's
`{"error": {"type": ..., "message": ...}}`, and every answer carries a `request-id` header.

## Receive webhooks

A trigger with a `webhook` is sent requests at `POST /v1/hooks/{agent}/{trigger}`, with no token.
The request proves itself with the trigger's secret instead:

```elixir
:ok = MyApp.Wardrik.put_secret("acme", "ISSUES_HOOK", System.fetch_env!("ISSUES_HOOK"))

Wardrik.Agent.define(scope, "acme/triage",
  model: "anthropic:claude-haiku-4-5",
  triggers: [%{name: "issues", webhook: %{secret: "${ISSUES_HOOK}"}, prompt: "Triage it."}]
)
```

Point the service at `https://agents.example.com/v1/hooks/acme/triage/issues`. See
[Trigger agents](https://hexdocs.pm/wardrik/triggers.html) for how a request proves itself.

## Run tools in your own process

A tool worker is your own program offering agents tools. Its tools run in its process, with its code,
data and keys, and it dials Wardrik, so Wardrik needs no way to reach it. Make it a token with the
`worker` role, over the agents it serves:

```elixir
{:ok, issued} =
  Wardrik.Tokens.create(scope, name: "shop", roles: ["worker"], resources: ["acme/agent/*"])
```

The worker opens a WebSocket to `/v1/workers` with that token, and answers as an MCP server does.
Wardrik sends it `initialize` and `tools/list`, then a `tools/call` for each call an agent makes:

```json
{"jsonrpc": "2.0", "id": 3, "method": "tools/call",
 "params": {"name": "refund_order", "arguments": {"order": "A1"},
            "_meta": {"agent": {"key": "acme/triage", "org": "acme", "name": "triage"},
                      "run": "4bf92f3577b34da6a3ce929d0e0e4736",
                      "principal": "acme/@maria", "idempotencyKey": "call_1"}}}
```

An agent names the tools workers offer as `workers/*`:

```elixir
Wardrik.Agent.define(scope, "acme/triage",
  model: "anthropic:claude-haiku-4-5",
  tools: ["workers/*"],
  policy: [ask: ["workers/refund_order"]]
)
```

The model sees it as `workers__refund_order`. A tool the worker doesn't mark `readOnlyHint` changes
things, so the agent's policy decides it as it does any other. A result's `_meta.costUsd` is what
the call cost, which a budget counts. See `WardrikHTTP.Worker` for the whole exchange.

A worker's tools go when its socket does, and come back when it dials in again: each turn takes
the tools offered as it starts, and each call goes to a worker connected then. A call whose worker
went away, or didn't answer in a minute, may have run. It runs again, under the same
`idempotencyKey`, where every worker offering the tool marks it `readOnlyHint` or
`idempotentHint`, on whichever worker offers it by then. Otherwise it waits on a person as
`in_doubt`, to approve running it again or deny it.

## Sign people in

Where your Wardrik signs people in, `/oauth/` serves the pages a sign-in comes back to. Set its
`page` to that path:

```elixir
config :my_app, MyApp.Wardrik,
  keys: [System.fetch_env!("WARDRIK_KEY")],
  oauth: [
    page: "https://agents.example.com/oauth",
    providers: [
      github: [
        issuer: "https://github.com/login/oauth",
        client_id: System.fetch_env!("GITHUB_CLIENT_ID"),
        client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET"),
        scopes: ~w(repo),
        flow: :device
      ]
    ]
  ]
```

See [Credentials and sign-ins](https://hexdocs.pm/wardrik/credentials.html).

## In a Phoenix app

Forward a path to it from your router, in place of the child above:

```elixir
forward "/agents", WardrikHTTP, wardrik: MyApp.Wardrik
```

The routes are then under `/agents`, as `/agents/v1/agents/acme/triage`, and the sign-in pages are
at `/agents/oauth`. A webhook's signature covers the exact bytes it was sent, so where your endpoint
parses bodies first, have `Plug.Parsers` keep them:

```elixir
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  json_decoder: Phoenix.json_library(),
  body_reader: {WardrikHTTP.BodyReader, :read_body, []}
```

## Your own sign-in

To know requests by your app's own sessions in place of API tokens, give an authenticator:

```elixir
defmodule MyAppWeb.WardrikSession do
  @behaviour WardrikHTTP.Authenticator

  @impl true
  def authenticate(conn, wardrik, _config) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, id} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "wardrik", token, max_age: 86_400) do
      {:ok, Wardrik.as(wardrik, id, roles: [:owner], resources: [id <> "/*"])}
    else
      _not_signed_in -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
    end
  end
end

forward "/agents", WardrikHTTP, wardrik: MyApp.Wardrik, authenticator: {MyAppWeb.WardrikSession, []}
```

## License

Apache-2.0
