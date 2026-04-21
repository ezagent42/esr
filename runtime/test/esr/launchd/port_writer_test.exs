defmodule Esr.Launchd.PortWriterTest do
  use ExUnit.Case, async: false
  alias Esr.Launchd.PortWriter

  setup do
    tmp = Path.join(System.tmp_dir!(), "esrd_port_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "default"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, esrd_home: tmp}
  end

  test "writes actually-bound port to esrd.port on start", %{esrd_home: home} do
    {:ok, _pid} = PortWriter.start_link(esrd_home: home, instance: "default", port: 45678)
    Process.sleep(100)
    assert File.read!(Path.join([home, "default", "esrd.port"])) |> String.trim() == "45678"
  end
end
