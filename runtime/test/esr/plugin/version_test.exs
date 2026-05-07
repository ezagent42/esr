defmodule Esr.Plugin.VersionTest do
  use ExUnit.Case, async: true

  alias Esr.Plugin.Version, as: V

  describe "satisfies?/2" do
    test ">= constraint passes when version is equal" do
      assert V.satisfies?(">= 0.1.0", "0.1.0") == true
    end

    test ">= constraint passes when version is higher" do
      assert V.satisfies?(">= 0.1.0", "0.2.0") == true
    end

    test ">= constraint fails when version is lower" do
      assert V.satisfies?(">= 0.2.0", "0.1.0") == false
    end

    test "~> pessimistic constraint passes patch bump" do
      assert V.satisfies?("~> 0.1.0", "0.1.5") == true
    end

    test "~> pessimistic constraint fails minor bump" do
      assert V.satisfies?("~> 0.1.0", "0.2.0") == false
    end

    test "exact == constraint passes on exact match" do
      assert V.satisfies?("== 0.1.0", "0.1.0") == true
    end

    test "exact == constraint fails on mismatch" do
      assert V.satisfies?("== 0.1.0", "0.2.0") == false
    end

    test "invalid constraint string returns {:error, :invalid_constraint}" do
      assert {:error, :invalid_constraint} = V.satisfies?("not_a_constraint", "0.1.0")
    end

    test "invalid version string returns {:error, :invalid_constraint}" do
      assert {:error, :invalid_constraint} = V.satisfies?(">= 0.1.0", "not_a_version")
    end

    test ">= 0.1.0 passes 0.1.0 (exact boundary)" do
      assert V.satisfies?(">= 0.1.0", "0.1.0") == true
    end

    test ">= 99.0.0 fails on current esrd version" do
      vsn = V.esrd_version()
      assert V.satisfies?(">= 99.0.0", vsn) == false
    end
  end

  describe "esrd_version/0" do
    test "returns a valid SemVer string" do
      vsn = V.esrd_version()
      assert is_binary(vsn)
      assert {:ok, _} = Version.parse(vsn)
    end
  end
end
