defmodule EsrWeb.AttachController do
  @moduledoc """
  PR-23: serves the static HTML page for `/sessions/:sid/attach`.

  Replaces PR-22's `EsrWeb.AttachLive`. The page is intentionally
  minimal: pulls the xterm.js bundle, embeds the sid, opens a
  Phoenix.Channel WebSocket to `attach:<sid>`. No LiveView, no DOM
  diffing — just an xterm container plus a script tag.
  """

  use Phoenix.Controller, formats: [:html]

  def show(conn, %{"sid" => sid}) do
    html(conn, page_html(sid))
  end

  defp page_html(sid) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>ESR · attach #{sid}</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: #1e1e1e;
            color: #d4d4d4;
            font-family: 'SF Mono', Menlo, Monaco, monospace;
            height: 100vh;
            overflow: hidden;
          }
          #term {
            position: fixed;
            inset: 0;
            padding: 4px;
          }
          #ended-banner {
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            padding: 6px 10px;
            background: #332200;
            color: #ffaa33;
            font-size: 12px;
            display: none;
            z-index: 10;
          }
        </style>
      </head>
      <body>
        <div id="ended-banner">[session ended — link no longer attached to a live PTY]</div>
        <div id="term"></div>
        <script>window.ESR_SID = "#{escape_js(sid)}";</script>
        <script src="/assets/app.js" defer></script>
      </body>
    </html>
    """
  end

  defp escape_js(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("<", "\\u003c")
  end
end
