#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Helpers for the optional `task seed` demo flow.
# -----------------------------------------------------------------------------

TASK_SEED_COLLECTION_NAME="${TASK_SEED_COLLECTION_NAME:-playground_todos}"

# Returns the repo-local state directory used by the task seed flow.
task_seed_state_dir() {
  load_env
  printf '%s\n' "${PLAYGROUND_STATE_DIR}/task-seed"
}

# Returns the managed frontend PID file path.
task_seed_frontend_pid_file() {
  printf '%s/frontend.pid\n' "$(task_seed_state_dir)"
}

# Returns the managed frontend log file path.
task_seed_frontend_log_file() {
  printf '%s/frontend.log\n' "$(task_seed_state_dir)"
}

# Returns the managed database port-forward PID file path.
task_seed_port_forward_pid_file() {
  printf '%s/port-forward.pid\n' "$(task_seed_state_dir)"
}

# Returns the managed database port-forward log file path.
task_seed_port_forward_log_file() {
  printf '%s/port-forward.log\n' "$(task_seed_state_dir)"
}

# Returns the file that records the chosen local forwarded DB port.
task_seed_port_forward_local_port_file() {
  printf '%s/port-forward.local-port\n' "$(task_seed_state_dir)"
}

# Ensures the task seed runtime directory exists before writes.
ensure_task_seed_state_dir() {
  mkdir -p "$(task_seed_state_dir)"
}

# Stops one managed background process if its PID file still points at a live PID.
task_seed_stop_process_from_pid_file() {
  local pid_file="$1"
  local pid=""

  if [ ! -f "${pid_file}" ]; then
    return 0
  fi

  IFS= read -r pid <"${pid_file}" || pid=""

  if [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" 2>/dev/null || true
  fi

  rm -f "${pid_file}"
}

# Stops the managed mock frontend server, if present.
stop_task_seed_frontend() {
  task_seed_stop_process_from_pid_file "$(task_seed_frontend_pid_file)"
}

# Stops the managed database port-forward, if present.
stop_task_seed_port_forward() {
  task_seed_stop_process_from_pid_file "$(task_seed_port_forward_pid_file)"
  rm -f "$(task_seed_port_forward_local_port_file)"
}

# Stops all managed task seed background processes.
stop_task_seed_runtime() {
  stop_task_seed_frontend
  stop_task_seed_port_forward
}

# Normalizes a URI scheme into one supported task seed engine key.
task_seed_engine_from_scheme() {
  local scheme="$1"

  case "${scheme}" in
    postgresql | postgres)
      printf 'postgresql\n'
      ;;
    mysql)
      printf 'mysql\n'
      ;;
    mongodb | mongodb+srv)
      printf 'mongodb\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# Parses one connection string into shell globals used by the engine helpers.
task_seed_parse_connection_string() {
  local connection_string="$1"
  local remainder=""
  local authority_and_path=""
  local host_and_path=""
  local path_suffix=""

  TASK_SEED_URI_SCHEME_RAW="${connection_string%%://*}"

  if [ "${TASK_SEED_URI_SCHEME_RAW}" = "${connection_string}" ]; then
    return 1
  fi

  TASK_SEED_URI_ENGINE="$(task_seed_engine_from_scheme "${TASK_SEED_URI_SCHEME_RAW}")" || return 1

  remainder="${connection_string#*://}"
  authority_and_path="${remainder}"
  TASK_SEED_URI_QUERY=""

  if [[ "${remainder}" == *\?* ]]; then
    authority_and_path="${remainder%%\?*}"
    TASK_SEED_URI_QUERY="${remainder#*\?}"
  fi

  TASK_SEED_URI_USERINFO=""
  host_and_path="${authority_and_path}"

  if [[ "${authority_and_path}" == *"@"* ]]; then
    TASK_SEED_URI_USERINFO="${authority_and_path%@*}"
    host_and_path="${authority_and_path#*@}"
  fi

  if [[ "${host_and_path}" == */* ]]; then
    TASK_SEED_URI_HOSTLIST="${host_and_path%%/*}"
    path_suffix="${host_and_path#*/}"
    TASK_SEED_URI_PATH="/${path_suffix}"
  else
    TASK_SEED_URI_HOSTLIST="${host_and_path}"
    TASK_SEED_URI_PATH="/"
  fi

  [ -n "${TASK_SEED_URI_HOSTLIST}" ]
}

# Returns the normalized engine key for one connection string.
task_seed_engine_from_connection_string() {
  task_seed_parse_connection_string "$1" || return 1
  printf '%s\n' "${TASK_SEED_URI_ENGINE}"
}

# Returns the default port for one supported engine.
task_seed_default_port_for_engine() {
  case "$1" in
    postgresql)
      printf '5432\n'
      ;;
    mysql)
      printf '3306\n'
      ;;
    mongodb)
      printf '27017\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns the first host entry from the raw host list.
