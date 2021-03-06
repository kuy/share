defmodule Share.PageChannel do
  use Share.Web, :channel
  alias Share.Follow
  alias Share.User
  alias Share.Post
  alias Share.Fav
  alias Share.Repo

  require Logger

  def join("page", _params, socket) do
    {:ok, socket}
  end

  def handle_in("user_info", %{"name" => name}, socket) do
    case Repo.get_by(User, name: name) do
      nil -> {:reply, :error, socket}
      user ->
        query = from p in Post, where: p.user_id == ^user.id
        post_count = Repo.aggregate(query, :count, :id)
        query = from f in Follow, where: f.user_id == ^user.id
        follow_count = Repo.aggregate(query, :count, :id)
        query = from f in Follow, where: f.target_user_id == ^user.id
        followed_count = Repo.aggregate(query, :count, :id)
        res = %{
          "user" => user,
          "postCount" => post_count,
          "following" => follow_count,
          "followers" => followed_count
        }
        {:reply, {:ok, res}, socket}
    end
  end

  def handle_in("post", %{"id" => id}, socket) do
    case Repo.get(Post, id) do
      nil -> {:reply, :error, socket}
      post ->
        res = %{
          post: Post.preload(post)
        }
        {:reply, {:ok, res}, socket}
    end
  end

  def handle_in("public_timeline", _params, socket) do
    query = Post
            |> limit(50)
            |> Post.random()
    query = subquery(query)
            |> order_by([p], [desc: p.id])
            |> Post.preload()
    posts = Repo.all(query)
    post_ids = posts |> Enum.map(&(&1.id))
    Repo.update_all((from p in Post, where: p.id in ^post_ids), inc: [views: 1])
    favs = Fav.get_favs(socket, post_ids)
    {:reply, {:ok, %{posts: posts, favs: favs}}, socket}
  end

  def handle_in("ping", _params, socket) do
    {:reply, :ok, socket}
  end
end
