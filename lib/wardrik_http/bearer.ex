defmodule WardrikHTTP.Bearer do
  @moduledoc """
  Knows a request by the API token it sends, as `Authorization: Bearer wrk_...`, with
  `Wardrik.authenticate/2`.
  """

  @behaviour WardrikHTTP.Authenticator

  alias Wardrik.Error

  @impl WardrikHTTP.Authenticator
  def authenticate(conn, wardrik, _config) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> secret] -> Wardrik.authenticate(wardrik, secret)
      _none -> {:error, Error.new(:unauthorized, "Send an API token as Authorization: Bearer.")}
    end
  end
end
