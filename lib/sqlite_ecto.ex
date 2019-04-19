defmodule Sqlite.Ecto2 do
  @moduledoc ~S"""
  Ecto Adapter module for SQLite.

  It uses Sqlitex and Esqlite for accessing the SQLite database.

  ## Configuration Options

  When creating an `Ecto.Repo` that uses a SQLite database, you should configure
  it as follows:

  ```elixir
  # In your config/config.exs file
  config :my_app, Repo,
    adapter: Sqlite.Ecto2,
    database: "ecto_simple.sqlite3"

  # In your application code
  defmodule Repo do
    use Ecto.Repo,
      otp_app: :my_app,
      adapter: Sqlite.Ecto2
  end
  ```

  You may use other options as specified in the `Ecto.Repo` documentation.

  Note that the `:database` option is passed as the `filename` argument to
  [`sqlite3_open_v2`](http://sqlite.org/c3ref/open.html). This implies that you
  may use `:memory:` to create a private, temporary in-memory database.

  See also [SQLite's interpretation of URI "filenames"](https://sqlite.org/uri.html)
  for more options such as shared memory caches.
  """

  # Inherit all behaviour from Ecto.Adapters.SQL
  use Ecto.Adapters.SQL, :sqlitex

  # And provide a custom storage implementation
  @behaviour Ecto.Adapter.Storage

  ## Custom SQLite Types

  @impl true
  def loaders(:boolean, type), do: [&bool_decode/1, type]
  def loaders(:binary_id, type), do: [Ecto.UUID, type]
  def loaders(:date, type), do: [&date_decode/1, type]
  def loaders(:utc_datetime, type), do: [&datetime_decode/1, type]
  def loaders(:naive_datetime, type), do: [&naive_datetime_decode/1, type]

  def loaders({:embed, _} = type, _),
    do: [&json_decode/1, &Ecto.Adapters.SQL.load_embed(type, &1)]

  def loaders(:map, type), do: [&json_decode/1, type]
  def loaders({:map, _}, type), do: [&json_decode/1, type]
  def loaders({:array, _}, type), do: [&json_decode/1, type]
  def loaders(:float, type), do: [&float_decode/1, type]
  def loaders(_primitive, type), do: [type]

  defp bool_decode(0), do: {:ok, false}
  defp bool_decode(1), do: {:ok, true}
  defp bool_decode(x), do: {:ok, x}

  defp date_decode(tuple), do: Date.from_erl(tuple)

  defp datetime_decode(datetime) do
    {:ok, naive_datetime} = naive_datetime_decode(datetime)
    DateTime.from_naive(naive_datetime, "Etc/UTC")
  end

  # defp datetime_decode({y, m, d}), do: Date.new(y, m, d)

  defp naive_datetime_decode(binary) when is_binary(binary),
    do: NaiveDateTime.from_iso8601(binary)

  defp naive_datetime_decode({{y, m, d}, {min, sec, microsecond, _}}),
    do: NaiveDateTime.new(y, m, d, min, sec, microsecond)

  defp json_decode(x) when is_binary(x),
    # TODO: change this
    do: {:ok, Application.get_env(:ecto, :json_library, Jason).decode!(x)}

  defp json_decode(x),
    do: {:ok, x}

  defp float_decode(x) when is_integer(x), do: {:ok, x / 1}
  defp float_decode(x), do: {:ok, x}

  def dumpers(:binary, type), do: [type, &blob_encode/1]
  def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  def dumpers(:boolean, type), do: [type, &bool_encode/1]
  def dumpers({:embed, _} = type, _), do: [&Ecto.Adapters.SQL.dump_embed(type, &1)]
  def dumpers(:time, type), do: [type, &time_encode/1]
  def dumpers(_primitive, type), do: [type]

  defp blob_encode(value), do: {:ok, {:blob, value}}

  defp bool_encode(false), do: {:ok, 0}
  defp bool_encode(true), do: {:ok, 1}

  defp time_encode(value) do
    {:ok, value}
  end

  ## Storage API

  @impl true
  @doc false
  def storage_up(opts) do
    storage_up_with_path(Keyword.get(opts, :database), opts)
  end

  defp storage_up_with_path(nil, opts) do
    raise ArgumentError,
          """
          No SQLite database path specified. Please check the configuration for your Repo.
          Your config/*.exs file should have something like this in it:

            config :my_app, MyApp.Repo,
              adapter: Sqlite.Ecto2,
              database: "/path/to/sqlite/database"

          Options provided were:

          #{inspect(opts, pretty: true)}

          """
  end

  defp storage_up_with_path(database, _opts) do
    if File.exists?(database) do
      {:error, :already_up}
    else
      database |> Path.dirname() |> File.mkdir_p!()
      {:ok, db} = Sqlitex.open(database)
      :ok = Sqlitex.exec(db, "PRAGMA journal_mode = WAL")
      {:ok, [[journal_mode: "wal"]]} = Sqlitex.query(db, "PRAGMA journal_mode")
      Sqlitex.close(db)
      :ok
    end
  end

  @impl true
  @doc false
  def storage_down(opts) do
    database = Keyword.get(opts, :database)

    case File.rm(database) do
      {:error, :enoent} ->
        {:error, :already_down}

      result ->
        # ignore results for these files
        File.rm(database <> "-shm")
        File.rm(database <> "-wal")
        result
    end
  end

  @doc false
  def supports_ddl_transaction?, do: true

  # Since SQLite doesn't have locks, we use this version of lock_for_migrations
  # to disable the lock behavior and fall back to single-threaded migration.
  # See https://github.com/elixir-ecto/ecto/pull/2215#issuecomment-332497229.
  def lock_for_migrations(meta, query, _opts, callback) do
    %{opts: default_opts} = meta

    if Keyword.fetch(default_opts, :pool_size) == {:ok, 1} do
      raise_pool_size_error()
    end

    query
    |> Map.put(:lock, nil)
    |> callback.()
  end

  defp raise_pool_size_error do
    raise Ecto.MigrationError, """
    Migrations failed to run because the connection pool size is less than 2.

    Ecto requires a pool size of at least 2 to support concurrent migrators.
    When migrations run, Ecto uses one connection to maintain a lock and
    another to run migrations.

    If you are running migrations with Mix, you can increase the number
    of connections via the pool size option:

        mix ecto.migrate --pool-size 2

    If you are running the Ecto.Migrator programmatically, you can configure
    the pool size via your application config:

        config :my_app, Repo,
          ...,
          pool_size: 2 # at least
    """
  end
end