task_seed_first_host_entry() {
  printf '%s\n' "${TASK_SEED_URI_HOSTLIST%%,*}"
}

# Splits one host entry into host and port columns.
task_seed_split_host_port() {
  local host_entry="$1"
  local default_port="$2"
  local host="${host_entry}"
  local port="${default_port}"

  case "${host_entry}" in
    \[*\]:*)
      host="${host_entry%%]:*}"
      host="${host#[}"
      port="${host_entry##*:}"
      ;;
    \[*\])
      host="${host_entry#[}"
      host="${host%]}"
      ;;
    *:*)
      host="${host_entry%:*}"
      port="${host_entry##*:}"
      ;;
  esac

  printf '%s\t%s\n' "${host}" "${port}"
}

# Returns success when the host is only reachable from inside the cluster.
task_seed_host_is_cluster_internal() {
  local host="$1"

  case "${host}" in
    *.svc | *.svc.cluster.local | *.cluster.local)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns success when the host should be rewritten for containerized clients.
task_seed_host_is_localhost() {
  local host="$1"

  case "${host}" in
    localhost | 127.0.0.1 | 0.0.0.0)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Converts a service DNS host into the kubectl port-forward target and namespace.
task_seed_service_ref_from_host() {
  local host="$1"
  local service_name=""
  local remainder=""
  local namespace=""

  service_name="${host%%.*}"
  remainder="${host#*.}"

  if [ "${remainder}" = "${host}" ]; then
    return 1
  fi

  namespace="${remainder%%.*}"

  [ -n "${service_name}" ] && [ -n "${namespace}" ] || return 1

  printf 'service/%s\t%s\n' "${service_name}" "${namespace}"
}

# Upserts one query-string parameter while preserving the others.
task_seed_upsert_query_param() {
  local query="${1:-}"
  local key="$2"
  local value="$3"
  local old_ifs="${IFS}"
  local rendered=""
  local part=""
  local updated="false"

  if [ -z "${query}" ]; then
    printf '%s=%s\n' "${key}" "${value}"
    return 0
  fi

  IFS='&'
  for part in ${query}; do
    if [ "${part%%=*}" = "${key}" ]; then
      part="${key}=${value}"
      updated="true"
    fi

    if [ -n "${rendered}" ]; then
      rendered="${rendered}&${part}"
    else
      rendered="${part}"
    fi
  done
  IFS="${old_ifs}"

  if [ "${updated}" != "true" ]; then
    rendered="${rendered}&${key}=${value}"
  fi

  printf '%s\n' "${rendered}"
}

# Looks up one decoded query-string value by key.
task_seed_query_param_value() {
  local query="${1:-}"
  local key="$2"
  local old_ifs="${IFS}"
  local part=""
  local part_key=""
  local part_value=""

  IFS='&'
  for part in ${query}; do
    part_key="${part%%=*}"
    if [ "${part_key}" = "${key}" ]; then
      part_value="${part#*=}"
      IFS="${old_ifs}"
      task_seed_url_decode "${part_value}"
      return 0
    fi
  done
  IFS="${old_ifs}"

  return 1
}

