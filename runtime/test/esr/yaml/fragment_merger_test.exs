defmodule Esr.Yaml.FragmentMergerTest do
  @moduledoc """
  Tests for `Esr.Yaml.FragmentMerger`.

  Spec: `docs/superpowers/specs/2026-05-04-core-decoupling-design.md` §三.

  Domain semantics tested here are **agents.yaml** style (top-level
  dictionary keyed by `<name>`):
    - plugin fragments add new keys
    - duplicate key across fragments is a hard fail
    - user override wins per-key (last layer)
  """
  use ExUnit.Case, async: true

  alias Esr.Yaml.FragmentMerger

  @tmp_dir Path.join(System.tmp_dir!(), "esr_fragment_merger_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write!(name, content) do
    path = Path.join(@tmp_dir, name)
    File.write!(path, content)
    path
  end

  describe "merge_keyed/2" do
    test "no fragments and no override → empty map" do
      assert {:ok, %{}} == FragmentMerger.merge_keyed([], nil)
    end

    test "single fragment is loaded as-is" do
      a =
        write!("a.yaml", """
        agents:
          alpha:
            description: A
        """)

      assert {:ok, %{"alpha" => %{"description" => "A"}}} ==
               FragmentMerger.merge_keyed([{a, "agents"}], nil)
    end

    test "two fragments with disjoint keys merge cleanly" do
      a = write!("a.yaml", "agents:\n  alpha:\n    description: A\n")
      b = write!("b.yaml", "agents:\n  beta:\n    description: B\n")

      {:ok, merged} = FragmentMerger.merge_keyed([{a, "agents"}, {b, "agents"}], nil)

      assert merged == %{
               "alpha" => %{"description" => "A"},
               "beta" => %{"description" => "B"}
             }
    end

    test "duplicate key across two fragments fails boot" do
      a = write!("a.yaml", "agents:\n  alpha:\n    description: A\n")
      b = write!("b.yaml", "agents:\n  alpha:\n    description: collision\n")

      assert {:error, {:duplicate_key, "alpha", _, _}} =
               FragmentMerger.merge_keyed([{a, "agents"}, {b, "agents"}], nil)
    end

    test "user override wins per-key over fragments" do
      a = write!("a.yaml", "agents:\n  alpha:\n    description: A\n")
      b = write!("b.yaml", "agents:\n  beta:\n    description: B\n")

      override =
        write!("user.yaml", """
        agents:
          alpha:
            description: overridden
        """)

      {:ok, merged} =
        FragmentMerger.merge_keyed([{a, "agents"}, {b, "agents"}], {override, "agents"})

      assert merged == %{
               "alpha" => %{"description" => "overridden"},
               "beta" => %{"description" => "B"}
             }
    end

    test "user override may add a brand-new key" do
      a = write!("a.yaml", "agents:\n  alpha:\n    description: A\n")

      override =
        write!("user.yaml", """
        agents:
          gamma:
            description: G
        """)

      {:ok, merged} = FragmentMerger.merge_keyed([{a, "agents"}], {override, "agents"})

      assert merged == %{
               "alpha" => %{"description" => "A"},
               "gamma" => %{"description" => "G"}
             }
    end

    test "missing fragment file is ignored (skipped)" do
      missing = Path.join(@tmp_dir, "ghost.yaml")
      a = write!("a.yaml", "agents:\n  alpha:\n    description: A\n")

      {:ok, merged} = FragmentMerger.merge_keyed([{missing, "agents"}, {a, "agents"}], nil)

      assert merged == %{"alpha" => %{"description" => "A"}}
    end

    test "missing user override is fine (no override applied)" do
      a = write!("a.yaml", "agents:\n  alpha:\n    description: A\n")
      missing_override = {Path.join(@tmp_dir, "ghost.user.yaml"), "agents"}

      {:ok, merged} = FragmentMerger.merge_keyed([{a, "agents"}], missing_override)

      assert merged == %{"alpha" => %{"description" => "A"}}
    end

    test "absent top-level key in fragment is treated as empty" do
      a = write!("a.yaml", "# nothing here\n")
      b = write!("b.yaml", "agents:\n  beta:\n    description: B\n")

      {:ok, merged} = FragmentMerger.merge_keyed([{a, "agents"}, {b, "agents"}], nil)

      assert merged == %{"beta" => %{"description" => "B"}}
    end

    test "malformed yaml in fragment surfaces as :error" do
      # Unbalanced/corrupt YAML — YamlElixir refuses this rather than
      # round-tripping it.
      bad = write!("bad.yaml", "agents:\n  alpha:\n    description: \"unterminated\n")

      assert {:error, {:parse_failed, _path, _reason}} =
               FragmentMerger.merge_keyed([{bad, "agents"}], nil)
    end

    test "non-map fragment under the top-level key fails fast" do
      bad = write!("list.yaml", "agents:\n  - alpha\n  - beta\n")

      assert {:error, {:not_a_map, _path, "agents"}} =
               FragmentMerger.merge_keyed([{bad, "agents"}], nil)
    end
  end
end
