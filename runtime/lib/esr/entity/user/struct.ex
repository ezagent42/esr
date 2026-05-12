defmodule Esr.Entity.User.Struct do
  @moduledoc """
  User entity struct (moved from Esr.Entity.User.Struct by PR-1).
  Stays in URI store entity rows; later refactor may rename to
  Esr.Resource.User.Struct.

  Fields:
  - username (canonical handle; mutable display)
  - feishu_ids (list of bound Feishu open_ids)
  - default_workspace_id (UUID of user's default workspace)
  """
  defstruct [:username, feishu_ids: [], default_workspace_id: nil]
end
