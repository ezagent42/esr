defmodule Esr.Resource.ChatScope.FileLoader do
  @moduledoc """
  Persist and load the `(chat_id, app_id)` → attached-set mapping.

  File: `$ESRD_HOME/<inst>/chat_attached.yaml`
  Format:
    chat_attached:
      - chat_id: "oc_xxx"
        app_id: "cli_yyy"
        sessions: ["uuid1", "uuid2"]
        current: "uuid1"

  Atomic write: tmp → rename. Read is non-destructive.
  Uses `YamlElixir` for reading and `Esr.Yaml.Writer` for writing.
  """

  @spec load(String.t()) :: {:ok, [map()]} | {:error, term()}
  def load(path) do
    if File.exists?(path) do
      with {:ok, yaml} <- YamlElixir.read_from_file(path) do
        entries =
          (yaml["chat_attached"] || [])
          |> Enum.flat_map(fn e ->
            chat_id = e["chat_id"]
            app_id = e["app_id"]

            if is_binary(chat_id) and is_binary(app_id) do
              sessions = (e["sessions"] || []) |> Enum.filter(&is_binary/1)
              current = if is_binary(e["current"]), do: e["current"], else: nil

              [%{chat_id: chat_id, app_id: app_id, sessions: sessions, current: current}]
            else
              []
            end
          end)

        {:ok, entries}
      end
    else
      {:ok, []}
    end
  end

  @spec write(String.t(), [map()]) :: :ok | {:error, term()}
  def write(path, entries) do
    serialised =
      Enum.map(entries, fn e ->
        %{
          "chat_id" => e.chat_id,
          "app_id" => e.app_id,
          "sessions" => e.sessions,
          "current" => e.current
        }
      end)

    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, text} <- encode(%{"chat_attached" => serialised}),
         :ok <- File.write(tmp, text),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  # Minimal YAML encoder that delegates to Esr.Yaml.Writer's internal encode.
  # We call write/2 on a temp path and read back the text to avoid duplicating
  # the scalar-quoting logic. Instead, use the Writer.write/2 directly.
  defp encode(data) do
    tmp = Path.join(System.tmp_dir!(), "cs_fl_#{:rand.uniform(999_999_999)}.yaml")

    case Esr.Yaml.Writer.write(tmp, data) do
      :ok ->
        result = File.read(tmp)
        File.rm(tmp)
        result

      {:error, _} = err ->
        err
    end
  end
end
