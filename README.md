![](https://images.ctfassets.net/1d31s1aajogl/6BraicTqvnQdNp6BLyJ7LG/b42ac2da1ce881fc47244307e909abcd/RocksDB-pacman.png)

### About
OTP23+ only.

Deepmerged key value database (/w diff subscriptions) ontop of ETS with RocksDB for persistence / dataloss protection.

### Deps

```
For rocker:
rust, libclang

On ubuntu:

apt install libclang-dev

sed -e 's|/root/.cargo/bin:||g' -i /etc/environment
sed -e 's|PATH="\(.*\)"|PATH="/root/.cargo/bin:\1"|g' -i /etc/environment
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs/ | sh -s -- -y
```

### Philosopy

ETS + RethinkDB + RockDB.

ETS is amazing for speedy queries and data compatibility.

RethinkDB has seamless event subscription streams.

RocksDB is amazing for dataloss protection.



All changes can be subscribed to.

All subscription notifications are diffs.

Only 2 operations, merge and delete.

Any query that works on ets will work.

### Problem with Mnesia

You lose data

https://bugs.erlang.org/browse/ERL-831

https://bugs.erlang.org/browse/ERL-1389


This is because Mnesia in :disc_copies mode does not use a WAL but instead periodically based on `dump_log_time_threshold` (total time elapsed)
or `dump_log_write_threshold` (total writes that occured) decides when to flush changes from ram to disk.

### Parts

:rocker https://github.com/Vonmo/rocker for rust rocksdb via rustler

:pg https://erlang.org/doc/man/pg.html new OTP 23 PG module for subscriptions

### Todo

[ ] More subscription filters

[ ] :rocker warnings with new rustler

[ ] transactions

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

{:mnesia_kv_event, :merge, Account, ^new_acc_uuid, _full_map, _diff = %{age: 1}} =
    receive do msg -> msg after 1 -> nil end

#Delete data
MnesiaKV.delete(Account, new_acc_uuid)

{:mnesia_kv_event, :delete, Account, ^new_acc_uuid} =
    receive do msg -> msg after 1 -> nil end


#Subscribe to all changes
MnesiaKV.subscribe(Account)

MnesiaKV.merge(Account, new_acc_uuid, %{age: 2})

{:mnesia_kv_event, :new, Account, ^new_acc_uuid, _full_map = %{age: 2}} =
    receive do msg -> msg after 1 -> nil end

```

### Benchmarks

```
4 core i5-7500 CPU @ 3.40GHz
ext4, consumer SSD

MnesiaKV.Bench.write_to_file_unsafe(4)
1.6m write tps

MnesiaKV.Bench.mnesia(4)
266k write tps

MnesiaKV.Bench.rocksdb(4)
120k write tps


8/16 core i9-9900K CPU @ 3.60GHz
XFS, PM981 NVME

MnesiaKV.Bench.write_to_file_unsafe(16)
5m write tps
MnesiaKV.Bench.write_to_file_unsafe(12)
5m write tps
MnesiaKV.Bench.write_to_file_unsafe(8)
3.8m write tps

MnesiaKV.Bench.mnesia(16)
640k write tps
MnesiaKV.Bench.mnesia(12)
1.02m write tps
MnesiaKV.Bench.mnesia(8)
1m write tps

MnesiaKV.Bench.rocksdb(16)
160k write tps
MnesiaKV.Bench.rocksdb(12)
189k write tps
MnesiaKV.Bench.rocksdb(8)
228k write tps
MnesiaKV.Bench.rocksdb(4)
260k write tps
MnesiaKV.Bench.rocksdb(1)
330k write tps
```

Based on these benchmarks if losing up to 8ms of data (if app crashes) or more in case of power outage is okay, unsafe journal makes sense.

Rocksdb performance seems to drop as the concurrent writers increase.
