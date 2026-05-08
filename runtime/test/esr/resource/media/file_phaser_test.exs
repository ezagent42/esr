defmodule Esr.Resource.Media.FilePhaserTest do
  use ExUnit.Case
  alias Esr.Resource.Media.FilePhaser

  test "media_type/0 == :file" do
    assert FilePhaser.media_type() == :file
  end

  test "input_formats / output_formats / streaming?" do
    assert FilePhaser.input_formats() == [:path]
    assert :path in FilePhaser.output_formats()
    assert :bytes in FilePhaser.output_formats()
    assert :inline_text in FilePhaser.output_formats()
    assert FilePhaser.streaming?() == false
  end

  test "transform :path is identity" do
    assert {:ok, "/tmp/x"} = FilePhaser.transform({:path, "/tmp/x"}, :path)
  end

  test "transform :bytes returns file content" do
    tmp = Path.join(System.tmp_dir!(), "blob_#{System.unique_integer([:positive])}.bin")
    File.write!(tmp, <<1, 2, 3, 4>>)
    on_exit(fn -> File.rm(tmp) end)
    assert {:ok, <<1, 2, 3, 4>>} = FilePhaser.transform({:path, tmp}, :bytes)
  end

  test "transform :inline_text returns content for small text file" do
    tmp = Path.join(System.tmp_dir!(), "small_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "hello world")
    on_exit(fn -> File.rm(tmp) end)
    assert {:ok, "hello world"} = FilePhaser.transform({:path, tmp}, :inline_text)
  end

  test "transform :inline_text errors for >100KB file" do
    tmp = Path.join(System.tmp_dir!(), "big_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, String.duplicate("x", 200_000))
    on_exit(fn -> File.rm(tmp) end)
    assert {:error, :too_large_for_inline} = FilePhaser.transform({:path, tmp}, :inline_text)
  end

  test "transform unsupported target returns error" do
    assert {:error, {:unsupported_target, :base64_data_url}} =
             FilePhaser.transform({:path, "/tmp/x"}, :base64_data_url)
  end
end
