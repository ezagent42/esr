defmodule Esr.Resource.Media.PhaserRegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Media
  alias Esr.Resource.Media.PhaserRegistry

  setup do
    tmp = Path.join(System.tmp_dir!(), "preg_#{System.unique_integer([:positive])}")
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

  test "transform/2 routes image URI to ImagePhaser", %{tmp: tmp} do
    src = Path.join(tmp, "x.png")
    File.write!(src, "fake png")
    {:ok, %{uri: uri}} = Media.store(:image, src, %{})

    assert {:ok, path_out} = PhaserRegistry.transform(uri, :path)
    assert is_binary(path_out)
    assert String.ends_with?(path_out, ".png")
  end

  test "transform/2 routes image URI to bytes target", %{tmp: tmp} do
    src = Path.join(tmp, "y.png")
    File.write!(src, "byteslike")
    {:ok, %{uri: uri}} = Media.store(:image, src, %{})

    assert {:ok, "byteslike"} = PhaserRegistry.transform(uri, :bytes)
  end

  test "transform/2 routes file URI to FilePhaser inline_text", %{tmp: tmp} do
    src = Path.join(tmp, "small.txt")
    File.write!(src, "hello")
    {:ok, %{uri: uri}} = Media.store(:file, src, %{})

    assert {:ok, "hello"} = PhaserRegistry.transform(uri, :inline_text)
  end

  test "transform/2 returns :not_found for missing sha256" do
    bogus = "esr://test@localhost:4001/resources/image/" <> String.duplicate("0", 64) <> ".png"
    assert {:error, :not_found} = PhaserRegistry.transform(bogus, :path)
  end

  test "transform/2 returns :invalid_uri for bad URI" do
    assert {:error, :invalid_uri} = PhaserRegistry.transform("not-a-uri", :path)
  end

  test "transform/2 returns :wrong_env for mismatched env" do
    bad = "esr://other@localhost:4001/resources/image/" <> String.duplicate("a", 64) <> ".png"
    assert {:error, :wrong_env} = PhaserRegistry.transform(bad, :path)
  end

  test "transform/2 returns :no_phaser_for_media_type for audio (no phaser registered yet)", %{tmp: tmp} do
    # Place a real file at the expected content-addressed path so that
    # Media.resolve/1 succeeds, letting the dispatch reach the phaser
    # lookup — where :audio has no registered Phaser.
    sha = String.duplicate("c", 64)
    audio_dir = Path.join([tmp, "test", "resources", "audio"])
    File.mkdir_p!(audio_dir)
    File.write!(Path.join(audio_dir, "#{sha}.opus"), "fake audio")

    audio_uri = "esr://test@localhost:4001/resources/audio/#{sha}.opus"

    assert {:error, :no_phaser_for_media_type} = PhaserRegistry.transform(audio_uri, :path)
  end
end
