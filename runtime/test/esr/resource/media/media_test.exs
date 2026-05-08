defmodule Esr.Resource.MediaTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Media

  setup do
    tmp = Path.join(System.tmp_dir!(), "esr_media_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    saved_home = System.get_env("ESRD_HOME")
    saved_inst = System.get_env("ESR_INSTANCE")
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "test")

    on_exit(fn ->
      File.rm_rf!(tmp)
      if saved_home, do: System.put_env("ESRD_HOME", saved_home), else: System.delete_env("ESRD_HOME")
      if saved_inst, do: System.put_env("ESR_INSTANCE", saved_inst), else: System.delete_env("ESR_INSTANCE")
    end)

    {:ok, tmp: tmp}
  end

  test "store/3 writes content-addressed file + appends refs.jsonl", %{tmp: tmp} do
    src = Path.join(tmp, "input.png")
    File.write!(src, "fake png bytes")
    expected_sha = :crypto.hash(:sha256, "fake png bytes") |> Base.encode16(case: :lower)

    {:ok, %{uri: uri, sha256: sha, path: stored_path}} =
      Media.store(:image, src, %{adapter: "test", chat_id: "oc_xx"})

    assert sha == expected_sha
    assert File.exists?(stored_path)
    assert stored_path =~ "/test/resources/image/#{sha}.png"
    assert uri =~ "esr://test@"
    assert uri =~ "/resources/image/#{sha}.png"

    refs_path = String.replace(stored_path, ".png", ".refs.jsonl")
    assert File.exists?(refs_path)
    refs = File.read!(refs_path) |> String.split("\n", trim: true)
    assert length(refs) == 1
    decoded = refs |> hd() |> Jason.decode!()
    assert decoded["adapter"] == "test"
    assert decoded["chat_id"] == "oc_xx"
    assert is_binary(decoded["received_at"])
  end

  test "store/3 second call with same bytes appends a ref but does not duplicate file", %{tmp: tmp} do
    src1 = Path.join(tmp, "a.png")
    src2 = Path.join(tmp, "b.png")
    File.write!(src1, "same content")
    File.write!(src2, "same content")

    {:ok, %{sha256: sha1, path: p1}} = Media.store(:image, src1, %{adapter: "a", chat_id: "c1"})
    {:ok, %{sha256: sha2, path: p2}} = Media.store(:image, src2, %{adapter: "b", chat_id: "c2"})

    assert sha1 == sha2
    assert p1 == p2  # content-addressed → same destination

    refs_path = String.replace(p2, ".png", ".refs.jsonl")
    refs = File.read!(refs_path) |> String.split("\n", trim: true)
    assert length(refs) == 2
  end

  test "store/3 returns bin extension for source without ext", %{tmp: tmp} do
    src = Path.join(tmp, "no_ext_file")
    File.write!(src, "blob")
    {:ok, %{path: stored_path}} = Media.store(:file, src, %{})
    assert String.ends_with?(stored_path, ".bin")
  end

  test "resolve/1 returns Path for a stored URI", %{tmp: _tmp} do
    src = Path.join(System.tmp_dir!(), "x_#{System.unique_integer([:positive])}.png")
    File.write!(src, "data")
    on_exit(fn -> File.rm(src) end)

    {:ok, %{uri: uri, path: p}} = Media.store(:image, src, %{})
    assert {:ok, ^p} = Media.resolve(uri)
  end

  test "resolve/1 returns :not_found for nonexistent sha256" do
    bogus = "esr://test@localhost:4001/resources/image/" <> String.duplicate("0", 64) <> ".png"
    assert {:error, :not_found} = Media.resolve(bogus)
  end

  test "resolve/1 returns :wrong_env for mismatched env" do
    bad = "esr://other@localhost:4001/resources/image/" <> String.duplicate("a", 64) <> ".png"
    assert {:error, :wrong_env} = Media.resolve(bad)
  end

  test "resolve/1 absent <env>@ defaults to local env (implicit)", %{tmp: _tmp} do
    src = Path.join(System.tmp_dir!(), "y_#{System.unique_integer([:positive])}.png")
    File.write!(src, "y")
    on_exit(fn -> File.rm(src) end)

    {:ok, %{sha256: sha}} = Media.store(:image, src, %{})
    no_env_uri = "esr://localhost:4001/resources/image/#{sha}.png"
    assert {:ok, _path} = Media.resolve(no_env_uri)
  end

  test "resolve/1 returns :invalid_uri for malformed URI" do
    assert {:error, :invalid_uri} = Media.resolve("not-a-uri")
    assert {:error, :invalid_uri} = Media.resolve("esr://test@localhost/sessions/abc")
  end
end
