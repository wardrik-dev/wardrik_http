defmodule WardrikHTTP.BodyReader do
  @moduledoc """
  Keeps a request's body as it came while `Plug.Parsers` reads it, so a webhook's signature can be
  checked over the exact bytes. Give it to `Plug.Parsers` where your app parses bodies ahead of
  `WardrikHTTP`:

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: JSON,
        body_reader: {WardrikHTTP.BodyReader, :read_body, []}
  """

  import Plug.Conn

  @doc "Reads the body as `Plug.Conn.read_body/2` does, and keeps what it read."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, kept(conn, body)}
      {:more, body, conn} -> {:more, body, kept(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the body kept as it came, or `nil` where none was."
  @spec kept(Plug.Conn.t()) :: binary() | nil
  def kept(conn), do: conn.private[:wardrik_http_body]

  defp kept(conn, body), do: put_private(conn, :wardrik_http_body, (kept(conn) || "") <> body)
end
