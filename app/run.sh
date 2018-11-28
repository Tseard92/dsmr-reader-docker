#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

#---------------------------------------------------------------------------------------------------------------------------
# VARIABLES
#---------------------------------------------------------------------------------------------------------------------------
: "${DEBUG:=false}"
: "${COMMAND:=$@}"
DB_PORT=${DB_PORT:-5432}
TIMER=${TIMER:-60}

#---------------------------------------------------------------------------------------------------------------------------
# FUNCTIONS
#---------------------------------------------------------------------------------------------------------------------------
function _info  () { echo -e "\\r[ \\033[00;34mINFO\\033[0m ] $*"; }
function _warn  () { echo -e "\\r\\033[2K[ \\033[0;33mWARN\\033[0m ] $*"; }
function _error () { echo -e "\\r\\033[2K[ \\033[0;31mFAIL\\033[0m ] $*"; }
function _debug () { echo -e "\\r[ \\033[00;37mDBUG\\033[0m ] $*"; }

function _pre_reqs() {
  _info "Checking if the DSMR web credential variables have been set..."
  if [ -z "${DSMR_USER}" ] || [ -z "${DSMR_EMAIL}" ] || [ -z "${DSMR_PASSWORD}" ]; then
    _error "DSMR web credentials not set. Exiting..."
    exit 1
  fi

  _info "Fixing /dev/ttyUSB* security..."
  [[ -e '/dev/ttyUSB0' ]] && chmod 666 /dev/ttyUSB*

  _info "Removing existing PID files..."
  rm -f /var/tmp/*.pid
}

function _override_entrypoint() {
  if [ -n "${COMMAND}" ]; then
    _info "ENTRYPOINT: Executing override command..."
    exec "${COMMAND}"
  fi
}

function _check_db_availability() {
  set -o xtrace
  _info "Verifying if Postgres in running..."
  cmd=$(command -v pg_isready)
  cmd="${cmd} -h ${DB_HOST} -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME} -t 1"
  while ! "${cmd}" >/dev/null 2>&1; do
    TIMER=$((TIMER-1))
    sleep 1
    if [[ "${TIMER}" -eq 0 ]]; then
      _error "Could not connect to database server. Aborting..."
      exit 1
    fi
    echo -n "."
  done
}

function _run_post_config() {
  _info "Running post configuration..."
  cmd=$(command -v python3)
  "${cmd}" manage.py migrate --noinput
  "${cmd}" manage.py collectstatic --noinput
  "${cmd}" manage.py shell -i python << PYTHON
  from django.contrib.auth.models import User
  if not User.objects.filter(username='${DSMR_USER}'):
    User.objects.create_superuser('${DSMR_USER}', '${DSMR_EMAIL}', '${DSMR_PASSWORD}')
    print('${DSMR_USER} created')
  else:
    print('${DSMR_USER} already exists')
PYTHON
}

function _start_supervisord() {
  _info "Starting supervisord..."
  cmd=$(command -v supervisord)
  "${cmd}" -n
}

#---------------------------------------------------------------------------------------------------------------------------
# MAIN
#---------------------------------------------------------------------------------------------------------------------------
[[ "${DEBUG}" == 'true' ]] && set -o xtrace

_pre_reqs
_override_entrypoint
_check_db_availability
_run_post_config
_start_supervisord