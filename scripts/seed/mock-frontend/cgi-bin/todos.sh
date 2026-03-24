#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Small CGI todo app used by the optional `task mock:app` demo flow.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/seed/runtime.sh"

# Escapes one text fragment for safe inline HTML rendering.
html_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&#39;/g"
}

# Decodes one form-urlencoded field payload.
url_decode_form_value() {
  local value="$1"

  value="${value//+/ }"
  printf '%b\n' "${value//%/\\x}"
}

# Extracts one named field from the POST body payload.
parse_form_field() {
  local body="$1"
  local key="$2"
  local old_ifs="${IFS}"
  local part=""
  local value=""

  IFS='&'
  for part in ${body}; do
    if [ "${part%%=*}" = "${key}" ]; then
      value="${part#*=}"
      IFS="${old_ifs}"
      url_decode_form_value "${value}"
      return 0
    fi
  done
  IFS="${old_ifs}"

  return 1
}

# Python's built-in CGI handler sends HTTP 200 before the script runs, so a
# CGI-level 302 redirect would render as a blank page in the browser. Return a
# tiny HTML redirect instead.
print_redirect_page() {
  printf 'Content-Type: text/html; charset=utf-8\r\n'
  printf '\r\n'
  cat <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=/cgi-bin/todos.sh">
    <title>Returning to todos</title>
    <script>
      window.location.replace('/cgi-bin/todos.sh');
    </script>
    <style>
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        background: #f4f0e8;
        color: #182022;
        font-family: Menlo, Monaco, "Courier New", monospace;
      }
      main {
        padding: 1.5rem;
        background: #fffdf8;
        border: 1px solid #d9cfbe;
      }
      a {
        color: #0d7b7b;
      }
    </style>
  </head>
  <body>
    <main>
      <p>Returning to the todo view.</p>
      <p><a href="/cgi-bin/todos.sh">Continue</a></p>
    </main>
  </body>
</html>
EOF
}

# Prints a small HTML error page for frontend failures.
print_error_page() {
  local message="$1"

  printf 'Status: 500 Internal Server Error\r\n'
  printf 'Content-Type: text/html; charset=utf-8\r\n'
  printf '\r\n'
  cat <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>OpenEverest Mock App</title>
    <style>
      body {
        font-family: Menlo, Monaco, "Courier New", monospace;
        margin: 2rem;
        background: #f7f4ee;
        color: #182022;
      }
      main {
        max-width: 48rem;
        margin: 0 auto;
        padding: 2rem;
        background: #fffdf8;
        border: 1px solid #d9cfbe;
      }
      code {
        background: #efe7d8;
        padding: 0.1rem 0.3rem;
      }
    </style>
  </head>
  <body>
    <main>
      <h1>Mock app is unavailable</h1>
      <p>$(html_escape "${message}")</p>
      <p>The seeded data still lives in <code>${TASK_SEED_COLLECTION_NAME}</code>.</p>
    </main>
  </body>
</html>
EOF
}

# Renders the current todo rows into table markup.
render_table_rows() {
  local connection_string="$1"
  local todo_id=""
  local title=""
  local completed=""
  local complete_label=""

  while IFS=$'\t' read -r todo_id title completed || [ -n "${todo_id}${title}${completed}" ]; do
    [ -n "${todo_id}" ] || continue

    if [ "${completed}" = "true" ]; then
      complete_label="Done"
    else
      complete_label="Open"
    fi

    cat <<EOF
        <tr>
          <td>$(html_escape "${todo_id}")</td>
          <td class="title">$(html_escape "${title}")</td>
          <td>${complete_label}</td>
          <td class="actions">
            <form method="post" action="/cgi-bin/todos.sh">
              <input type="hidden" name="action" value="toggle">
              <input type="hidden" name="id" value="$(html_escape "${todo_id}")">
              <button type="submit">Toggle</button>
            </form>
            <form method="post" action="/cgi-bin/todos.sh">
              <input type="hidden" name="action" value="delete">
              <input type="hidden" name="id" value="$(html_escape "${todo_id}")">
              <button type="submit" class="danger">Delete</button>
            </form>
          </td>
        </tr>
EOF
  done < <(task_seed_list_todos_tsv "${connection_string}")
}

