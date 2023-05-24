defmodule MnesiaKV.Gen do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, tables, options}, _from, state) do
    loaded_tables =
      tables
      |> Enum.map(fn {table, args} ->
        db = :persistent_term.get({:mnesia_kv_db, table}, nil)

        if is_nil(db) do
          if options[:log] do
            IO.puts("MnesiaKV loading #{table} #{inspect(options)}")
          end
          path = options[:path] || "mnesia_kv/"
          extra_options = options[:extra_options] || []
          db = MnesiaKV.make_table(table, args, path, extra_options)
          table
        end
      end)
      |> Enum.filter(& &1)

    {:reply, loaded_tables, state}
  end
end
