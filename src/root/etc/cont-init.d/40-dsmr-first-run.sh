#!/usr/bin/with-contenv bash
#set -o errexit
#set -o pipefail
#set -o nounset

#---------------------------------------------------------------------------------------------------------------------------
# VARIABLES
#---------------------------------------------------------------------------------------------------------------------------
: "${DEBUG:=false}"
: "${COMMAND:=$@}"
: "${TIMER:=60}"
: "${DSMR_GIT_REPO:=dsmrreader/dsmr-reader}"

#---------------------------------------------------------------------------------------------------------------------------
# FUNCTIONS
#---------------------------------------------------------------------------------------------------------------------------
function _info  () { printf "\\r[ \\033[00;34mINFO\\033[0m ] %s\\n" "$@"; }
function _warn  () { printf "\\r\\033[2K[ \\033[0;33mWARN\\033[0m ] %s\\n" "$@"; }
function _error () { printf "\\r\\033[2K[ \\033[0;31mFAIL\\033[0m ] %s\\n" "$@"; }
function _debug () { printf "\\r[ \\033[00;37mDBUG\\033[0m ] %s\\n" "$@"; }

function _pre_reqs() {
  alias cp="cp"

  _info "Verifying if the DSMR web credential variables have been set..."
  if [[ -z "${DSMRREADER_ADMIN_USER}" ]] || [[ -z "${DSMRREADER_ADMIN_PASSWORD}" ]]; then
    _error "DSMR web credentials not set. Exiting..."
    exit 1
  fi

  _info "Fixing /dev/ttyUSB* security..."
  [[ -e '/dev/ttyUSB0' ]] && chmod 666 /dev/ttyUSB*
}

function __dsmr_client_installation() {
  _info "Installing the DSMR remote datalogger client..."
  touch /dsmr/.env
  if [[ -z "${DATALOGGER_API_HOSTS}" || -z "${DATALOGGER_API_KEYS}" || -z "${DATALOGGER_INPUT_METHOD}" ]]; then
      _error "DATALOGGER_API_HOSTS and/or DATALOGGER_API_KEYS and/or DATALOGGER_INPUT_METHOD required values are not set. Exiting..."
      exit 1
  else
    if [[ "${DATALOGGER_INPUT_METHOD}" = ipv4 ]]; then
      _info "Using a network socket for the DSMR remote datalogger..."
      if [[ -z "${DATALOGGER_NETWORK_HOST}" || -z "${DATALOGGER_NETWORK_PORT}" ]]; then
        _error "DATALOGGER_NETWORK_HOST and/or DATALOGGER_NETWORK_PORT required values are not set. Exiting..."
        exit 1
      else
        _info "Adding DATALOGGER_NETWORK_HOST and DATALOGGER_NETWORK_PORT to the DSMR remote datalogger configuration..."
        { echo DATALOGGER_NETWORK_HOST="${DATALOGGER_NETWORK_HOST}"; echo DATALOGGER_NETWORK_PORT="${DATALOGGER_NETWORK_PORT}"; } >> /dsmr/.env
      fi
    elif [[ "${DATALOGGER_INPUT_METHOD}" = serial ]]; then
      _info "Using a serial connection for the DSMR remote datalogger..."
      if [[ -z "${DATALOGGER_SERIAL_PORT}" || -z "${DATALOGGER_SERIAL_BAUDRATE}" ]]; then
        _error "DATALOGGER_SERIAL_PORT and/or DATALOGGER_SERIAL_BAUDRATE required values are not set. Exiting..."
        exit 1
      else
        _info "Adding DATALOGGER_SERIAL_PORT and DATALOGGER_SERIAL_PORT to the DSMR remote datalogger configuration..."
        { echo DATALOGGER_SERIAL_PORT="${DATALOGGER_SERIAL_PORT}"; echo DATALOGGER_SERIAL_PORT="${DATALOGGER_SERIAL_PORT}"; } >> /dsmr/.env
      fi
    else
      _error "Incorrect configuration of the DATALOGGER_INPUT_METHOD value. Exiting..."
      exit 1
    fi
    _info "Adding DATALOGGER_API_HOSTS, DATALOGGER_API_KEYS and DATALOGGER_INPUT_METHOD to the DSMR remote datalogger configuration..."
    { echo DATALOGGER_API_HOSTS="${DATALOGGER_API_HOSTS}"; echo DATALOGGER_API_KEYS="${DATALOGGER_API_KEYS}"; echo DATALOGGER_INPUT_METHOD="${DATALOGGER_INPUT_METHOD}"; } >> /dsmr/.env
  fi

  if [[ -n "${DATALOGGER_TIMEOUT}" ]]; then
    _info "Adding DATALOGGER_TIMEOUT to the DSMR remote datalogger configuration..."
    echo DATALOGGER_TIMEOUT="${DATALOGGER_TIMEOUT}" >> /dsmr/.env
  fi

  if [[ -n "${DATALOGGER_SLEEP}" ]]; then
    _info "Adding DATALOGGER_SLEEP to the DSMR remote datalogger configuration..."
    echo DATALOGGER_SLEEP="${DATALOGGER_SLEEP}" >> /dsmr/.env
  fi

  if [[ -n "${DATALOGGER_DEBUG_LOGGING}" ]]; then
    _info "Adding DATALOGGER_DEBUG_LOGGING to the DSMR remote datalogger configuration..."
    echo DATALOGGER_DEBUG_LOGGING="${DATALOGGER_DEBUG_LOGGING}" >> /dsmr/.env
  fi
}

