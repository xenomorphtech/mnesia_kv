defmodule MnesiaKV do
  def load(tables, options \\ %{}) do
    loaded_tables = GenServer.call(MnesiaKV.Gen, {:load, tables, options}, 180_000)

    if loaded_tables != [] do
      IO.puts("MnesiaKV loaded #{inspect(loaded_tables)} #{inspect(options)}!")
    end
  end

  def load_table(table, args, db) do
    {:ok, iter} = :rocksdb.iterator(db, [])
    load_table_1(table, args, iter)
  end

  defp load_table_1(table, args, iter, itr_type \\ :first) do
    case :rocksdb.iterator_move(iter, itr_type) do
      {:error, :invalid_iterator} ->
        :rocksdb.iterator_close(iter)

      {:ok, key, value} ->
        key =
          case args[:key_type] do
            :elixir_term ->
              {key, []} = Code.eval_string(key)
              key

            _ ->
              key
          end

        map = :erlang.binary_to_term(value)
        :ets.insert(table, {key, map})
        index_add(table, key, map, args)
        load_table_1(table, args, iter, :next)
    end
  end

  defp index_add(table, key, map, args) do
    index_map = if args[:index], do: Map.take(map, args.index)

    if index_map do
      index_delete(table, key, args)
      index_tuple = :erlang.list_to_tuple([key] ++ Enum.map(args.index, &index_map[&1]))
      :ets.insert(:"#{table}_index", {index_tuple, key})
    end
  end

  defp index_delete(table, key, args) do
    if args[:index] do
      index_tuple = :erlang.list_to_tuple([key] ++ Enum.map(args.index, & &1 && :_))
      :ets.match_delete(:"#{table}_index", {index_tuple, :_})
    end
  end

  def merge_nested(left, right) do
    Map.merge(left, right, &merge_nested_resolve/3)
  end

  defp merge_nested_resolve(_, left, right) do
    case {is_map(left), is_map(right)} do
      {true, true} -> merge_nested(left, right)
      _ -> right
    end
  end

  defp proc_subscriptions_new(table, key, map) do
    :pg.get_local_members(PGMnesiaKVSubscribeByKey, {table, key})
    |> Enum.each(&send(&1, {:mnesia_kv_event, :new, table, key, map}))

    :pg.get_local_members(PGMnesiaKVSubscribe, table)
    |> Enum.each(&send(&1, {:mnesia_kv_event, :new, table, key, map}))
  end

  defp proc_subscriptions_merge(table, key, map, diff_map) do
    :pg.get_local_members(PGMnesiaKVSubscribeByKey, {table, key})
    |> Enum.each(&send(&1, {:mnesia_kv_event, :merge, table, key, map, diff_map}))

    :pg.get_local_members(PGMnesiaKVSubscribe, table)
    |> Enum.each(&send(&1, {:mnesia_kv_event, :merge, table, key, map, diff_map}))
  end

  defp proc_subscriptions_delete(table, key) do
    :pg.get_local_members(PGMnesiaKVSubscribeByKey, {table, key})
    |> Enum.each(&send(&1, {:mnesia_kv_event, :delete, table, key}))

    :pg.get_local_members(PGMnesiaKVSubscribe, table)
    |> Enum.each(&send(&1, {:mnesia_kv_event, :delete, table, key}))
  end

  def uuid(random_bytes \\ 3) do
    MnesiaKV.Uuid.generate(random_bytes)
  end

  def subscribe(table, pid \\ nil) do
    pid = if pid, do: pid, else: self()
    :pg.join(PGMnesiaKVSubscribe, table, pid)
  end

  def subscribe_by_key(table, key, pid \\ nil) do
    pid = if pid, do: pid, else: self()
    :pg.join(PGMnesiaKVSubscribeByKey, {table, key}, pid)
  end

  def unsubscribe(table, pid \\ nil) do
    pid = if pid, do: pid, else: self()
    :pg.leave(PGMnesiaKVSubscribe, table, pid)
  end

  def unsubscribe_by_key(table, key, pid \\ nil) do
    pid = if pid, do: pid, else: self()
    :pg.leave(PGMnesiaKVSubscribeByKey, {table, key}, pid)
  end

  def make_table(table, args, path) do
    try do
      :ets.new(table, [:ordered_set, :named_table, :public, {:write_concurrency, true}, {:read_concurrency, true}])

      if args[:index] do
        :ets.new(:"#{table}_index", [:ordered_set, :named_table, :public, {:write_concurrency, true}, {:read_concurrency, true}])
      end
    catch
      :error, :badarg -> IO.inspect(:already_has_ets)
    end

    db =
      try do
        :ok = File.mkdir_p!(path)
        {:ok, db} = :rocksdb.open('#{path}/#{table}', [{:create_if_missing, true}, {:unordered_write, true}])
        load_table(table, args, db)
        :persistent_term.put({:mnesia_kv_db, table}, %{db: db, args: args})
        db
      catch
        :error, {:badmatch, {:err, "IO error: While lock file: " <> _}} ->
          IO.inspect({:already_opened_rocks, __STACKTRACE__})
          :error
      end

    db
  end

  def merge(table, key, diff_map, subscription \\ true) do
    ts_s = :os.system_time(1)
    %{db: db, args: args} = :persistent_term.get({:mnesia_kv_db, table})

    key_rocks =
      case args[:key_type] do
        :elixir_term -> "#{inspect(key)}"
        _ -> key
      end

    try do
      # update existing
      old_map = :ets.lookup_element(table, key, 2)
      map = merge_nested(old_map, diff_map)

      if map == old_map do
      else
        map = Map.put(map, :_tsu, ts_s)
        :ok = :rocksdb.put(db, key_rocks, :erlang.term_to_binary(map), [])
        :ets.insert(table, {key, map})
        index_add(table, key, map, args)
        subscription && proc_subscriptions_merge(table, key, map, diff_map)
      end
    catch
      :error, :badarg ->
        # insert new
        map = Map.merge(diff_map, %{uuid: key, _tsc: ts_s, _tsu: ts_s})
        :ok = :rocksdb.put(db, key_rocks, :erlang.term_to_binary(map), [])
        :ets.insert(table, {key, map})
        index_add(table, key, map, args)
        subscription && proc_subscriptions_new(table, key, diff_map)
    end
  end

  def merge_override(table, key, diff_map, subscription \\ true) do
    ts_s = :os.system_time(1)
    %{db: db, args: args} = :persistent_term.get({:mnesia_kv_db, table})

    key_rocks =
      case args[:key_type] do
        :elixir_term -> "#{inspect(key)}"
        _ -> key
      end

    try do
      # update existing
      old_map = :ets.lookup_element(table, key, 2)
      map = Map.merge(old_map, diff_map)

      if map == old_map do
      else
        map = Map.put(map, :_tsu, ts_s)
        :ok = :rocksdb.put(db, key_rocks, :erlang.term_to_binary(map), [])
        :ets.insert(table, {key, map})
        index_add(table, key, map, args)
        subscription && proc_subscriptions_merge(table, key, map, diff_map)
      end
    catch
      :error, :badarg ->
        # insert new
        map = Map.merge(diff_map, %{uuid: key, _tsc: ts_s, _tsu: ts_s})
        :ok = :rocksdb.put(db, key_rocks, :erlang.term_to_binary(map), [])
        :ets.insert(table, {key, map})
        index_add(table, key, map, args)
        subscription && proc_subscriptions_new(table, key, diff_map)
    end
  end

  def update(table, key, diff_map, subscription \\ true) do
    ts_s = :os.system_time(1)
    %{db: db, args: args} = :persistent_term.get({:mnesia_kv_db, table})

    key_rocks =
      case args[:key_type] do
        :elixir_term -> "#{inspect(key)}"
        _ -> key
      end

    try do
      # update existing
      old_map = :ets.lookup_element(table, key, 2)
      map = merge_nested(old_map, diff_map)

      if map == old_map do
      else
        map = Map.put(map, :_tsu, ts_s)
        :ok = :rocksdb.put(db, key_rocks, :erlang.term_to_binary(map), [])
        :ets.insert(table, {key, map})
        index_add(table, key, map, args)
        subscription && proc_subscriptions_merge(table, key, map, diff_map)
      end
    catch
      :error, :badarg -> nil
    end
  end

  def increment_counter(table, key, amount) do
    %{db: db, args: args} = :persistent_term.get({:mnesia_kv_db, table})

    key_rocks =
      case args[:key_type] do
        :elixir_term -> "#{inspect(key)}"
        _ -> key
      end

    new_counter = :ets.update_counter(table, key, {2, amount}, {key, 0})
    :ok = :rocksdb.put(db, key_rocks, :erlang.term_to_binary(new_counter), [])
  end

  def delete(table, key) do
    %{db: db, args: args} = :persistent_term.get({:mnesia_kv_db, table})

    key_rocks =
      case args[:key_type] do
        :elixir_term -> "#{inspect(key)}"
        _ -> key
      end

    :ok = :rocksdb.delete(db, key_rocks, [])
    :ets.delete(table, key)
    index_delete(table, key, args)
    proc_subscriptions_delete(table, key)
  end

  def random(table) do
    size = :ets.info(table, :size)

    if size > 0 do
      [{_, data}] = :ets.slot(table, :rand.uniform(size) - 1)
      data
    end
  end

  def get(table, key) do
    try do
      :ets.lookup_element(table, key, 2)
    catch
      :error, :badarg -> nil
    end
  end

  def get(table) do
    :ets.select(table, [{{:_, :"$1"}, [], [:"$1"]}])
  end

  def get_spec(table, key, spec, result_format) do
    case :ets.select(table, [{{key, spec}, [], [result_format]}]) do
      [result] -> result
      [] -> nil
    end
  end

  def get_spec!(table, key, spec, result_format) do
    case :ets.select(table, [{{key, spec}, [], [result_format]}]) do
      [result] -> result
      [] -> throw({:spec_not_found, {table, key, spec, result_format}})
    end
  end

  def exists(table, key) do
    try do
      :ets.lookup_element(table, key, 1)
      true
    catch
      :error, :badarg -> false
    end
  end

  def match_object(table, match_spec) do
    :ets.match_object(table, match_spec) |> Enum.map(&elem(&1, 1))
  end

  def match_object_index(table, map) do
    %{args: args} = :persistent_term.get({:mnesia_kv_db, table})
    if !args[:index], do: throw(%{error: :no_index})

    index_args = [:key] ++ args.index

    index_tuple =
      :erlang.list_to_tuple(
        Enum.map(index_args, fn index ->
          case Map.fetch(map, index) do
            :error -> :_
            {:ok, value} -> value
          end
        end)
      )

    match_spec = [{{index_tuple, :"$2"}, [], [:"$2"]}]
    :ets.select(:"#{table}_index", match_spec)
  end

  def keys(table) do
    :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  def size(table) do
    :ets.info(table, :size)
  end

  def clear(table) do
    :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
    |> Enum.each(&delete(table, &1))
  end
end