# Renders the full GET response for the mock todo page.
render_page() {
  local connection_string="$1"
  local engine_label=""

  case "$(task_seed_engine_from_connection_string "${connection_string}")" in
    postgresql)
      engine_label="PostgreSQL"
      ;;
    mysql)
      engine_label="MySQL"
      ;;
    mongodb)
      engine_label="MongoDB"
      ;;
    *)
      engine_label="database"
      ;;
  esac

  printf 'Content-Type: text/html; charset=utf-8\r\n'
  printf '\r\n'
  cat <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>OpenEverest Mock App</title>
    <style>
      :root {
        color-scheme: light;
        --bg: #f4f0e8;
        --panel: #fffdf8;
        --border: #d9cfbe;
        --ink: #182022;
        --muted: #6d6358;
        --accent: #0d7b7b;
        --danger: #b84e3a;
      }
      * {
        box-sizing: border-box;
      }
      body {
        margin: 0;
        min-height: 100vh;
        background:
          radial-gradient(circle at top left, rgba(13, 123, 123, 0.12), transparent 28rem),
          radial-gradient(circle at bottom right, rgba(184, 78, 58, 0.10), transparent 24rem),
          var(--bg);
        color: var(--ink);
        font-family: Menlo, Monaco, "Courier New", monospace;
      }
      main {
        max-width: 62rem;
        margin: 0 auto;
        padding: 2rem 1.25rem 3rem;
      }
      .hero {
        padding: 1.5rem;
        border: 1px solid var(--border);
        background: var(--panel);
      }
      .hero h1 {
        margin: 0 0 0.75rem;
        font-size: clamp(1.8rem, 4vw, 2.8rem);
      }
      .hero p {
        margin: 0;
        color: var(--muted);
        line-height: 1.5;
      }
      .grid {
        display: grid;
        gap: 1rem;
        margin-top: 1rem;
      }
      .panel {
        padding: 1.25rem;
        border: 1px solid var(--border);
        background: var(--panel);
      }
      form {
        margin: 0;
      }
      .composer {
        display: grid;
        gap: 0.75rem;
      }
      input[type="text"] {
        width: 100%;
        padding: 0.8rem 0.9rem;
        border: 1px solid var(--border);
        background: #ffffff;
        color: var(--ink);
        font: inherit;
      }
      button {
        border: 1px solid var(--ink);
        background: var(--accent);
        color: #ffffff;
        padding: 0.7rem 0.95rem;
        font: inherit;
        cursor: pointer;
      }
      button.danger {
        background: var(--danger);
      }
      table {
        width: 100%;
        border-collapse: collapse;
      }
      th, td {
        padding: 0.8rem 0.55rem;
        border-top: 1px solid var(--border);
        text-align: left;
        vertical-align: top;
      }
      thead th {
        border-top: none;
        color: var(--muted);
      }
      td.title {
        width: 100%;
      }
      td.actions {
        white-space: nowrap;
      }
      td.actions form {
        display: inline-block;
        margin-right: 0.4rem;
      }
      .meta {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem 1rem;
        margin-top: 1rem;
        color: var(--muted);
      }
      .meta code {
        background: #efe7d8;
        padding: 0.1rem 0.3rem;
      }
      @media (max-width: 720px) {
        td.actions form {
          display: block;
          margin: 0 0 0.5rem;
        }
        td.actions form:last-child {
          margin-bottom: 0;
        }
      }
    </style>
  </head>
  <body>
    <main>
      <section class="hero">
        <h1>OpenEverest mock app</h1>
        <p>This lightweight demo talks straight to your seeded ${engine_label} database and only touches <code>${TASK_SEED_COLLECTION_NAME}</code>.</p>
        <div class="meta">
          <span>CRUD surface: <code>${TASK_SEED_COLLECTION_NAME}</code></span>
          <span>Mode: local demo only</span>
        </div>
      </section>

      <section class="panel grid">
        <form method="post" action="/cgi-bin/todos.sh" class="composer">
          <input type="hidden" name="action" value="create">
          <label for="title">Add a todo</label>
          <input id="title" name="title" type="text" maxlength="160" placeholder="Describe the next demo action" required>
          <button type="submit">Create</button>
        </form>
      </section>

      <section class="panel">
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Title</th>
              <th>Status</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
EOF
  render_table_rows "${connection_string}"
  cat <<'EOF'
          </tbody>
        </table>
      </section>
    </main>
  </body>
</html>
EOF
}

# Handles one POSTed CRUD action before returning to the todo view.
handle_post() {
  local connection_string="$1"
  local request_body=""
  local request_length="${CONTENT_LENGTH:-0}"
  local action=""
  local todo_id=""
  local title=""

  if [ "${request_length}" -gt 0 ]; then
    IFS= read -r -n "${request_length}" request_body || true
  fi

  action="$(parse_form_field "${request_body}" "action" 2>/dev/null || true)"

  case "${action}" in
    create)
      title="$(parse_form_field "${request_body}" "title" 2>/dev/null || true)"
      title="$(task_seed_normalize_title "${title}")"
      if [ -n "${title}" ]; then
        task_seed_create_todo "${connection_string}" "${title}"
      fi
      ;;
    toggle)
      todo_id="$(parse_form_field "${request_body}" "id" 2>/dev/null || true)"
      task_seed_toggle_todo "${connection_string}" "${todo_id}"
      ;;
    delete)
      todo_id="$(parse_form_field "${request_body}" "id" 2>/dev/null || true)"
      task_seed_delete_todo "${connection_string}" "${todo_id}"
      ;;
  esac

  print_redirect_page
}

# Loads the current mock app connection string from the command-scoped runtime
# file when the direct environment handoff is unavailable.
load_task_seed_frontend_connection_string() {
  local connection_string_file=""
  local connection_string=""

  connection_string="${PLAYGROUND_TASK_SEED_CONNECTION_STRING:-}"
  if [ -n "${connection_string}" ]; then
    printf '%s\n' "${connection_string}"
    return 0
  fi

  connection_string_file="$(task_seed_frontend_connection_file)"
  if [ ! -f "${connection_string_file}" ]; then
    return 1
  fi

  IFS= read -r connection_string <"${connection_string_file}" || connection_string=""
  [ -n "${connection_string}" ] || return 1
  printf '%s\n' "${connection_string}"
}

load_env
connection_string="$(load_task_seed_frontend_connection_string 2>/dev/null || true)"

if [ -z "${connection_string}" ]; then
  print_error_page "The mock app connection string is not loaded. Rerun task mock:app."
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  print_error_page "Docker is required to drive the demo database clients."
  exit 0
fi

if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
  if ! handle_post "${connection_string}"; then
    print_error_page "The last todo action failed. Check that the playground cluster and database are still reachable."
  fi
  exit 0
fi

if ! render_page "${connection_string}"; then
  print_error_page "The seeded todo table could not be queried. Check that the playground cluster and database are still reachable."
fi
