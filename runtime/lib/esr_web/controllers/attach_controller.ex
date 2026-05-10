defmodule EsrWeb.AttachController do
  @moduledoc """
  Serves the static HTML page for `GET /sessions/attach?token=<token>`.

  ## Auth (PR 2026-05-09)

  The browser arrives with a `?token=` query param — a `Phoenix.Token`
  HMAC-signed payload of the PTY's actor_id, signed under salt
  `"pty_attach"` by `Esr.Commands.Pty.Attach.execute/1`. We verify
  with `max_age: 600` (10-minute TTL); on success we embed both the
  actor_id (for display) and the same token (for the WebSocket connect
  in `assets/js/app.js`) into the page; on failure we return 403 with
  a plain HTML page. PtySocket re-verifies the token on the WebSocket
  upgrade — this controller's verify is a defense-in-depth pre-check
  so we don't render the xterm.js shell for a bad token.

  Replaces PR-23's `EsrWeb.AttachLive`. The page is intentionally
  minimal: pulls the xterm.js bundle, embeds `ESR_SID` + `ESR_TOKEN`,
  opens a Phoenix.Socket WebSocket to `/attach_socket/websocket`. No
  LiveView, no DOM diffing — just an xterm container plus a script tag.
  """

  use Phoenix.Controller, formats: [:html]

  require Logger

  # Must match the salt used in Esr.Commands.Pty.Attach + EsrWeb.PtySocket.
  @token_salt "pty_attach"
  @token_max_age_seconds 600

  def show(conn, %{"token" => token}) when is_binary(token) and token != "" do
    case Phoenix.Token.verify(EsrWeb.Endpoint, @token_salt, token,
           max_age: @token_max_age_seconds
         ) do
      {:ok, actor_id} when is_binary(actor_id) and actor_id != "" ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, page_html(actor_id, token))

      {:error, reason} ->
        Logger.warning("attach_controller: token rejected reason=#{inspect(reason)}")

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(403, forbidden_html())
    end
  end

  def show(conn, _params) do
    Logger.warning("attach_controller: missing token query param")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(403, forbidden_html())
  end

  defp page_html(sid, token) do
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
        <script>
          window.ESR_SID = "#{escape_js(sid)}";
          window.ESR_TOKEN = "#{escape_js(token)}";
        </script>
        <script src="/assets/app.js" defer></script>
      </body>
    </html>
    """
  end

  defp forbidden_html do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>ESR · attach link expired</title>
        <style>
          html, body { height: 100%; margin: 0; background: #1e1e1e;
                       color: #d4d4d4;
                       font-family: Consolas, "Liberation Mono", Menlo,
                                    Courier, monospace; }
          .box { max-width: 480px; margin: 15vh auto; padding: 24px;
                 border: 1px solid #444; border-radius: 6px;
                 background: #2a2a2a; }
          h1 { margin: 0 0 12px; font-size: 18px; color: #ffaa33; }
          p { margin: 0 0 8px; line-height: 1.5; }
          code { background: #1a1a1a; padding: 2px 6px; border-radius: 3px; }
        </style>
      </head>
      <body>
        <div class="box">
          <h1>Attach link expired or invalid</h1>
          <p>This attach URL has either expired (10-minute TTL) or its
             signature does not verify. Run
             <code>/pty:attach pty=&lt;actor_id&gt;</code>
             again to get a fresh link.</p>
        </div>
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
