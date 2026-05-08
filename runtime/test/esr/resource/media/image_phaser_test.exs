defmodule Esr.Resource.Media.ImagePhaserTest do
  use ExUnit.Case
  alias Esr.Resource.Media.ImagePhaser

  setup do
    tmp = Path.join(System.tmp_dir!(), "img_#{System.unique_integer([:positive])}.png")
    File.write!(tmp, <<137, 80, 78, 71, 13, 10, 26, 10>> <> "fake")  # PNG magic + payload
    on_exit(fn -> File.rm(tmp) end)
    {:ok, path: tmp}
  end

  test "media_type/0 == :image" do
    assert ImagePhaser.media_type() == :image
  end

  test "input_formats / output_formats / streaming?" do
    assert ImagePhaser.input_formats() == [:path]
    assert :path in ImagePhaser.output_formats()
    assert :base64_data_url in ImagePhaser.output_formats()
    assert :bytes in ImagePhaser.output_formats()
    assert ImagePhaser.streaming?() == false
  end

  test "transform :path is identity", %{path: p} do
    assert {:ok, ^p} = ImagePhaser.transform({:path, p}, :path)
  end

  test "transform :bytes returns file content", %{path: p} do
    {:ok, bytes} = ImagePhaser.transform({:path, p}, :bytes)
    assert is_binary(bytes)
    assert byte_size(bytes) > 0
  end

  test "transform :base64_data_url returns data: URI with PNG mime", %{path: p} do
    {:ok, data_url} = ImagePhaser.transform({:path, p}, :base64_data_url)
    assert String.starts_with?(data_url, "data:image/png;base64,")
  end

  test "transform :base64_data_url uses ext-derived mime for jpg" do
    tmp = Path.join(System.tmp_dir!(), "img_#{System.unique_integer([:positive])}.jpg")
    File.write!(tmp, "fake jpg")
    on_exit(fn -> File.rm(tmp) end)
    {:ok, data_url} = ImagePhaser.transform({:path, tmp}, :base64_data_url)
    assert String.starts_with?(data_url, "data:image/jpeg;base64,")
  end

  test "transform unsupported target returns error" do
    assert {:error, {:unsupported_target, :nonsense}} =
             ImagePhaser.transform({:path, "/tmp/x"}, :nonsense)
  end
end
