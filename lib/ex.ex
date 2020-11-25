defmodule MnesiaKV.App do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    supervisor =
      Supervisor.start_link(
        [
          {DynamicSupervisor, strategy: :one_for_one, name: MnesiaKV.Supervisor, max_seconds: 1, max_restarts: 999_999_999_999}
        ],
        strategy: :one_for_one
      )

    {:ok, _} = DynamicSupervisor.start_child(MnesiaKV.Supervisor, %{id: PGMnesiaKVByKey, start: {:pg, :start_link, [PGMnesiaKVByKey]}})

    supervisor
  end
end
