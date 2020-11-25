### About
OTP23+ only.

Deepmerged key value database (/w diff subscriptions) ontop of ETS with RocksDB for persistence / dataloss protection.

### Reason
Mnesia with disc_copies loses data simply due to lack of a WAL.

Mnesia is slow and locks tables when it dumps to disk.

Sure this can be fixed by using distributed Mnesia but it gets difficult, if someone trips over the powercord going to the rack your
cluster is on, you will still lose data.

### Philosopy

ETS + RethinkDB + RockDB.

ETS is amazing for speed and data compability.

RethinkDB has seamless event subscription streams.

RocksDB is amazing for dataloss protection.



All changes can be subscribed to.

All subcription notifications are diffs.

Only 2 operations, merge and delete.

Any query that works on ets will work.

### Problem with Mnesia

You lose data

https://bugs.erlang.org/browse/ERL-831
https://bugs.erlang.org/browse/ERL-1389

alot of it.

This is because Mnesia does not use a WAL but instead periodically based on `dump_log_time_threshold` (total time elapsed)
or `dump_log_write_threshold` (total writes that occured) decides when to flush changes from ram to disk.

### Parts

:rocker https://github.com/Vonmo/rocker for rust rocksdb via rustler
:pg https://erlang.org/doc/man/pg.html new OTP 23 PG module for subscriptions

### Todo

[ ] More subscription filters
[ ] :rocker warnings with new rustler

### UUID function

MnesiaKV has its own simple timebased UUID function `MnesiaKV.uuid()`

This works well with the ordered_set table that backs it.

Feel free to use it if you wish.


```
"w6IFq53Bknb" = MnesiaKV.uuid()
"w6IFqbWoIyj" = MnesiaKV.uuid()
"w6IFqivwMzu" = MnesiaKV.uuid()
```

### API

MnesiaKV stores each rocksdb under `mnesia_kv/` in the current working dir.

Each subfolder containing the rocksdb database is the name of the ets table.

Tables are automagically created if they dont exist.

```elixir
#Make sure MnesiaKV app is started
{:ok, _} = :application.ensure_all_started(:mnesia_kv)

#At the start of your app run
MnesiaKV.load()

#Write data
new_acc_uuid = MnesiaKV.uuid()
MnesiaKV.merge(Account, new_acc_uuid,
    %{username: "roaringtt", password: "CxfhZdUnbXQoZXxvWkRDK83qZ3TjQI+CMnSRAwaQMSM="})

#Update data
MnesiaKV.merge(Account, new_acc_uuid, %{age: 376})

#Read data
%{age: 376} = MnesiaKV.get(Account, new_acc_uuid)

#Subscribe to changes
MnesiaKV.subscribe_by_key(Account, new_acc_uuid)

MnesiaKV.merge(Account, new_acc_uuid, %{age: 1})

{:mnesia_kv_event, :merge, Account, ^new_acc_uuid, %{age: 1}} =
    receive do msg -> msg after 1 -> nil end

#Delete data
MnesiaKV.delete(Account, new_acc_uuid)

{:mnesia_kv_event, :delete, Account, ^new_acc_uuid} =
receive do msg -> msg after 1 -> nil end
```
