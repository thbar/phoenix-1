defmodule Phoenix.Presence do
  @moduledoc """
  TODO


  ## Fetching Presence Information

      def fetch(_topic, entries) do
        query =
          from p in Post,
            where: p.id in ^Map.keys(entries),
            select: {p.id, p}

        posts = query |> Repo.all |> Enum.into(%{})

        for {key, %{metas: metas}} <- entries, into: %{} do
          {key, %{metas: metas, post: posts[key]}}
        end
      end

  """
  alias Phoenix.Socket.Broadcast

  @type presences :: %{ String.t => %{metas: [map]}}
  @type presence :: %{key: String.t, meta: map}
  @type topic :: String.t

  @callback start_link(Keyword.t) :: {:ok, pid} | {:error, reason :: term} :: :ignore
  @callback init(Keyword.t) :: {:ok, pid} | {:error, reason :: term}
  @callback track_presence(Phoenix.Socket.t, key :: String.t, meta :: map) :: :ok
  @callback track_presence(pid, topic, key :: String.t, meta ::map) :: :ok
  @callback fetch(topic, presences) :: presences
  @callback list(topic) :: presences
  @callback handle_join(topic, presence, state :: term) :: {:ok, state :: term}
  @callback handle_leave(topic, presence, state :: term) :: {:ok, state :: term}

  defmacro __using__(opts) do
    quote do
      @otp_app unquote(opts)[:otp_app] || raise "presence expects :otp_app to be given"
      @behaviour unquote(__MODULE__)
      @task_supervisor Module.concat(__MODULE__, TaskSupervisor)

      def start_link(opts \\ []) do
        Phoenix.Presence.start_link(__MODULE__, @otp_app, @task_supervisor, opts)
      end

      def init(opts) do
        server = Keyword.fetch!(opts, :pubsub_server)
        {:ok, %{pubsub_server: server,
                node_name: Phoenix.PubSub.node_name(server),
                task_sup: @task_supervisor}}
      end

      def track_presence(%Phoenix.Socket{} = socket, key, meta) do
        track_presence(socket.channel_pid, socket.topic, key, meta)
      end
      def track_presence(pid, topic, key, meta) do
        Phoenix.Tracker.track(__MODULE__, pid, topic, key, meta)
      end

      def fetch(_topic, presences), do: presences

      def list(topic) do
        Phoenix.Presence.list(__MODULE__, topic)
      end

      def handle_join(topic, presence, state) do
        Phoenix.Presence.handle_join(__MODULE__,
          topic, presence, state.node_name, state.pubsub_server, state.task_sup
        )
        {:ok, state}
      end

      def handle_leave(topic, presence, state) do
        Phoenix.Presence.handle_leave(__MODULE__,
          topic, presence, state.node_name, state.pubsub_server, state.task_sup
        )
        {:ok, state}
      end

      defoverridable fetch: 2
    end
  end

  @doc """
  Starts the presence supervisor.
  """
  def start_link(module, otp_app, task_supervisor, opts) do
    import Supervisor.Spec
    opts =
      opts
      |> Keyword.merge(Application.get_env(otp_app, module) || [])
      |> Keyword.put(:name, module)

    children = [
      supervisor(Task.Supervisor, [[name: task_supervisor]]),
      worker(Phoenix.Tracker, [module, opts, opts])
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  @doc """
  TODO
  """
  def handle_join(module, topic, {key, meta}, node_name, pubsub_server, sup_name) do
    Task.Supervisor.start_child(sup_name, fn ->
      presence_info = module.fetch(topic, %{key => %{metas: [meta]}})
      msg = %Broadcast{topic: topic, event: "presence_join", payload: presence_info}
      Phoenix.PubSub.direct_broadcast!(node_name, pubsub_server, topic, msg)
    end)
  end

  @doc """
  TODO
  """
  def handle_leave(module, topic, {key, meta}, node_name, pubsub_server, sup_name) do
    Task.Supervisor.start_child(sup_name, fn ->
      presence_info = module.fetch(topic, %{key => %{metas: [meta]}})
      msg = %Broadcast{topic: topic, event: "presence_leave", payload: presence_info}
      Phoenix.PubSub.direct_broadcast!(node_name, pubsub_server, topic, msg)
    end)
  end

  @doc """
  TODO
  """
  def list(module, topic) do
    grouped =
      module
      |> Phoenix.Tracker.list(topic)
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn {key, meta}, acc ->
        Map.update(acc, key, %{metas: [meta]}, fn %{metas: metas} ->
          %{metas: [meta | metas]}
        end)
      end)

    module.fetch(topic, grouped)
  end
end