# Reassembles the parsed connection string with a different host list or query string.
task_seed_rebuild_connection_string() {
  local hostlist="$1"
  local query="${2:-${TASK_SEED_URI_QUERY}}"
  local rebuilt=""

  rebuilt="${TASK_SEED_URI_SCHEME_RAW}://"

  if [ -n "${TASK_SEED_URI_USERINFO}" ]; then
    rebuilt="${rebuilt}${TASK_SEED_URI_USERINFO}@"
  fi

  rebuilt="${rebuilt}${hostlist}${TASK_SEED_URI_PATH}"

  if [ -n "${query}" ]; then
    rebuilt="${rebuilt}?${query}"
  fi

  printf '%s\n' "${rebuilt}"
}

# URL-decodes one small URI component.
task_seed_url_decode() {
  local value="$1"

  value="${value//+/ }"
  printf '%b\n' "${value//%/\\x}"
}

# Normalizes a title into one compact line for the demo UI.
task_seed_normalize_title() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

# Escapes one SQL string literal payload.
task_seed_sql_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Escapes one JavaScript single-quoted string literal payload.
task_seed_js_literal() {
  printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"
}

# Returns success when the ID is a safe integer string for SQL engines.
task_seed_id_is_integer() {
  local id="$1"

  case "${id}" in
    '' | *[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

# Returns success when the ID looks like one Mongo ObjectId.
task_seed_id_is_object_id() {
  local id="$1"

  case "${id}" in
    '' | *[!0-9a-fA-F]*)
      return 1
      ;;
  esac

  [ "${#id}" -eq 24 ]
}

# Starts one managed kubectl port-forward and returns the chosen local port.
start_task_seed_port_forward() {
  local service_ref="$1"
  local namespace="$2"
  local remote_port="$3"
  local log_file=""
  local pid_file=""
  local local_port_file=""
  local pid=0
  local attempt=0
  local local_port=""

  load_env
  ensure_task_seed_state_dir
  stop_task_seed_port_forward

  log_file="$(task_seed_port_forward_log_file)"
  pid_file="$(task_seed_port_forward_pid_file)"
  local_port_file="$(task_seed_port_forward_local_port_file)"

  : >"${log_file}"

  kubectl --context "${KUBE_CONTEXT}" -n "${namespace}" port-forward "${service_ref}" ":${remote_port}" >"${log_file}" 2>&1 &
  pid=$!
  printf '%s\n' "${pid}" >"${pid_file}"

  while [ "${attempt}" -lt 50 ]; do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      rm -f "${pid_file}" "${local_port_file}"
      return 1
    fi

    local_port="$(sed -nE 's/.*127\.0\.0\.1:([0-9]+).*/\1/p' "${log_file}" | head -n 1)"
    if [ -n "${local_port}" ]; then
      printf '%s\n' "${local_port}" >"${local_port_file}"
      printf '%s\n' "${local_port}"
      return 0
    fi

    sleep 0.2
    attempt=$((attempt + 1))
  done

  stop_task_seed_port_forward
  return 1
}

# Rewrites one connection string so the Dockerized clients can reach it locally.
task_seed_prepare_client_connection_string() {
  local connection_string="$1"
  local default_port=""
  local first_host_entry=""
  local first_host=""
  local first_port=""
  local service_ref=""
  local namespace=""
  local local_port=""
  local query=""

  task_seed_parse_connection_string "${connection_string}" || return 1
  default_port="$(task_seed_default_port_for_engine "${TASK_SEED_URI_ENGINE}")"
  first_host_entry="$(task_seed_first_host_entry)"
  IFS=$'\t' read -r first_host first_port <<<"$(task_seed_split_host_port "${first_host_entry}" "${default_port}")"

  if task_seed_host_is_cluster_internal "${first_host}"; then
    IFS=$'\t' read -r service_ref namespace <<<"$(task_seed_service_ref_from_host "${first_host}")" || return 1
    local_port="$(start_task_seed_port_forward "${service_ref}" "${namespace}" "${first_port}")" || return 1
    query="${TASK_SEED_URI_QUERY}"
    if [ "${TASK_SEED_URI_ENGINE}" = "mongodb" ]; then
      query="$(task_seed_upsert_query_param "${query}" "directConnection" "true")"
    fi
    task_seed_rebuild_connection_string "host.docker.internal:${local_port}" "${query}"
    return 0
  fi

  if task_seed_host_is_localhost "${first_host}"; then
    query="${TASK_SEED_URI_QUERY}"
    if [ "${TASK_SEED_URI_ENGINE}" = "mongodb" ] && [[ "${TASK_SEED_URI_HOSTLIST}" == *,* ]]; then
      query="$(task_seed_upsert_query_param "${query}" "directConnection" "true")"
    fi
    task_seed_rebuild_connection_string "host.docker.internal:${first_port}" "${query}"
    return 0
  fi

  printf '%s\n' "${connection_string}"
}

# Parses one MySQL connection string into shell globals for the CLI wrapper.
task_seed_parse_mysql_connection_fields() {
  local connection_string="$1"
  local default_port="3306"
  local first_host_entry=""
  local first_host=""
  local first_port=""
  local raw_user=""
  local raw_password=""
  local ssl_mode=""

  task_seed_parse_connection_string "${connection_string}" || return 1
  [ "${TASK_SEED_URI_ENGINE}" = "mysql" ] || return 1

  first_host_entry="$(task_seed_first_host_entry)"
  IFS=$'\t' read -r first_host first_port <<<"$(task_seed_split_host_port "${first_host_entry}" "${default_port}")"

  raw_user="${TASK_SEED_URI_USERINFO%%:*}"
  raw_password=""

  if [ "${TASK_SEED_URI_USERINFO}" != "${raw_user}" ]; then
    raw_password="${TASK_SEED_URI_USERINFO#*:}"
  fi

  TASK_SEED_MYSQL_HOST="${first_host}"
  TASK_SEED_MYSQL_PORT="${first_port}"
  TASK_SEED_MYSQL_USER="$(task_seed_url_decode "${raw_user}")"
  TASK_SEED_MYSQL_PASSWORD="$(task_seed_url_decode "${raw_password}")"
  TASK_SEED_MYSQL_DATABASE="$(task_seed_url_decode "${TASK_SEED_URI_PATH#/}")"
  TASK_SEED_MYSQL_SSL_MODE=""

  if ssl_mode="$(task_seed_query_param_value "${TASK_SEED_URI_QUERY}" "ssl-mode" 2>/dev/null)"; then
    TASK_SEED_MYSQL_SSL_MODE="${ssl_mode}"
  elif ssl_mode="$(task_seed_query_param_value "${TASK_SEED_URI_QUERY}" "sslMode" 2>/dev/null)"; then
    TASK_SEED_MYSQL_SSL_MODE="${ssl_mode}"
  fi
}

# Runs one PostgreSQL SQL statement through a throwaway client container.
task_seed_postgres_sql() {
  local connection_string="$1"
  local sql="$2"

  docker run --rm --add-host=host.docker.internal:host-gateway postgres:16-alpine \
    psql "${connection_string}" -v ON_ERROR_STOP=1 -qAt -F $'\t' -c "${sql}"
}

# Runs one MySQL SQL statement through a throwaway client container.
task_seed_mysql_sql() {
  local connection_string="$1"
  local sql="$2"
  local -a command=()

  task_seed_parse_mysql_connection_fields "${connection_string}" || return 1

  command=(
    docker run --rm --add-host=host.docker.internal:host-gateway
    -e "MYSQL_PWD=${TASK_SEED_MYSQL_PASSWORD}"
    mysql:8
    mysql
    --protocol=TCP
    --batch
    --skip-column-names
    --host="${TASK_SEED_MYSQL_HOST}"
    --port="${TASK_SEED_MYSQL_PORT}"
    --user="${TASK_SEED_MYSQL_USER}"
  )

  if [ -n "${TASK_SEED_MYSQL_SSL_MODE}" ]; then
    command+=("--ssl-mode=${TASK_SEED_MYSQL_SSL_MODE}")
  fi

  if [ -n "${TASK_SEED_MYSQL_DATABASE}" ]; then
    command+=("${TASK_SEED_MYSQL_DATABASE}")
  fi

  command+=("-e" "${sql}")
  "${command[@]}"
}

# Runs one Mongo shell snippet through a throwaway client container.
task_seed_mongo_eval() {
  local connection_string="$1"
  local script="$2"

  docker run --rm --add-host=host.docker.internal:host-gateway mongo:7 \
    mongosh "${connection_string}" --quiet --eval "${script}"
}

# Seeds the PostgreSQL demo table only when it is still empty and prints the
# resulting status token.
task_seed_seed_postgresql() {
  local connection_string="$1"
  local sql=""

  sql="
CREATE TABLE IF NOT EXISTS ${TASK_SEED_COLLECTION_NAME} (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  completed BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
WITH existing AS (
  SELECT EXISTS (SELECT 1 FROM ${TASK_SEED_COLLECTION_NAME} LIMIT 1) AS has_rows
), seeded AS (
  INSERT INTO ${TASK_SEED_COLLECTION_NAME} (title, completed)
  SELECT seed.title, seed.completed
  FROM (
    VALUES
      ('Create a demo database in OpenEverest', TRUE),
      ('Run task seed against its connection string', TRUE),
      ('Open the mock todo app and try CRUD', FALSE)
  ) AS seed(title, completed)
  WHERE NOT (SELECT has_rows FROM existing)
)
SELECT CASE
  WHEN (SELECT has_rows FROM existing) THEN 'already-present'
  ELSE 'seeded'
END;
"

  task_seed_postgres_sql "${connection_string}" "${sql}" | tail -n 1
}

# Seeds the MySQL demo table only when it is still empty and prints the
# resulting status token.
task_seed_seed_mysql() {
  local connection_string="$1"
  local sql=""

  sql="
CREATE TABLE IF NOT EXISTS ${TASK_SEED_COLLECTION_NAME} (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  title TEXT NOT NULL,
  completed BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
SET @task_seed_has_rows = EXISTS(SELECT 1 FROM ${TASK_SEED_COLLECTION_NAME} LIMIT 1);
INSERT INTO ${TASK_SEED_COLLECTION_NAME} (title, completed)
SELECT seed.title, seed.completed
FROM (
  SELECT 'Create a demo database in OpenEverest' AS title, TRUE AS completed
  UNION ALL
  SELECT 'Run task seed against its connection string', TRUE
  UNION ALL
  SELECT 'Open the mock todo app and try CRUD', FALSE
) AS seed
WHERE @task_seed_has_rows = 0;
SELECT IF(@task_seed_has_rows = 1, 'already-present', 'seeded');
"

  task_seed_mysql_sql "${connection_string}" "${sql}" | tail -n 1
}

# Seeds the MongoDB demo collection only when it is still empty and prints the
# resulting status token.
task_seed_seed_mongodb() {
  local connection_string="$1"
  local script=""

  script="
const todos = db.getCollection('${TASK_SEED_COLLECTION_NAME}');
if (todos.countDocuments({}) === 0) {
  todos.insertMany([
    { title: 'Create a demo database in OpenEverest', completed: true, createdAt: new Date() },
    { title: 'Run task seed against its connection string', completed: true, createdAt: new Date() },
    { title: 'Open the mock todo app and try CRUD', completed: false, createdAt: new Date() }
  ]);
  print('seeded');
} else {
  print('already-present');
}
"

  task_seed_mongo_eval "${connection_string}" "${script}" | tail -n 1
}

# Seeds the demo dataset into the supported engine named by the connection
# string and prints `seeded` or `already-present`.
task_seed_seed_demo_data() {
  local connection_string="$1"
  local engine=""

  engine="$(task_seed_engine_from_connection_string "${connection_string}")" || return 1

  case "${engine}" in
    postgresql)
      task_seed_seed_postgresql "${connection_string}"
      ;;
    mysql)
      task_seed_seed_mysql "${connection_string}"
      ;;
    mongodb)
      task_seed_seed_mongodb "${connection_string}"
      ;;
  esac
}

# Lists the PostgreSQL demo rows as id, title, completed tab-delimited fields.
task_seed_list_postgresql_todos_tsv() {
  local connection_string="$1"
  local sql=""

  sql="
SELECT id::text, REPLACE(REPLACE(title, E'\t', ' '), E'\n', ' '), CASE WHEN completed THEN 'true' ELSE 'false' END
FROM ${TASK_SEED_COLLECTION_NAME}
ORDER BY id;
"

  task_seed_postgres_sql "${connection_string}" "${sql}"
}

# Lists the MySQL demo rows as id, title, completed tab-delimited fields.
task_seed_list_mysql_todos_tsv() {
  local connection_string="$1"
  local sql=""

  sql="
SELECT CAST(id AS CHAR), REPLACE(REPLACE(title, '\t', ' '), '\n', ' '), IF(completed = 1, 'true', 'false')
FROM ${TASK_SEED_COLLECTION_NAME}
ORDER BY id;
"

  task_seed_mysql_sql "${connection_string}" "${sql}"
}

# Lists the MongoDB demo rows as id, title, completed tab-delimited fields.
task_seed_list_mongodb_todos_tsv() {
  local connection_string="$1"
  local script=""

  script="
db.getCollection('${TASK_SEED_COLLECTION_NAME}')
  .find({}, { _id: 1, title: 1, completed: 1 })
  .sort({ createdAt: 1, _id: 1 })
  .forEach((doc) => {
    const title = String(doc.title || '').replace(/\\t/g, ' ').replace(/\\r?\\n/g, ' ');
    print([doc._id.valueOf(), title, doc.completed ? 'true' : 'false'].join('\\t'));
  });
"

  task_seed_mongo_eval "${connection_string}" "${script}"
}

# Lists the demo rows as id, title, completed tab-delimited fields.
task_seed_list_todos_tsv() {
  local connection_string="$1"
  local engine=""

  engine="$(task_seed_engine_from_connection_string "${connection_string}")" || return 1

  case "${engine}" in
    postgresql)
      task_seed_list_postgresql_todos_tsv "${connection_string}"
      ;;
    mysql)
      task_seed_list_mysql_todos_tsv "${connection_string}"
      ;;
    mongodb)
      task_seed_list_mongodb_todos_tsv "${connection_string}"
      ;;
  esac
}

