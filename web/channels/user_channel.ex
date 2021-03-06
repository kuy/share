defmodule Share.UserChannel do
  use Share.Web, :channel
  alias Share.Follow
  alias Share.User
  alias Share.Post
  alias Share.PostAddress
  alias Share.Fav
  alias Share.Repo

  require Logger

  def join("user:" <> name, _params, socket) do
    user = socket.assigns.user
    true = name == user.name

    user_params = get_user_params(user, socket)
    {:ok, %{"userParams" => user_params}, socket}
  end

  def handle_in("edit", %{"user" => params}, socket) do
    user = socket.assigns.user
    user = Repo.get!(User, user.id)
    changeset = User.changeset(user, params)
    case Repo.update(changeset) do
      {:ok, user} ->
        {:reply, {:ok, %{user: user}}, socket}
      {:error, changeset} ->
        {:reply, {:error, %{user: user}}, socket}
    end
  end

  def handle_in("new_post", params, socket) do
    user = socket.assigns.user
    user = Repo.get!(User, user.id)
    %{"post" => params, "address" => address} = params
    params = params
             |> Map.put("user_id", user.id)
             |> Map.put("user_display", user.display)
    text = Map.get(params, "text")
    post_id = Map.get(params, "post_id")
    if is_nil(post_id) and text == "" do
      {:reply, :error, socket}
    else
      changeset = Post.changeset(%Post{}, params)
      post = Repo.insert!(changeset)
      Share.PostHandler.handle(post, address)
      {:reply, :ok, socket}
    end
  end

  def handle_in("fav", %{"id" => id}, socket) do
    user = socket.assigns.user
    query = from f in Fav,
      where: f.user_id == ^user.id,
      where: f.post_id == ^id
    with 0 <- Repo.aggregate(query, :count, :id),
         params <- %{user_id: user.id, post_id: id},
         changeset <- Fav.changeset(%Fav{}, params),
         {:ok, fav} <- Repo.insert(changeset) do
      Task.start(fn -> Share.Notice.add_fav_notice(user, Fav.preload(fav)) end)
      {:reply, :ok, socket}
    else
      _ -> {:reply, :error, socket}
    end
  end

  def handle_in("unfav", %{"id" => id}, socket) do
    user = socket.assigns.user
    query = from f in Fav,
      where: f.user_id == ^user.id,
      where: f.post_id == ^id
    case Repo.one(query) do
      nil -> {:reply, :error, socket}
      fav -> case Repo.delete(fav) do
        {:ok, _} -> {:reply, :ok, socket}
        _ -> {:reply, :error, socket}
      end
    end
  end

  def handle_in("follow", %{"id" => id}, socket) do
    user = socket.assigns.user
    query = from f in Follow,
      where: f.user_id == ^user.id,
      where: f.target_user_id == ^id
    with true <- user.id != id,
         0 <- Repo.aggregate(query, :count, :id),
         params <- %{user_id: user.id, target_user_id: id},
         changeset <- Follow.changeset(%Follow{}, params),
         {:ok, follow} <- Repo.insert(changeset) do
      Task.start(fn -> Share.Notice.add_follow_notice(user, Follow.preload(follow)) end)
      {:reply, :ok, socket}
    else
      _ -> {:reply, :error, socket}
    end
  end

  def handle_in("unfollow", %{"id" => id}, socket) do
    user = socket.assigns.user
    query = from f in Follow,
      where: f.user_id == ^user.id,
      where: f.target_user_id == ^id
    case Repo.one(query) do
      nil -> {:reply, :error, socket}
      follow -> case Repo.delete(follow) do
        {:ok, _} -> {:reply, :ok, socket}
        _ -> {:reply, :error, socket}
      end
    end
  end

  def handle_in("open_notices", %{"noticed" => noticed}, socket) do
    user = socket.assigns.user
    user = Repo.get!(User, user.id)
    {:ok, noticed} = NaiveDateTime.from_iso8601(noticed)
    changeset = Ecto.Changeset.change(user, noticed: noticed)
    case Repo.update(changeset) do
      {:ok, user} ->
        {:reply, {:ok, %{noticed: user.noticed}}, socket}
      _ -> {:reply, :error, socket}
    end
  end

  def handle_in("timeline", _params, socket) do
    user = socket.assigns.user
    timeline = get_timeline(user, socket)
    {:reply, {:ok, timeline}, socket}
  end

  def handle_in("send_to_online", params, socket) do
    user = socket.assigns.user
    user = Repo.get!(User, user.id)
    %{"post_id" => post_id} = params
    case Repo.get(Post, post_id) do
      nil -> {:reply, :error, socket}
      post ->
        post = Post.preload(post)
        post = %{
          text: nil, user: user, id: UUID.uuid4(),
          inserted_at: NaiveDateTime.utc_now(),
          post: post,
          post_addresses: [],
          isOnlinePost: false
        }
        Share.OnlinePostHandler.handle(post, user)
        {:reply, :ok, socket}
    end
  end

  def handle_in("online_post", params, socket) do
    user = socket.assigns.user
    user = Repo.get!(User, user.id)
    %{"text" => text} = params
    post = %{
      text: text, user: user, id: UUID.uuid4(),
      inserted_at: NaiveDateTime.utc_now(),
      post_addresses: [],
      isOnlinePost: true
    }
    Share.OnlinePostHandler.handle(post, user)
    {:reply, :ok, socket}
  end

  defp get_timeline(user, socket) do
    query = from f in Follow,
      select: f.target_user_id,
      where: f.user_id == ^user.id
    users = [user.id | Repo.all(query)]
    query = Post
            |> where([p], p.user_id in ^users)
            |> order_by([p], [desc: p.id])
            |> limit(50)
            |> Post.preload()
    posts = Repo.all(query)
    post_ids = posts |> Enum.map(&(&1.id))
    favs = Fav.get_favs(socket, post_ids)
    %{posts: posts, favs: favs}
  end

  defp get_user_params(user, socket) do
    user = Repo.get!(User, user.id)

    query = from u in User,
      where: u.provider == ^user.provider,
      where: u.provided_id == ^user.provided_id,
      where: u.id != ^user.id
    users = Repo.all(query)

    timeline = get_timeline(user, socket)

    query = from f in Follow,
      select: f.target_user_id,
      where: f.user_id == ^user.id
    following = Repo.all(query)

    query = from fav in Fav,
      join: post in Post,
      on: post.id == fav.post_id,
      where: post.user_id == ^user.id,
      order_by: [desc: :id],
      limit: 50
    favs = Repo.all(Fav.preload(query))
           |> Enum.map(fn fav -> %{id: fav.id, user: fav.user, post: fav.post, inserted_at: fav.inserted_at} end)

    query = from follow in Follow,
      where: follow.target_user_id == ^user.id,
      order_by: [desc: :id],
      limit: 50
    follows = Repo.all(Follow.preload(query))
              |> Enum.map(fn follow -> %{id: follow.id, user: follow.user, inserted_at: follow.inserted_at} end)

    query = from follow in Follow,
      where: follow.target_user_id == ^user.id,
      select: follow.user_id
    followers = Repo.all(query)

    query = from post in Post,
      join: address in PostAddress,
      on: post.id == address.post_id,
      where: address.user_id == ^user.id,
      where: is_nil(post.post_id),
      order_by: [desc: :id],
      limit: 50
    addresses = Repo.all(Post.preload(query))

    query = from post in Post,
      join: address in PostAddress,
      on: post.id == address.post_id,
      where: address.user_id == ^user.id,
      where: not is_nil(post.post_id),
      order_by: [desc: :id],
      limit: 50
    replies = Repo.all(Post.preload(query))

    %{
      user: user,
      users: users,
      timeline: timeline,
      following: following,
      followers: followers,
      noticed: user.noticed,
      notices: %{
        favs: favs,
        follows: follows,
        addresses: addresses,
        replies: replies
      }
    }
  end
end