function _check_db_availability() {
  _info "Verifying Database connectivity..."
  cmd=$(command -v python3)
  "${cmd}" /dsmr/manage.py shell -c 'import django; print(django.db.connection.ensure_connection()); quit();'
  if [[ "$?" -ne 0 ]]; then
    _error "Could not connect to database server. Exiting..."
    exit 1
  fi
}

function _run_post_config() {
  _info "Running post configuration..."
  cmd=$(command -v python3)
  "${cmd}" /dsmr/manage.py migrate --noinput
  "${cmd}" /dsmr/manage.py collectstatic --noinput
  "${cmd}" /dsmr/manage.py dsmr_superuser
}

function _nginx_ssl_configuration() {
  _info "Checking for NGINX SSL configuration..."
  if [[ -n "${ENABLE_NGINX_SSL}" ]]; then
    if [[ "${ENABLE_NGINX_SSL}" = true ]] ; then
      if [[ ! -f "/etc/ssl/private/fullchain.pem" ]] && [[ ! -f "/etc/ssl/private/fullchain.pem" ]] ; then
        _error "Make sure /etc/ssl/private/fullchain.pem and /etc/ssl/private/privkey.pem are mounted in the Docker container and exist!"
        exit 1
      else
        _info "Required files /etc/ssl/private/fullchain.pem and /etc/ssl/private/privkey.pem exists."
      fi
      if grep -q "443" /etc/nginx/conf.d/dsmr-webinterface.conf; then
        _info "SSL has already been enabled..."
      else
        sed -i '/listen\s*80/r '<(cat <<- END_HEREDOC
        listen 443 ssl;
        ssl_certificate /etc/ssl/private/fullchain.pem;
        ssl_certificate_key /etc/ssl/private/privkey.pem;
END_HEREDOC
        ) /etc/nginx/conf.d/dsmr-webinterface.conf
      fi
      if nginx -c /etc/nginx/nginx.conf -t 2>/dev/null; then
        _info "NGINX SSL configured and enabled"
        return
      else
        _error "NGINX configuration error"
        exit 1
      fi
    fi
  fi
  _info "ENABLE_NGINX_SSL is disabled, nothing to see here. Continuing..."
}

function _generate_auth_configuration() {
  _info "Checking for HTTP AUTHENTICATION configuration..."
  if [[ -n "${ENABLE_HTTP_AUTH}" ]]; then
    if [[ "${ENABLE_HTTP_AUTH}" = true ]] ; then
      _info "ENABLE_HTTP_AUTH is enabled, let's secure this!"
      canWeContinue=true
      if [[ -z "${HTTP_AUTH_USERNAME}" ]]; then
        _warn "Please provide a HTTP_AUTH_USERNAME"
        canWeContinue=false
      fi
      if [[ -z "${HTTP_AUTH_PASSWORD}" ]]; then
        _warn "Please provide a HTTP_AUTH_PASSWORD"
        canWeContinue=false
      fi
      if [[ "${canWeContinue}" = false ]] ; then
        _error "Cannot generate a valid .htpasswd file, please check above warnings."
        exit 1
      fi
      _info "Generating htpasswd..."
	    HTTP_AUTH_CRYPT_PASSWORD=$(openssl passwd -apr1 "${HTTP_AUTH_PASSWORD}")
    	printf "%s:%s\n" "${HTTP_AUTH_USERNAME}" "${HTTP_AUTH_CRYPT_PASSWORD}" > /etc/nginx/htpasswd
      _info "Done! Enabling the configuration in NGINX..."
      sed -i "s/##    auth_basic/    auth_basic/" /etc/nginx/conf.d/dsmr-webinterface.conf
      if nginx -c /etc/nginx/nginx.conf -t 2>/dev/null; then
        _info "HTTP AUTHENTICATION configured and enabled"
        return
      else
        _error "NGINX configuration error"
        exit 1
      fi
    fi
  fi
  _info "ENABLE_HTTP_AUTH is disabled, nothing to see here. Continuing..."
}

#---------------------------------------------------------------------------------------------------------------------------
# MAIN
#---------------------------------------------------------------------------------------------------------------------------
[[ "${DEBUG}" = true ]] && set -o xtrace

_pre_reqs
_check_db_availability
_run_post_config
_nginx_ssl_configuration
_generate_auth_configuration