# Inserts one PostgreSQL todo row.
task_seed_create_postgresql_todo() {
  local connection_string="$1"
  local title="$2"
  local escaped_title=""

  escaped_title="$(task_seed_sql_literal "$(task_seed_normalize_title "${title}")")"
  task_seed_postgres_sql "${connection_string}" "INSERT INTO ${TASK_SEED_COLLECTION_NAME} (title, completed) VALUES ('${escaped_title}', FALSE);" >/dev/null
}

# Inserts one MySQL todo row.
task_seed_create_mysql_todo() {
  local connection_string="$1"
  local title="$2"
  local escaped_title=""

  escaped_title="$(task_seed_sql_literal "$(task_seed_normalize_title "${title}")")"
  task_seed_mysql_sql "${connection_string}" "INSERT INTO ${TASK_SEED_COLLECTION_NAME} (title, completed) VALUES ('${escaped_title}', FALSE);" >/dev/null
}

# Inserts one MongoDB todo row.
task_seed_create_mongodb_todo() {
  local connection_string="$1"
  local title="$2"
  local escaped_title=""
  local script=""

  escaped_title="$(task_seed_js_literal "$(task_seed_normalize_title "${title}")")"
  script="
db.getCollection('${TASK_SEED_COLLECTION_NAME}').insertOne({
  title: '${escaped_title}',
  completed: false,
  createdAt: new Date()
});
"

  task_seed_mongo_eval "${connection_string}" "${script}" >/dev/null
}

