defmodule MnesiaKV.MixProject do
  use Mix.Project

  def project do
    [
      app: :mnesia_kv,
      version: "0.1.0",
      elixir: ">= 1.11.1",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto],
      mod: {MnesiaKV.App, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rocksdb, git: "https://gitlab.com/vans/erlang-rocksdb.git", branch: "fix-gcc13"}
    ]
  end
end
