defmodule WardrikHTTP.Bearer do
  @moduledoc """
  Knows a request by the API token it sends, as `Authorization: Bearer wrk_...`, with
  its server's `authenticate/2`.
  """

  @behaviour WardrikHTTP.Authenticator

  alias Wardrik.Error

  @impl WardrikHTTP.Authenticator
  def authenticate(conn, {server, wardrik}, _config) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> secret] -> server.authenticate(wardrik, secret)
      _none -> {:error, Error.new(:unauthorized, "Send an API token as Authorization: Bearer.")}
    end
  end
end