# Inserts one todo row into the demo dataset.
task_seed_create_todo() {
  local connection_string="$1"
  local title="$2"
  local engine=""

  engine="$(task_seed_engine_from_connection_string "${connection_string}")" || return 1

  case "${engine}" in
    postgresql)
      task_seed_create_postgresql_todo "${connection_string}" "${title}"
      ;;
    mysql)
      task_seed_create_mysql_todo "${connection_string}" "${title}"
      ;;
    mongodb)
      task_seed_create_mongodb_todo "${connection_string}" "${title}"
      ;;
  esac
}

# Toggles one PostgreSQL todo row.
task_seed_toggle_postgresql_todo() {
  local connection_string="$1"
  local todo_id="$2"

  task_seed_id_is_integer "${todo_id}" || return 1
  task_seed_postgres_sql "${connection_string}" "UPDATE ${TASK_SEED_COLLECTION_NAME} SET completed = NOT completed WHERE id = ${todo_id};" >/dev/null
}

# Toggles one MySQL todo row.
task_seed_toggle_mysql_todo() {
  local connection_string="$1"
  local todo_id="$2"

  task_seed_id_is_integer "${todo_id}" || return 1
  task_seed_mysql_sql "${connection_string}" "UPDATE ${TASK_SEED_COLLECTION_NAME} SET completed = NOT completed WHERE id = ${todo_id};" >/dev/null
}

