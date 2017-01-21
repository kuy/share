defmodule Share.PageController do
  use Share.Web, :controller

  def index(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    case user do
      nil ->
        client = %{
          account: nil
        }
        token = Phoenix.Token.sign(Share.Endpoint, "channel", client)
        render conn, "index.html", signed_in: false, token: token
      user ->
        client = %{
          user: user
        }
        token = Phoenix.Token.sign(Share.Endpoint, "channel", client)
        render conn, "index.html", signed_in: true, token: token
    end
  end
end
