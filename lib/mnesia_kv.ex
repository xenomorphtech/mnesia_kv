defmodule MnesiaKV do
  def load(tables) do
    loaded_tables = GenServer.call(MnesiaKV.Gen, {:load, tables})
    if loaded_tables != [] do
      IO.puts "MnesiaKV loaded #{inspect loaded_tables}!"
    end
  end

  def load_table(table, db) do
    {:ok, iter} = :rocker.iterator(db, {:start})
    load_table_1(table, iter)
  end

  defp load_table_1(table, iter) do
    case :rocker.next(iter) do
      :ok -> :ok

      {:ok, key, value} ->
        map = :erlang.binary_to_term(value)
        :ets.insert(table, {key, map})
        load_table_1(table, iter)
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

  def make_table(table) do
    try do
      :ets.new(table, [:ordered_set, :named_table, :public, {:write_concurrency, true}, {:read_concurrency, true}])
    catch
      :error, :badarg -> IO.inspect(:already_has_ets)
    end

    db = try do
      :ok = File.mkdir_p!("mnesia_kv")
      {:ok, db} = :rocker.open_default("mnesia_kv/#{table}")
      load_table(table, db)
      :persistent_term.put({:mnesia_kv_db, table}, db)
      db
    catch
      :error, {:badmatch, {:err, "IO error: While lock file: " <> _}} ->
        IO.inspect({:already_opened_rocks, __STACKTRACE__})
        :error
    end

    db
  end

  def merge(table, key, diff_map, subscription \\ true) do
    db = :persistent_term.get({:mnesia_kv_db, table})
    ts_s = :os.system_time(1)

    try do
      #update existing
      old_map = :ets.lookup_element(table, key, 2)
      map = merge_nested(old_map, diff_map)
      if map == old_map do
      else
        Map.put(map, :_tsu, ts_s)
        :ok = :rocker.put(db, key, :erlang.term_to_binary(map))
        :ets.insert(table, {key, map})
        subscription && proc_subscriptions_merge(table, key, map, diff_map)
      end
    catch
      :error, :badarg ->
        #insert new
        map = Map.merge(diff_map, %{uuid: key, _tsc: ts_s, _tsu: ts_s})
        :ok = :rocker.put(db, key, :erlang.term_to_binary(map))
        :ets.insert(table, {key, map})
        subscription && proc_subscriptions_new(table, key, diff_map)
    end
  end

  def delete(table, key) do
    db = :persistent_term.get({:mnesia_kv_db, table})

    :ok = :rocker.delete(db, key)
    :ets.delete(table, key)
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

  def match_object(table, match_spec) do
    :ets.match_object(table, match_spec) |> Enum.map(&elem(&1, 1))
  end

  def keys(table) do
    :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  def size(table) do
    :ets.info(table, :size)
  end
end
