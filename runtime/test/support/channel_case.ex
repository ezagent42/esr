defmodule EsrWeb.ChannelCase do
  @moduledoc """
  Test case template for Phoenix.Channel tests (PRD 01 F09+).

  Tests using this case get `Phoenix.ChannelTest` helpers imported
  and the `@endpoint` attribute bound to `EsrWeb.Endpoint`. Channels
  run against the live application-started supervision tree, so any
  AdapterHub.Registry / PeerRegistry bindings set up in tests are
  visible to channel callbacks (they share ETS + Registry state).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for channel tests
      @endpoint EsrWeb.Endpoint

      import Phoenix.ChannelTest
      import EsrWeb.ChannelCase
    end
  end
end
