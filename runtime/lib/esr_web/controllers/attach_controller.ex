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
          /* Verbatim copy of ttyd's flow-based layout
             (html/src/style/index.scss). Don't deviate — every
             previous variant (`position: fixed; inset: 0`,
             `width: 100% !important` overrides on xterm internals)
             produced the wrong rendered width. xterm.js's bundled
             CSS already positions `.xterm-viewport` absolute
             top:0/right:0/bottom:0/left:0; ttyd just gives it a
             flow-sized parent and lets xterm do its thing. */
          html, body {
            height: 100%;
            width: 100%;
            min-height: 100%;
            margin: 0;
            overflow: hidden;
            background: #1e1e1e;
            color: #d4d4d4;
            font-family: Consolas, "Liberation Mono", Menlo, Courier, monospace;
          }
          /* Explicit viewport-relative size on the term container
             (vs ttyd's `width: auto` which depends on body cascading
             100% from html). Avoids any block-width-lazy-resolution
             where the container measures at less-than-viewport at the
             moment xterm.js's `term.open` runs. */
          #term {
            width: 100vw;
            height: 100vh;
            padding: 0;
            margin: 0;
            box-sizing: border-box;
          }
          #term .xterm,
          #term .terminal {
            height: 100%;
            padding: 5px;
            box-sizing: border-box;
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
