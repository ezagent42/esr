defmodule Esr.Plugins.Feishu.Commands.SelfUnbind do
  @moduledoc """
  Slash-only self-unbind wrapper for `/feishu:unbind`. Looks up which
  esr user currently owns the caller's `ou_xxx` and delegates to
  UnbindUser. Idempotent if the caller has no binding.

  Any args key not in `@allowed_keys` is rejected as `invalid_args`
  (mirrors SelfBind contract). The slash declares `args: []`, so
  user-supplied keys (`name=`, `target_principal_id=`) are always
  rejected; envelope-injected keys (`caller_principal_id`, `chat_id`,
  `app_id`, `thread_id`) are allowed through.

  If a concurrent admin `feishu_unbind` lands between our lookup_owner
  and UnbindUser's read, UnbindUser returns user_not_found. We catch
  and remap to idempotent {:ok, "no longer bound"} (spec § 7.2).

  Emits `[:esr, :slash, :feishu, :self_unbind]` telemetry on every
  invocation.
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.UnbindUser

  @allowed_keys ~w(caller_principal_id chat_id app_id thread_id)

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) when is_map(args) do
    result =
      case Map.keys(args) -- @allowed_keys do
        [] -> do_unbind(args)
        extras -> reject_extras(extras)
      end

    :telemetry.execute(
      [:esr, :slash, :feishu, :self_unbind],
      %{},
      %{
        caller_principal_id: Map.get(args, "caller_principal_id"),
        result: result_tag(result)
      }
    )

    result
  end

  def execute(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind requires args (envelope must inject caller_principal_id)"}}

  defp do_unbind(%{"caller_principal_id" => p}) when is_binary(p) and p != "" do
    case __MODULE__.lookup_owner(p) do
      nil ->
        {:ok, %{"text" => "#{p} is not bound to any esr user"}}

      name ->
        case UnbindUser.execute(%{"args" => %{"name" => name, "feishu_user_id" => p}}) do
          {:error, %{"type" => "user_not_found"}} ->
            {:ok, %{"text" => "#{p} is no longer bound (raced concurrent unbind)"}}

          {:error, %{"type" => "binding_not_found"}} ->
            {:ok, %{"text" => "#{p} is no longer bound (raced concurrent unbind)"}}

          other -> other
        end
    end
  end

  defp do_unbind(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind requires an envelope-injected caller_principal_id"}}

  defp reject_extras(extras), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind does not accept: #{Enum.join(extras, ", ")}"}}

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, %{"type" => t}}), do: t
  defp result_tag(_), do: :unknown

  @doc false
  # Public for :meck-driven testing of race-remap behavior.
  # Non-atomic read: lookup_owner reads users.yaml, then the delegated
  # UnbindUser.execute reads it again. Concurrent admin feishu_unbind
  # can return user_not_found from UnbindUser even though lookup_owner
  # found a name — caught and remapped above (spec § 7.2).
  def lookup_owner(fid) do
    path = Esr.Paths.users_yaml()

    case YamlElixir.read_from_file(path) do
      {:ok, %{"users" => users}} when is_map(users) ->
        Enum.find_value(users, fn {name, row} ->
          if is_map(row) and fid in (Map.get(row, "feishu_ids") || []), do: name
        end)

      _ -> nil
    end
  end
end
