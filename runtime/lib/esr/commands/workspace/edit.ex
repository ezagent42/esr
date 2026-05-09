defmodule Esr.Commands.Workspace.Edit do
  @moduledoc """
  `/workspace edit` slash — mutate one field of an existing workspace.

  ## Args

      args: %{
        "name" => "esr-dev",            # required
        "set"  => "agent=claude"        # required; key=value
      }

  ## Result

      {:ok, %{"name" => name, "id" => uuid, "field" => key, "value" => parsed}}
      {:error, %{"type" => ..., ...}}

  ## set= parsing

  Split on first `=` to get `{key, value}`.

  Split `key` on first `.` to get `{top, rest?}`:

    * `agent`        → replace `ws.agent` (string, no dotted suffix allowed)
    * `env.<NAME>`   → `ws.env[NAME] = value` (NAME must not contain dots)
    * `settings.<k>` → `ws.settings[k] = value` (k is flat dot-string, preserved verbatim)
    * `transient`    → boolean only; rejected on repo-bound workspaces
    * locked fields  → `id`, `name`, `chats`, `folders`, `location`

  Value parsing (in order):
    * `"true"` → `true`
    * `"false"` → `false`
    * matches `^-?\\d+$` → integer
    * contains `,` and no `=` → CSV list (trimmed strings)
    * otherwise → string verbatim
  """

  use Esr.Commands.Meta

  command :workspace_edit do
    slash         "/workspace:edit"
    category      "Workspace"
    description   "改 workspace.json 单个字段；set=<key>=<value>（settings 用扁平 dot-key；env.<NAME>=...；chats/folders 用专门 slash）"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name, required: true,  doc: "workspace 名（必填）"
    arg :set,  required: true,  doc: "key=value 字符串"

    error :invalid_args,                "workspace_edit requires args.name (string) and args.set (key=value string)"
    error :invalid_set,                 "set must be key=value"
    error :field_locked,                "%{field} is locked; use the dedicated command to change it"
    error :invalid_field,               "invalid field %{field}: %{detail}"
    error :invalid_env_key,             "%{detail}"
    error :unknown_field,               "unknown field %{field}"
    error :invalid_value,               "invalid value for %{field}: %{detail}"
    error :unknown_workspace,           "workspace %{name} not found"
    error :transient_repo_bound_forbidden, "transient: true is not valid for repo-bound workspaces"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.{Struct, Registry, NameIndex}

  @locked_fields ~w(id name chats folders location)

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name, "set" => set}})
      when is_binary(name) and name != "" and is_binary(set) and set != "" do
    with {:ok, {key, raw_value}} <- parse_set_string(set),
         {:ok, top, sub} <- parse_key(key),
         {:ok, parsed_value} <- parse_value(raw_value),
         :ok <- validate_field_value(top, parsed_value),
         {:ok, ws} <- lookup_struct_by_name(name),
         :ok <- check_transient_repo_bound(top, parsed_value, ws),
         {:ok, updated} <- apply_mutation(ws, top, sub, parsed_value),
         :ok <- Registry.put(updated) do
      field_label = field_label(top, sub)

      {:ok,
       %{
         "name" => name,
         "id" => updated.id,
         "field" => field_label,
         "value" => parsed_value
       }}
    end
  end

  def execute(_) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  ## Internals ---------------------------------------------------------------

  # Step 1: Split set string on first "="
  defp parse_set_string(set) do
    case String.split(set, "=", parts: 2) do
      [_key, _value] = parts ->
        [key, value] = parts
        {:ok, {key, value}}

      [_no_equals] ->
        Render.error(__MODULE__.command_meta(), :invalid_set)
    end
  end

  # Step 2: Determine top-level field and sub-key (if any)
  defp parse_key(key) do
    case String.split(key, ".", parts: 2) do
      [top] ->
        check_locked_or_known(top, nil)

      [top, rest] ->
        check_locked_or_known(top, rest)
    end
  end

  defp check_locked_or_known(top, _rest) when top in @locked_fields do
    Render.error(__MODULE__.command_meta(), :field_locked, %{field: top})
  end

  defp check_locked_or_known("agent", nil), do: {:ok, "agent", nil}

  defp check_locked_or_known("agent", _rest) do
    Render.error(__MODULE__.command_meta(), :invalid_field, %{
      field: "agent",
      detail: "agent does not accept dotted suffix"
    })
  end

  defp check_locked_or_known("env", nil) do
    Render.error(__MODULE__.command_meta(), :invalid_env_key, %{
      detail: "env requires env.<NAME>=<value>"
    })
  end

  defp check_locked_or_known("env", rest) do
    if String.contains?(rest, ".") do
      Render.error(__MODULE__.command_meta(), :invalid_env_key, %{
        detail: "env keys cannot contain dots"
      })
    else
      {:ok, "env", rest}
    end
  end

  defp check_locked_or_known("settings", nil) do
    Render.error(__MODULE__.command_meta(), :invalid_field, %{
      field: "settings",
      detail: "settings requires settings.<key>=<value>"
    })
  end

  defp check_locked_or_known("settings", rest), do: {:ok, "settings", rest}

  defp check_locked_or_known("transient", nil), do: {:ok, "transient", nil}

  defp check_locked_or_known("transient", _rest) do
    Render.error(__MODULE__.command_meta(), :invalid_field, %{
      field: "transient",
      detail: "transient does not accept dotted suffix"
    })
  end

  defp check_locked_or_known(top, _rest) do
    Render.error(__MODULE__.command_meta(), :unknown_field, %{field: top})
  end

  # Step 4: Parse the raw string value
  defp parse_value("true"), do: {:ok, true}
  defp parse_value("false"), do: {:ok, false}

  defp parse_value(raw) do
    cond do
      Regex.match?(~r/^-?\d+$/, raw) ->
        {:ok, String.to_integer(raw)}

      String.contains?(raw, ",") and not String.contains?(raw, "=") ->
        list =
          raw
          |> String.split(",")
          |> Enum.map(&String.trim/1)

        {:ok, list}

      true ->
        {:ok, raw}
    end
  end

  # Step 4 (continued): Validate field-specific value constraints
  defp validate_field_value("transient", value) when not is_boolean(value) do
    Render.error(__MODULE__.command_meta(), :invalid_value, %{
      field: "transient",
      detail: "transient must be true or false"
    })
  end

  defp validate_field_value("agent", value) when not (is_binary(value) and value != "") do
    Render.error(__MODULE__.command_meta(), :invalid_value, %{
      field: "agent",
      detail: "agent must be a non-empty string"
    })
  end

  defp validate_field_value(_field, _value), do: :ok

  # Check: transient=true forbidden on repo-bound workspaces
  defp check_transient_repo_bound("transient", true, %Struct{location: {:repo_bound, _}}) do
    Render.error(__MODULE__.command_meta(), :transient_repo_bound_forbidden)
  end

  defp check_transient_repo_bound(_top, _value, _ws), do: :ok

  # Workspace lookup
  defp lookup_struct_by_name(name) do
    case NameIndex.id_for_name(:esr_workspace_name_index, name) do
      {:ok, id} ->
        case Registry.get_by_id(id) do
          {:ok, ws} -> {:ok, ws}
          :not_found -> workspace_not_found(name)
        end

      :not_found ->
        workspace_not_found(name)
    end
  end

  defp workspace_not_found(name) do
    Render.error(__MODULE__.command_meta(), :unknown_workspace, %{name: name})
  end

  # Step 5: Apply the mutation to the workspace struct
  defp apply_mutation(%Struct{} = ws, "agent", nil, value) do
    {:ok, %{ws | agent: value}}
  end

  defp apply_mutation(%Struct{} = ws, "env", env_key, value) do
    {:ok, %{ws | env: Map.put(ws.env, env_key, value)}}
  end

  defp apply_mutation(%Struct{} = ws, "settings", settings_key, value) do
    {:ok, %{ws | settings: Map.put(ws.settings, settings_key, value)}}
  end

  defp apply_mutation(%Struct{} = ws, "transient", nil, value) do
    {:ok, %{ws | transient: value}}
  end

  # Build a human-readable field label for the result
  defp field_label("env", key), do: "env.#{key}"
  defp field_label("settings", key), do: "settings.#{key}"
  defp field_label(top, nil), do: top
  defp field_label(top, key), do: "#{top}.#{key}"
end