# Toggles one MongoDB todo row.
task_seed_toggle_mongodb_todo() {
  local connection_string="$1"
  local todo_id="$2"
  local script=""

  task_seed_id_is_object_id "${todo_id}" || return 1
  script="
db.getCollection('${TASK_SEED_COLLECTION_NAME}').updateOne(
  { _id: ObjectId('${todo_id}') },
  [{ \$set: { completed: { \$not: ['\$completed'] } } }]
);
"

  task_seed_mongo_eval "${connection_string}" "${script}" >/dev/null
}

# Toggles one demo todo row.
task_seed_toggle_todo() {
  local connection_string="$1"
  local todo_id="$2"
  local engine=""

  engine="$(task_seed_engine_from_connection_string "${connection_string}")" || return 1

  case "${engine}" in
    postgresql)
      task_seed_toggle_postgresql_todo "${connection_string}" "${todo_id}"
      ;;
    mysql)
      task_seed_toggle_mysql_todo "${connection_string}" "${todo_id}"
      ;;
    mongodb)
      task_seed_toggle_mongodb_todo "${connection_string}" "${todo_id}"
      ;;
  esac
}

# Deletes one PostgreSQL todo row.
task_seed_delete_postgresql_todo() {
  local connection_string="$1"
  local todo_id="$2"

  task_seed_id_is_integer "${todo_id}" || return 1
  task_seed_postgres_sql "${connection_string}" "DELETE FROM ${TASK_SEED_COLLECTION_NAME} WHERE id = ${todo_id};" >/dev/null
}

