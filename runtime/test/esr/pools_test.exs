defmodule Esr.PoolsTest do
  @moduledoc """
  P4a-7 — `Esr.Pools` reads the optional
  `${ESRD_HOME}/<instance>/pools.yaml` to override per-pool max-worker
  counts. Defaults come from an inline map (voice pools default 4);
  overrides are clamped to `Esr.PeerPool.default_max_workers/0`.
  """
  use ExUnit.Case, async: false

  @fixture Path.expand("../fixtures/pools/override.yaml", __DIR__)

  test "pool_max/2 returns default 4 when yaml absent" do
    assert Esr.Pools.pool_max(:voice_asr_pool, nil) == 4
    assert Esr.Pools.pool_max(:voice_tts_pool, nil) == 4
  end

  test "pool_max/2 reads override from pools.yaml" do
    assert Esr.Pools.pool_max(:voice_asr_pool, @fixture) == 8
    # not overridden → default
    assert Esr.Pools.pool_max(:voice_tts_pool, @fixture) == 4
  end

  test "pool_max/2 caps at Esr.PeerPool.default_max_workers" do
    # An override higher than the global 128 cap is clamped.
    path =
      Path.join(
        System.tmp_dir!(),
        "pools_huge_#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, "pools:\n  voice_asr_pool: 9999\n")
    on_exit(fn -> File.rm_rf!(path) end)

    assert Esr.Pools.pool_max(:voice_asr_pool, path) == 128
  end

  test "pool_max/2 for an unknown pool falls back to the global cap" do
    # Unknown pool + no override → global cap (128). No entry in
    # @defaults means the caller wasn't opinionated; return the max we
    # could ever spawn rather than inventing a low number.
    assert Esr.Pools.pool_max(:mystery_pool, nil) == 128
  end
end
