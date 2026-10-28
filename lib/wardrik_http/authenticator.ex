defmodule WardrikHTTP.Authenticator do
  @moduledoc """
  An authenticator says who a request comes from, as the `Wardrik.Scope` it acts in. It's given as
  `{module, config}`, and `WardrikHTTP.Bearer` is the one used unless you give another.

      defmodule MyAppWeb.WardrikSession do
        @behaviour WardrikHTTP.Authenticator

        @impl true
        def authenticate(conn, {server, wardrik}, _config) do
          with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
               {:ok, id} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "wardrik", token, max_age: 86_400) do
            {:ok, Wardrik.Scope.new(server, wardrik, id, roles: [:owner], resources: [id <> "/*"])}
          else
            _not_signed_in -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
          end
        end
      end

  It's asked again while an event stream is open, and the stream ends once it refuses.
  """

  @doc """
  Returns the scope the request `conn` acts in on the Wardrik `server` runs, given as `{module,
  name}`, or why it has none.
  """
  @callback authenticate(conn :: Plug.Conn.t(), server :: {module(), atom()}, config :: term()) ::
              {:ok, Wardrik.Scope.t()} | {:error, Wardrik.Error.t()}
end