# Deletes one MySQL todo row.
task_seed_delete_mysql_todo() {
  local connection_string="$1"
  local todo_id="$2"

  task_seed_id_is_integer "${todo_id}" || return 1
  task_seed_mysql_sql "${connection_string}" "DELETE FROM ${TASK_SEED_COLLECTION_NAME} WHERE id = ${todo_id};" >/dev/null
}

# Deletes one MongoDB todo row.
task_seed_delete_mongodb_todo() {
  local connection_string="$1"
  local todo_id="$2"
  local script=""

  task_seed_id_is_object_id "${todo_id}" || return 1
  script="db.getCollection('${TASK_SEED_COLLECTION_NAME}').deleteOne({ _id: ObjectId('${todo_id}') });"
  task_seed_mongo_eval "${connection_string}" "${script}" >/dev/null
}

# Deletes one demo todo row.
task_seed_delete_todo() {
  local connection_string="$1"
  local todo_id="$2"
  local engine=""

  engine="$(task_seed_engine_from_connection_string "${connection_string}")" || return 1

  case "${engine}" in
    postgresql)
      task_seed_delete_postgresql_todo "${connection_string}" "${todo_id}"
      ;;
    mysql)
      task_seed_delete_mysql_todo "${connection_string}" "${todo_id}"
      ;;
    mongodb)
      task_seed_delete_mongodb_todo "${connection_string}" "${todo_id}"
      ;;
  esac
}
