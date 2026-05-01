defmodule EsrWeb.Layouts do
  @moduledoc """
  PR-22: minimal LiveView layout shell for /sessions/:sid/attach.

  Only one template — `root.html.heex` — embeds the xterm.js bundle and
  hosts the LiveView root. No nav / chrome / branding; the entire viewport
  is the terminal.
  """

  use EsrWeb, :html
  embed_templates "layouts/*"
end
