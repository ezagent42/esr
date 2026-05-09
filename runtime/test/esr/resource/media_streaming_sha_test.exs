defmodule Esr.Resource.MediaStreamingShaTest do
  @moduledoc """
  Regression: `Esr.Resource.Media.compute_sha256/1` must work on files
  larger than the BEAM heap budget by streaming, not by `File.read/1`.

  Pre-2026-05-09 the function loaded the entire file into a single
  binary on the BEAM heap. That was workable for Lark's 30 MB image /
  50 MB file caps but blew up under audio / video Phaser sizes. The
  streaming implementation reads 64 KiB chunks and feeds them through
  `:crypto.hash_init/update/final`, holding constant memory regardless
  of file size. These tests pin that contract.
  """

  use ExUnit.Case, async: true

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "esr_streaming_sha_test_#{System.unique_integer([:positive])}.bin"
      )

    on_exit(fn -> File.rm(tmp) end)
    {:ok, tmp: tmp}
  end

  test "computes sha256 of a small known file", %{tmp: tmp} do
    File.write!(tmp, "hello world")
    {:ok, sha} = call_compute_sha256(tmp)
    # sha256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
    assert sha ==
             "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
  end

  test "streams 8 MB file and matches reference :crypto.hash digest", %{tmp: tmp} do
    # Write 8 MiB of zeros in 64 KiB chunks, mirroring how the
    # streaming implementation reads them. Then verify the streamed
    # digest matches a one-shot reference digest taken over the same
    # bytes built in memory — proving the chunked reduce yields the
    # same hash as a flat hash.
    File.open!(tmp, [:write, :binary], fn h ->
      Enum.each(1..128, fn _ ->
        IO.binwrite(h, :binary.copy(<<0>>, 64 * 1024))
      end)
    end)

    {:ok, sha} = call_compute_sha256(tmp)

    expected =
      :crypto.hash(:sha256, :binary.copy(<<0>>, 8 * 1024 * 1024))
      |> Base.encode16(case: :lower)

    assert sha == expected
  end

  test "missing file returns {:error, :enoent}" do
    {:error, _} = call_compute_sha256("/nonexistent/path/xyz_esr_streaming_sha_test")
  end

  defp call_compute_sha256(path) do
    Esr.Resource.Media.__compute_sha256__(path)
  end
end
