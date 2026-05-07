defmodule Esr.Entity.Agent.MentionParser do
  @moduledoc """
  Parse `@<name>` mentions from inbound message text.

  ## Algorithm (spec §4 — mention parser specification, Q7=B)

  1. Scan text for the first occurrence of `@` followed by `[a-zA-Z0-9_-]+`.
     The `@` must be preceded by start-of-string, whitespace, or punctuation
     that is NOT alphanumeric or underscore (prevents `email@example.com` from
     matching).
  2. If found, check the extracted name against `agent_names` (case-sensitive).
  3. Name matched → `{:mention, name, stripped_text}` where `stripped_text` is
     the original text with the `@<name>` token removed and the result trimmed.
  4. Name NOT in list → `{:plain, text}` (route to primary agent).
  5. No `@<identifier>` pattern found → `{:plain, text}`.

  ## Boundary rule

  `@` must appear at the start of the string OR be preceded by a character that
  is not `[A-Za-z0-9_]`.  This prevents `user@domain` from being treated as a
  mention.

  ## First-match wins

  When multiple `@<name>` tokens appear, the first match that resolves to a
  known agent name wins; its token is stripped and the remainder (including any
  further `@` tokens) is returned as `rest`.

  ## Return values

    * `{:mention, agent_name, rest}` — `agent_name` is the matched name;
      `rest` is the message text with the `@<name>` token removed (trimmed).
    * `{:plain, text}` — no matched mention; route to primary agent.

  ## Examples

      iex> MentionParser.parse("@alice hello", ["alice", "bob"])
      {:mention, "alice", "hello"}

      iex> MentionParser.parse("@ lone at", ["alice"])
      {:plain, "@ lone at"}

      iex> MentionParser.parse("@unknown hi", ["alice"])
      {:plain, "@unknown hi"}

      iex> MentionParser.parse("email@example.com", ["example"])
      {:plain, "email@example.com"}
  """

  # Regex explanation:
  #   `(?:^|(?<=[^A-Za-z0-9_]))` — lookbehind: @ must be at start-of-string
  #     or preceded by a non-word char (spaces, punctuation, etc.).
  #     Erlang's PCRE engine supports variable-length lookbehinds.
  #   `@` — literal at sign
  #   `([a-zA-Z0-9][a-zA-Z0-9_-]*)` — capture group 1: name starts with
  #     alphanumeric so `@-foo` / `@_bar` are invalid.
  @mention_pattern ~r/(?:^|(?<=[^A-Za-z0-9_]))@([a-zA-Z0-9][a-zA-Z0-9_-]*)/

  @doc """
  Parse `text` for an `@<name>` mention.

  `agent_names` is the list of known agent names for the current session.
  Matching is case-sensitive and uses simple string equality (spec Q7=B).
  """
  @spec parse(String.t(), [String.t()]) ::
          {:mention, String.t(), String.t()} | {:plain, String.t()}
  def parse(text, agent_names) when is_binary(text) and is_list(agent_names) do
    # Scan returns a list of match groups. Each element is a list of
    # [{full_match_start, full_match_len}, {name_start, name_len}].
    matches = Regex.scan(@mention_pattern, text, return: :index)

    case find_first_agent_match(matches, text, agent_names) do
      {:mention, _name, _rest} = result -> result
      :no_match -> {:plain, text}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Walk all scan matches left-to-right. Return the first whose captured name
  # is in agent_names, or :no_match if none qualify.
  defp find_first_agent_match([], _text, _agent_names), do: :no_match

  defp find_first_agent_match(
         [[{full_start, full_len}, {name_start, name_len}] | rest],
         text,
         agent_names
       ) do
    name = binary_part(text, name_start, name_len)

    if name in agent_names do
      # Strip the matched `@<name>` token and surrounding whitespace.
      # Use full_start for the prefix end so we include any non-word boundary
      # char that the lookbehind consumed (e.g. a space before @).
      # After concatenation, collapse runs of whitespace that can appear when
      # the token was in the middle of the text (e.g. "hey @alice there"
      # → "hey  there" → "hey there"), then trim the outer edges.
      prefix = binary_part(text, 0, full_start)
      suffix_start = full_start + full_len
      suffix = binary_part(text, suffix_start, byte_size(text) - suffix_start)

      rest_text =
        (prefix <> suffix)
        |> String.replace(~r/  +/, " ")
        |> String.trim()

      {:mention, name, rest_text}
    else
      find_first_agent_match(rest, text, agent_names)
    end
  end

  # Fallback for unexpected match shapes (e.g. no capture group — shouldn't
  # happen with the pattern above, but be defensive).
  defp find_first_agent_match([_ | rest], text, agent_names) do
    find_first_agent_match(rest, text, agent_names)
  end
end
