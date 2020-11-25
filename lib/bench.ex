defmodule MnesiaKV.Bench do
  def make_ets() do
    try do
      :ets.new(Bench, [:ordered_set, :named_table, :public, {:write_concurrency,true}, {:read_concurrency, true}])
    catch _,_ -> nil end
  end

  #can lose up to 8ms of data if app gets killed
  def write_to_file_unsafe(threads \\ 4) do
    make_ets()
    Enum.each(1..threads, fn(_idx)->
      :erlang.spawn_opt(fn()->
        {:ok, file} = :file.open("/tmp/dump", [:write, :raw, :binary, {:delayed_write, 524288, 8}])
        {took, _} = :timer.tc(fn()->
          Enum.each(1..100000, fn(_key) ->
            key = :rand.uniform(10000)
            term = {
              key,
              case :ets.lookup(Bench, key) do
                [] -> %{field: :rand.uniform(1000000)}
                [{_,old}] -> Map.merge(old, %{field: :rand.uniform(100000)})
              end
            }
            bin_term = :erlang.term_to_binary(term)
           :ok = :file.write(file, <<byte_size(bin_term)::16-little>> <> bin_term)
            #System.halt()
            :ets.insert(Bench, term)
          end)
        end)
        took = took / 1000
        IO.inspect took
      end, [{:min_heap_size, 512}])
    end)
  end

  def mnesia(threads \\ 4) do
    ignore_warning = :mnesia
    ignore_warning.create_schema([:erlang.node()])
    :application.ensure_all_started(:mnesia)
    ignore_warning.create_table(BenchMnesia,
      disc_copies: [node()],
      type: :ordered_set,
      attributes: [:uuid, :data]
    )
    ignore_warning.wait_for_tables(ignore_warning.system_info(:local_tables), :infinity)

    Enum.each(1..threads, fn(_idx)->
      :erlang.spawn_opt(fn()->
        {took, _} = :timer.tc(fn()->
          Enum.each(1..100000, fn(_key) ->
            key = :rand.uniform(10000)
            map = case ignore_warning.dirty_read(BenchMnesia, key) do
              [] -> %{field: :rand.uniform(1000000)}
              [{_,_,old}] -> Map.merge(old, %{field: :rand.uniform(100000)})
            end

            #System.halt()
            ignore_warning.dirty_write(BenchMnesia, {BenchMnesia, key, map})
          end)
        end)
        took = took / 1000
        IO.inspect took
      end, [{:min_heap_size, 512}])
    end)
  end

  def rocksdb(threads \\ 4) do
    make_ets()
    {:ok, db} = :rocker.open_default("mnesia_kv/Elixir.Bench")
    Enum.each(1..threads, fn(_idx)->
      :erlang.spawn_opt(fn()->
        {took, _} = :timer.tc(fn()->
          Enum.each(1..100000, fn(_key) ->
            key = :rand.uniform(10000)
            map = case :ets.lookup(Bench, key) do
              [] -> %{field: :rand.uniform(1000000)}
              [{_,old}] -> Map.merge(old, %{field: :rand.uniform(100000)})
            end

            :ok = :rocker.put(db, "#{key}", :erlang.term_to_binary(map))
            #System.halt()
            :ets.insert(Bench, {key, map})
          end)
        end)
        took = took / 1000
        IO.inspect took
      end, [{:min_heap_size, 512}])
    end)
  end

end
