defmodule Esr.AnsiStrip do
  @moduledoc """
  Cheap ANSI escape stripper for `<Feishu chat>` rendering of PTY
  stdout during the boot bridge window (PR-24 step 2).

  We don't need a full terminal emulator — just enough to make
  claude's TUI output legible-ish in a chat message. xterm.js still
  owns full-fidelity rendering on `/attach`. Anything we drop here
  the operator can recover by attaching the browser.

  Sequences handled:
  - CSI `\\e[…<final>` (most cursor / colour / mode escapes)
  - OSC `\\e]…\\a` or `\\e]…\\e\\\\` (window-title, hyperlink, etc.)
  - DCS / SOS / PM / APC `\\eP…\\e\\\\` and friends
  - Single-char ESC sequences (`\\e=`, `\\eM`, `\\e7`, `\\e8`, …)
  - Bare control chars (BEL, FF, VT, …) — kept newline + tab

  Not handled (intentionally lossy): true colour rendering, cursor
  positioning, line clears (TUI redraws come out as gibberish).
  """

  # Final byte for CSI: any byte in 0x40..0x7E
  defguardp is_csi_final(b) when b >= 0x40 and b <= 0x7E

  @doc """
  Strip ANSI escapes from a binary, returning a printable text run
  suitable for pushing into a Feishu chat message.
  """
  @spec strip(binary()) :: binary()
  def strip(bin) when is_binary(bin) do
    bin |> do_strip([]) |> IO.iodata_to_binary()
  end

  # CSI: ESC [ … <final 0x40-0x7E>. Replace with a single space so
  # cursor-positioning escapes (which claude uses to lay out words on
  # a row) don't squish adjacent words together when stripped — the
  # operator reads "Loading development channels" rather than
  # "Loadingdevelopmentchannels".
  defp do_strip(<<0x1B, ?[, rest::binary>>, acc) do
    rest |> drop_until_csi_final() |> do_strip([acc | " "])
  end

  # OSC: ESC ] … (BEL | ESC \)
  defp do_strip(<<0x1B, ?], rest::binary>>, acc) do
    rest |> drop_until_st_or_bel() |> do_strip(acc)
  end

  # DCS / SOS / PM / APC: ESC P / ESC X / ESC ^ / ESC _ … ESC \
  defp do_strip(<<0x1B, intro, rest::binary>>, acc) when intro in [?P, ?X, ?^, ?_] do
    rest |> drop_until_st() |> do_strip(acc)
  end

  # Two-byte ESC sequences (ESC + intermediate + final). Cheap and
  # imprecise: just eat the next byte after ESC.
  defp do_strip(<<0x1B, _next, rest::binary>>, acc), do: do_strip(rest, acc)

  # Bare control chars to drop (keep \n and \t for legibility).
  defp do_strip(<<c, rest::binary>>, acc) when c in [0x00..0x08, 0x0B..0x0C, 0x0E..0x1F] do
    do_strip(rest, acc)
  end

  defp do_strip(<<0x7F, rest::binary>>, acc), do: do_strip(rest, acc)

  defp do_strip(<<c, rest::binary>>, acc), do: do_strip(rest, [acc | <<c>>])

  defp do_strip(<<>>, acc), do: acc

  defp drop_until_csi_final(<<b, rest::binary>>) when is_csi_final(b), do: rest
  defp drop_until_csi_final(<<_b, rest::binary>>), do: drop_until_csi_final(rest)
  defp drop_until_csi_final(<<>>), do: <<>>

  defp drop_until_st_or_bel(<<0x07, rest::binary>>), do: rest
  defp drop_until_st_or_bel(<<0x1B, ?\\, rest::binary>>), do: rest
  defp drop_until_st_or_bel(<<_b, rest::binary>>), do: drop_until_st_or_bel(rest)
  defp drop_until_st_or_bel(<<>>), do: <<>>

  defp drop_until_st(<<0x1B, ?\\, rest::binary>>), do: rest
  defp drop_until_st(<<_b, rest::binary>>), do: drop_until_st(rest)
  defp drop_until_st(<<>>), do: <<>>
end
