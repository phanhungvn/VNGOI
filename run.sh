#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================================
# VNGOJ / VNGOI one-click installer and deployer
# Target: Ubuntu/Debian VPS, Docker Compose, MariaDB, Redis, Gunicorn, Nginx
# Repository: https://github.com/phanhungvn/VNGOI
#
# Examples:
#   chmod +x vngoj.sh
#   sudo ./vngoj.sh --force
#
#   sudo ./vngoj.sh \
#     --domain oj.example.com \
#     --admin-user admin \
#     --admin-email admin@example.com \
#     --admin-password 'StrongPassword123!' \
#     --force
#
#   sudo ./vngoj.sh --source-zip '/root/OJ-master(1).zip' --force
# ============================================================================

REPO_URL="${REPO_URL:-https://github.com/phanhungvn/VNGOI.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/vngoi}"
DOMAIN="${DOMAIN:-_}"
HTTP_PORT="${HTTP_PORT:-80}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SITE_NAME="${SITE_NAME:-VNGOI Online Judge}"
TIME_ZONE="${TIME_ZONE:-Asia/Ho_Chi_Minh}"
BRANCH="${BRANCH:-main}"
SOURCE_ZIP="${SOURCE_ZIP:-}"
FORCE_REINSTALL=0
DOMAIN_EXPLICIT=0
PORT_EXPLICIT=0
SITE_NAME_EXPLICIT=0
TIME_ZONE_EXPLICIT=0
ADMIN_USER_EXPLICIT=0
ADMIN_EMAIL_EXPLICIT=0
ADMIN_PASSWORD_EXPLICIT=0
LOG_FILE="${LOG_FILE:-/var/log/vngoj-deploy.log}"

usage() {
  cat <<EOF
Usage: sudo bash $0 [options]

Options:
  --domain DOMAIN          Domain/IP for Django and Nginx; default allows all
  --port PORT              Public HTTP port (default: 80)
  --install-dir PATH       Install directory (default: /opt/vngoi)
  --branch NAME            Git branch/tag (default: main)
  --source-zip PATH        Use a local .zip/.tar archive instead of GitHub
  --site-name NAME         Website name (default: VNGOI Online Judge)
  --timezone TZ            Timezone (default: Asia/Ho_Chi_Minh)
  --admin-user USER        Admin username (default: admin)
  --admin-email EMAIL      Admin email (default: admin@localhost)
  --admin-password PASS    Admin password; random when omitted
  --force                  Regenerate source/config/image; keeps database data
  -h, --help               Show help

Examples:
  sudo bash $0 --force
  sudo bash $0 --domain oj.example.com --force
  sudo bash $0 --source-zip '/root/OJ-master(1).zip' --force
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:?Missing value for --domain}"; DOMAIN_EXPLICIT=1; shift 2 ;;
    --port) HTTP_PORT="${2:?Missing value for --port}"; PORT_EXPLICIT=1; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:?Missing value for --install-dir}"; shift 2 ;;
    --branch) BRANCH="${2:?Missing value for --branch}"; shift 2 ;;
    --source-zip) SOURCE_ZIP="${2:?Missing value for --source-zip}"; shift 2 ;;
    --site-name) SITE_NAME="${2:?Missing value for --site-name}"; SITE_NAME_EXPLICIT=1; shift 2 ;;
    --timezone) TIME_ZONE="${2:?Missing value for --timezone}"; TIME_ZONE_EXPLICIT=1; shift 2 ;;
    --admin-user) ADMIN_USER="${2:?Missing value for --admin-user}"; ADMIN_USER_EXPLICIT=1; shift 2 ;;
    --admin-email) ADMIN_EMAIL="${2:?Missing value for --admin-email}"; ADMIN_EMAIL_EXPLICIT=1; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2:?Missing value for --admin-password}"; ADMIN_PASSWORD_EXPLICIT=1; shift 2 ;;
    --force) FORCE_REINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ${EUID} -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash $0" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

CURRENT_STEP="initialization"
on_error() {
  local rc=$?
  echo >&2
  echo "[ERROR] Deployment stopped" >&2
  echo "        Step: $CURRENT_STEP" >&2
  echo "        Line: $1" >&2
  echo "        Exit: $rc" >&2
  echo "        Log:  $LOG_FILE" >&2
  exit "$rc"
}
trap 'on_error $LINENO' ERR

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fatal() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

rand_hex() {
  openssl rand -hex "$1"
}

rand_password() {
  # Alphanumeric only, safe for Docker env files and shell tooling.
  python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(30)))
PY
}

env_quote() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1], ensure_ascii=False))
PY
}

read_env_value() {
  local key="$1" file="$2"
  python3 - "$key" "$file" <<'PY'
import ast
import sys
from pathlib import Path
key, filename = sys.argv[1], sys.argv[2]
for raw in Path(filename).read_text(encoding='utf-8').splitlines():
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, value = line.split('=', 1)
    if k.strip() != key:
        continue
    value = value.strip()
    if value[:1] in ('"', "'"):
        try:
            value = ast.literal_eval(value)
        except Exception:
            value = value.strip('"\'')
    print(value)
    break
PY
}

validate_inputs() {
  CURRENT_STEP="validating parameters"

  [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || fatal "Invalid HTTP port: $HTTP_PORT"
  (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 )) || fatal "Port must be from 1 to 65535"

  [[ "$ADMIN_USER" =~ ^[A-Za-z0-9_@.+-]+$ ]] || \
    fatal "Invalid Django admin username: $ADMIN_USER"

  [[ "$DOMAIN" != http://* && "$DOMAIN" != https://* ]] || \
    fatal "Use hostname/IP only for --domain, without http:// or https://"

  [[ -z "$SOURCE_ZIP" || -f "$SOURCE_ZIP" ]] || \
    fatal "Source archive not found: $SOURCE_ZIP"
}

wait_for_apt() {
  local waited=0 max_wait=900
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/cache/apt/archives/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if (( waited >= max_wait )); then
      fatal "apt/dpkg remained locked for ${max_wait}s"
    fi
    warn "apt/dpkg is busy; waiting 10s... (${waited}/${max_wait}s)"
    sleep 10
    waited=$((waited + 10))
  done
}

ensure_swap_if_needed() {
  CURRENT_STEP="checking available memory"
  local mem_kb swap_kb total_kb swapfile
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
  total_kb=$((mem_kb + swap_kb))
  swapfile="/var/swap-vngoj"

  # Docker image builds may fail on very small VPS instances.
  if (( total_kb < 2000000 )) && [[ ! -f "$swapfile" ]]; then
    log "Low memory detected; creating a 2 GB swap file"
    if command -v fallocate >/dev/null 2>&1; then
      fallocate -l 2G "$swapfile"
    else
      dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=progress
    fi
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null
    swapon "$swapfile"
    grep -qF "$swapfile none swap sw 0 0" /etc/fstab || \
      echo "$swapfile none swap sw 0 0" >> /etc/fstab
  fi
}

install_dependencies() {
  CURRENT_STEP="installing system packages and Docker"
  export DEBIAN_FRONTEND=noninteractive

  log "Installing required system packages"
  wait_for_apt
  apt-get update -y
  wait_for_apt
  apt-get install -y --no-install-recommends \
    ca-certificates curl git openssl gnupg lsb-release unzip tar rsync \
    python3 python3-minimal jq

  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Engine"
    install -m 0755 -d /etc/apt/keyrings

    . /etc/os-release
    local docker_os="$ID"
    case "$docker_os" in
      ubuntu|debian) ;;
      *) fatal "Unsupported OS for automatic Docker installation: $docker_os" ;;
    esac

    curl -fsSL "https://download.docker.com/linux/${docker_os}/gpg" \
      | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_os} ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    wait_for_apt
    apt-get update -y
    wait_for_apt
    apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  elif ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Compose plugin"
    wait_for_apt
    apt-get install -y docker-compose-plugin
  fi

  systemctl enable --now docker
  docker info >/dev/null
  docker compose version

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    log "Opening HTTP port ${HTTP_PORT} in UFW"
    ufw allow "${HTTP_PORT}/tcp" >/dev/null
  fi
}

source_is_valid() {
  local dir="$1"
  [[ -f "$dir/manage.py" \
    && -f "$dir/dmoj/settings.py" \
    && -f "$dir/dmoj/wsgi.py" \
    && -d "$dir/judge" \
    && -d "$dir/templates" \
    && -d "$dir/resources" ]]
}

find_project_root() {
  local base="$1" manage root

  if source_is_valid "$base"; then
    printf '%s\n' "$base"
    return 0
  fi

  while IFS= read -r manage; do
    root="${manage%/manage.py}"
    if source_is_valid "$root"; then
      printf '%s\n' "$root"
      return 0
    fi
  done < <(find "$base" -mindepth 1 -maxdepth 8 -type f -name manage.py -print 2>/dev/null)

  return 1
}

extract_archive() {
  local archive="$1" destination="$2"
  mkdir -p "$destination"

  case "${archive,,}" in
    *.zip) unzip -q -o "$archive" -d "$destination" ;;
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$destination" ;;
    *.tar.xz|*.txz) tar -xJf "$archive" -C "$destination" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$destination" ;;
    *.tar) tar -xf "$archive" -C "$destination" ;;
    *) return 1 ;;
  esac
}

clone_or_refresh_repo() {
  local destination="$1"

  if [[ -d "$destination/.git" ]]; then
    log "Refreshing repository checkout"
    git -C "$destination" fetch --all --tags --prune
    if git -C "$destination" rev-parse --verify "origin/${BRANCH}" >/dev/null 2>&1; then
      git -C "$destination" reset --hard "origin/${BRANCH}"
    else
      git -C "$destination" reset --hard origin/HEAD
    fi
    git -C "$destination" clean -fdx
  else
    rm -rf "$destination"
    if ! git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$destination"; then
      warn "Branch '$BRANCH' was unavailable; cloning repository default branch"
      rm -rf "$destination"
      git clone --depth 1 "$REPO_URL" "$destination"
    fi
  fi
}

hydrate_frontend_assets() {
  local app_dir="$1"
  CURRENT_STEP="downloading frontend static assets"

  # ZIP snapshots often contain empty Git submodule directories. The home page
  # requires these assets, especially resources/libs/fontawesome/.
  if [[ ! -f "$app_dir/resources/libs/fontawesome/font-awesome.css" ]]; then
    log "Downloading DMOJ site-assets into resources/libs"
    rm -rf "$app_dir/resources/libs"
    git clone --depth 1 --branch master \
      https://github.com/DMOJ/site-assets.git \
      "$app_dir/resources/libs"
    rm -rf "$app_dir/resources/libs/.git"
  fi

  if [[ ! -d "$app_dir/resources/vnoj" ]] \
      || ! find "$app_dir/resources/vnoj" -mindepth 1 -type f -print -quit | grep -q .; then
    log "Downloading VNOJ static assets into resources/vnoj"
    rm -rf "$app_dir/resources/vnoj"
    git clone --depth 1 \
      https://github.com/VNOI-Admin/vnoj-static.git \
      "$app_dir/resources/vnoj"
    rm -rf "$app_dir/resources/vnoj/.git"
  fi

  [[ -f "$app_dir/resources/libs/fontawesome/font-awesome.css" ]] || \
    fatal "Missing resources/libs/fontawesome/font-awesome.css after asset download"
  [[ -f "$app_dir/resources/libs/jquery-3.4.1.min.js" ]] || \
    fatal "Missing resources/libs/jquery-3.4.1.min.js after asset download"
}

prepare_source() {
  CURRENT_STEP="preparing application source"
  log "Preparing source code in $INSTALL_DIR/app"
  mkdir -p "$INSTALL_DIR"

  local stage="$INSTALL_DIR/.source-stage"
  local repository="$INSTALL_DIR/repository"
  local project_root=""
  local archive extracted count=0

  rm -rf "$stage"
  mkdir -p "$stage"

  if [[ -n "$SOURCE_ZIP" ]]; then
    log "Using local source archive: $SOURCE_ZIP"
    extract_archive "$SOURCE_ZIP" "$stage/local" || \
      fatal "Unsupported or invalid source archive: $SOURCE_ZIP"
    project_root="$(find_project_root "$stage/local" || true)"
  else
    log "Downloading source container from $REPO_URL"
    clone_or_refresh_repo "$repository"

    project_root="$(find_project_root "$repository" || true)"

    # The specified GitHub repository may store the actual project in an
    # uploaded archive rather than at repository root.
    if [[ -z "$project_root" ]]; then
      while IFS= read -r archive; do
        count=$((count + 1))
        extracted="$stage/archive-${count}"
        log "Inspecting embedded archive: ${archive#$repository/}"
        if extract_archive "$archive" "$extracted"; then
          project_root="$(find_project_root "$extracted" || true)"
          [[ -n "$project_root" ]] && break
        fi
      done < <(
        find "$repository" -maxdepth 5 -type f \
          \( -iname '*.zip' -o -iname '*.tar' -o -iname '*.tar.gz' \
             -o -iname '*.tgz' -o -iname '*.tar.xz' -o -iname '*.txz' \
             -o -iname '*.tar.bz2' -o -iname '*.tbz2' \) -print
      )
    fi
  fi

  [[ -n "$project_root" ]] || \
    fatal "Could not find a complete VNGOI source tree (manage.py, dmoj/, judge/, templates/, resources/)"
  source_is_valid "$project_root" || fatal "Detected source tree is incomplete: $project_root"

  log "Found application source: $project_root"
  rm -rf "$INSTALL_DIR/app.new"
  mkdir -p "$INSTALL_DIR/app.new"
  rsync -a --delete \
    --exclude='.git' \
    --exclude='__MACOSX' \
    --exclude='.DS_Store' \
    --exclude='*:Zone.Identifier' \
    "$project_root/" "$INSTALL_DIR/app.new/"

  hydrate_frontend_assets "$INSTALL_DIR/app.new"
  source_is_valid "$INSTALL_DIR/app.new" || fatal "Source copy validation failed"

  if [[ -d "$INSTALL_DIR/app" ]]; then
    rm -rf "$INSTALL_DIR/app.previous"
    mv "$INSTALL_DIR/app" "$INSTALL_DIR/app.previous"
  fi
  mv "$INSTALL_DIR/app.new" "$INSTALL_DIR/app"
  rm -rf "$stage"

  log "Application source prepared successfully"
}

write_environment() {
  CURRENT_STEP="writing credentials and environment"
  local django_secret db_root db_password event_key submission_key
  local old

  if [[ -f "$INSTALL_DIR/.env" ]]; then
    log "Preserving existing database credentials and Django secrets"

    old="$(read_env_value HTTP_PORT "$INSTALL_DIR/.env")"
    [[ $PORT_EXPLICIT -eq 1 || -z "$old" ]] || HTTP_PORT="$old"

    old="$(read_env_value DOMAIN "$INSTALL_DIR/.env")"
    [[ $DOMAIN_EXPLICIT -eq 1 || -z "$old" ]] || DOMAIN="$old"

    old="$(read_env_value SITE_NAME "$INSTALL_DIR/.env")"
    [[ $SITE_NAME_EXPLICIT -eq 1 || -z "$old" ]] || SITE_NAME="$old"

    old="$(read_env_value TIME_ZONE "$INSTALL_DIR/.env")"
    [[ $TIME_ZONE_EXPLICIT -eq 1 || -z "$old" ]] || TIME_ZONE="$old"

    old="$(read_env_value DJANGO_ADMIN_USER "$INSTALL_DIR/.env")"
    [[ $ADMIN_USER_EXPLICIT -eq 1 || -z "$old" ]] || ADMIN_USER="$old"

    old="$(read_env_value DJANGO_ADMIN_EMAIL "$INSTALL_DIR/.env")"
    [[ $ADMIN_EMAIL_EXPLICIT -eq 1 || -z "$old" ]] || ADMIN_EMAIL="$old"

    old="$(read_env_value DJANGO_ADMIN_PASSWORD "$INSTALL_DIR/.env")"
    [[ $ADMIN_PASSWORD_EXPLICIT -eq 1 || -z "$old" ]] || ADMIN_PASSWORD="$old"

    django_secret="$(read_env_value DJANGO_SECRET_KEY "$INSTALL_DIR/.env")"
    db_root="$(read_env_value DB_ROOT_PASSWORD "$INSTALL_DIR/.env")"
    db_password="$(read_env_value DB_PASSWORD "$INSTALL_DIR/.env")"
    event_key="$(read_env_value EVENT_DAEMON_KEY "$INSTALL_DIR/.env")"
    submission_key="$(read_env_value EVENT_DAEMON_SUBMISSION_KEY "$INSTALL_DIR/.env")"
  else
    django_secret=""
    db_root=""
    db_password=""
    event_key=""
    submission_key=""
  fi

  [[ -n "$django_secret" ]] || django_secret="$(rand_hex 48)"
  [[ -n "$db_root" ]] || db_root="$(rand_password)"
  [[ -n "$db_password" ]] || db_password="$(rand_password)"
  [[ -n "$event_key" ]] || event_key="$(rand_hex 48)"
  [[ -n "$submission_key" ]] || submission_key="$(rand_hex 48)"
  [[ -n "$ADMIN_PASSWORD" ]] || ADMIN_PASSWORD="$(rand_password)"

  cat > "$INSTALL_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=vngoi
HTTP_PORT=$(env_quote "$HTTP_PORT")
DOMAIN=$(env_quote "$DOMAIN")
SITE_NAME=$(env_quote "$SITE_NAME")
TIME_ZONE=$(env_quote "$TIME_ZONE")
DJANGO_SETTINGS_MODULE="dmoj.settings"
DJANGO_SECRET_KEY=$(env_quote "$django_secret")
DB_NAME="vngoi"
DB_USER="vngoi"
DB_PASSWORD=$(env_quote "$db_password")
DB_ROOT_PASSWORD=$(env_quote "$db_root")
DJANGO_ADMIN_USER=$(env_quote "$ADMIN_USER")
DJANGO_ADMIN_EMAIL=$(env_quote "$ADMIN_EMAIL")
DJANGO_ADMIN_PASSWORD=$(env_quote "$ADMIN_PASSWORD")
EVENT_DAEMON_KEY=$(env_quote "$event_key")
EVENT_DAEMON_SUBMISSION_KEY=$(env_quote "$submission_key")
EOF
  chmod 600 "$INSTALL_DIR/.env"
}

write_django_settings() {
  CURRENT_STEP="writing Django settings"

  cat > "$INSTALL_DIR/app/dmoj/local_settings.py" <<'PY'
import os

SECRET_KEY = os.environ['DJANGO_SECRET_KEY']
DEBUG = False

# Allow direct IP, hostname and Cloudflare proxy access. Restrict this list to
# specific production hostnames later if desired.
ALLOWED_HOSTS = ['*']

_domain = os.environ.get('DOMAIN', '_').strip()
CSRF_TRUSTED_ORIGINS = []
if _domain not in ('', '_', '*'):
    CSRF_TRUSTED_ORIGINS = [f'http://{_domain}', f'https://{_domain}']

SITE_ID = 1
SITE_NAME = os.environ.get('SITE_NAME', 'VNGOI Online Judge')
TIME_ZONE = os.environ.get('TIME_ZONE', 'Asia/Ho_Chi_Minh')
DEFAULT_USER_TIME_ZONE = TIME_ZONE
LANGUAGE_CODE = 'vi'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.environ.get('DB_NAME', 'vngoi'),
        'USER': os.environ.get('DB_USER', 'vngoi'),
        'PASSWORD': os.environ['DB_PASSWORD'],
        'HOST': os.environ.get('DB_HOST', 'db'),
        'PORT': os.environ.get('DB_PORT', '3306'),
        'OPTIONS': {
            'charset': 'utf8mb4',
            'init_command': "SET sql_mode='STRICT_TRANS_TABLES'",
        },
    }
}

CACHES = {
    'default': {
        'BACKEND': 'django_redis.cache.RedisCache',
        'LOCATION': 'redis://redis:6379/1',
        'OPTIONS': {'CLIENT_CLASS': 'django_redis.client.DefaultClient'},
    }
}
SESSION_ENGINE = 'django.contrib.sessions.backends.cached_db'

CELERY_BROKER_URL = 'redis://redis:6379/2'
CELERY_RESULT_BACKEND = 'redis://redis:6379/3'
CELERY_BROKER_URL_SECRET = CELERY_BROKER_URL

STATIC_ROOT = '/vol/static'
MEDIA_ROOT = '/vol/media'
DMOJ_PROBLEM_DATA_ROOT = '/vol/problems'

# Required by django-compressor when staticfiles is enabled.
STATICFILES_FINDERS = tuple(dict.fromkeys(
    tuple(STATICFILES_FINDERS) + ('compressor.finders.CompressorFinder',)
))
COMPRESS_ROOT = STATIC_ROOT
COMPRESS_ENABLED = True
COMPRESS_OFFLINE = False

# inlinei18n() reads generated files from this exact location.
STATICI18N_ROOT = STATIC_ROOT
STATICI18N_OUTPUT_DIR = 'jsi18n'

EVENT_DAEMON_USE = False
EVENT_DAEMON_KEY = os.environ.get('EVENT_DAEMON_KEY')
EVENT_DAEMON_SUBMISSION_KEY = os.environ.get('EVENT_DAEMON_SUBMISSION_KEY')
ENABLE_FTS = False

SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
USE_X_FORWARDED_HOST = True
SECURE_SSL_REDIRECT = False
PY
}

write_dockerfile() {
  CURRENT_STEP="writing Docker image definition"

  cat > "$INSTALL_DIR/app/Dockerfile" <<'DOCKERFILE'
FROM python:3.10-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DJANGO_SETTINGS_MODULE=dmoj.settings

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    default-libmysqlclient-dev \
    pkg-config \
    libxml2-dev \
    libxslt1-dev \
    libffi-dev \
    libssl-dev \
    libjpeg62-turbo-dev \
    zlib1g-dev \
    libfreetype6-dev \
    gettext \
    git \
    curl \
    nodejs \
    npm \
    mariadb-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt additional_requirements.txt ./
RUN python -m pip install --upgrade pip setuptools wheel \
    && pip install --no-cache-dir -r requirements.txt \
    && if [ -s additional_requirements.txt ]; then \
         pip install --no-cache-dir -r additional_requirements.txt; \
       fi \
    && pip install --no-cache-dir gunicorn

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

RUN test -f resources/libs/fontawesome/font-awesome.css \
    && test -f resources/libs/jquery-3.4.1.min.js \
    && chmod +x make_style.sh \
    && ./make_style.sh

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["gunicorn", "dmoj.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "2", "--threads", "2", "--worker-class", "gthread", "--timeout", "120", "--access-logfile", "-", "--error-logfile", "-"]
DOCKERFILE
}

write_entrypoint() {
  CURRENT_STEP="writing container startup script"

  cat > "$INSTALL_DIR/app/docker-entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -Eeuo pipefail

export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-dmoj.settings}"

wait_for_mariadb() {
  echo "Waiting for MariaDB..."
  local count=0
  until mariadb-admin ping \
      -h "${DB_HOST:-db}" \
      -P "${DB_PORT:-3306}" \
      -u"${DB_USER}" \
      -p"${DB_PASSWORD}" \
      --silent >/dev/null 2>&1; do
    count=$((count + 1))
    if (( count >= 120 )); then
      echo "MariaDB was not ready after 6 minutes" >&2
      exit 1
    fi
    sleep 3
  done
  echo "MariaDB is ready"
}

prepare_django() {
  python manage.py migrate --noinput

  # Compile gettext catalogs before generating JavaScript i18n catalogs.
  python manage.py compilemessages || true

  python manage.py collectstatic --noinput

  # Fixes: /vol/static/jsi18n/vi/djangojs.js not found.
  mkdir -p /vol/static/jsi18n
  python manage.py compilejsi18n --output /vol/static/jsi18n

  # Fail early when the two previously missing static resources are absent.
  test -f /vol/static/libs/fontawesome/font-awesome.css
  test -f /vol/static/jsi18n/vi/djangojs.js

  python manage.py shell <<'PY'
import os
from django.contrib.auth import get_user_model
from django.contrib.sites.models import Site
from judge.models import Profile

User = get_user_model()
username = os.environ['DJANGO_ADMIN_USER']
email = os.environ['DJANGO_ADMIN_EMAIL']
password = os.environ['DJANGO_ADMIN_PASSWORD']
domain = os.environ.get('DOMAIN', '_').strip()
site_name = os.environ.get('SITE_NAME', 'VNGOI Online Judge')

if domain in ('', '_', '*'):
    domain = 'localhost'

Site.objects.update_or_create(
    id=1,
    defaults={'domain': domain, 'name': site_name},
)

user, created = User.objects.get_or_create(
    username=username,
    defaults={'email': email},
)
user.email = email
user.is_staff = True
user.is_superuser = True
user.is_active = True
user.set_password(password)
user.save()
Profile.objects.get_or_create(user=user)

print(('Created' if created else 'Updated') + f' administrator: {username}')
print(f'Updated Django site: {domain}')
PY

  python manage.py shell -c \
    "from django.core.cache import cache; cache.clear(); print('Django cache cleared')"
}

wait_for_mariadb

if [[ "${1:-}" == "gunicorn" ]]; then
  prepare_django
fi

exec "$@"
ENTRYPOINT

  chmod +x "$INSTALL_DIR/app/docker-entrypoint.sh"
}

write_compose() {
  CURRENT_STEP="writing Docker Compose services"

  mkdir -p "$INSTALL_DIR"/{nginx,data/{mysql,redis,media,static,problems},backups}

  cat > "$INSTALL_DIR/docker-compose.yml" <<'COMPOSE'
services:
  db:
    image: mariadb:10.11
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: ${DB_NAME}
      MARIADB_USER: ${DB_USER}
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      TZ: ${TIME_ZONE}
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --max-allowed-packet=64M
    volumes:
      - ./data/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 30

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 20

  web:
    build: ./app
    restart: unless-stopped
    env_file: .env
    environment:
      DJANGO_SETTINGS_MODULE: dmoj.settings
      DB_HOST: db
      DB_PORT: 3306
    command:
      - gunicorn
      - dmoj.wsgi:application
      - --bind
      - 0.0.0.0:8000
      - --workers
      - "2"
      - --threads
      - "2"
      - --worker-class
      - gthread
      - --timeout
      - "120"
      - --access-logfile
      - "-"
      - --error-logfile
      - "-"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ./data/static:/vol/static
      - ./data/media:/vol/media
      - ./data/problems:/vol/problems
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8000/admin/login/ >/dev/null || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 90s

  celery:
    build: ./app
    restart: unless-stopped
    command: celery -A dmoj worker -l INFO --concurrency=2
    env_file: .env
    environment:
      DJANGO_SETTINGS_MODULE: dmoj.settings
      DB_HOST: db
      DB_PORT: 3306
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
      web:
        condition: service_healthy
    volumes:
      - ./data/media:/vol/media
      - ./data/problems:/vol/problems

  nginx:
    image: nginx:1.27-alpine
    restart: unless-stopped
    ports:
      - "${HTTP_PORT}:80"
    depends_on:
      web:
        condition: service_healthy
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./data/static:/vol/static:ro
      - ./data/media:/vol/media:ro
COMPOSE
}

write_nginx() {
  CURRENT_STEP="writing Nginx configuration"

  cat > "$INSTALL_DIR/nginx/default.conf" <<'NGINX'
map $http_x_forwarded_proto $vngoj_forwarded_proto {
    default $http_x_forwarded_proto;
    ""      $scheme;
}

upstream vngoj_web {
    server web:8000;
    keepalive 16;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 100m;

    location /static/ {
        alias /vol/static/;
        access_log off;
        expires 7d;
        add_header Cache-Control "public, max-age=604800";
    }

    location /media/ {
        alias /vol/media/;
        expires 7d;
    }

    location / {
        proxy_pass http://vngoj_web;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $vngoj_forwarded_proto;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Connection "";
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}
NGINX
}

write_management_script() {
  CURRENT_STEP="writing management helper"

  cat > "$INSTALL_DIR/manage.sh" <<'MANAGE'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  start)
    docker compose up -d
    ;;
  stop)
    docker compose down
    ;;
  restart)
    docker compose restart
    ;;
  rebuild)
    docker compose build --no-cache web celery
    docker compose up -d --force-recreate
    ;;
  status)
    docker compose ps
    ;;
  check)
    docker compose ps
    echo
    curl -I --max-time 15 http://127.0.0.1:"$(grep '^HTTP_PORT=' .env | cut -d= -f2- | tr -d '"')"/
    ;;
  logs)
    docker compose logs -f --tail=200 "${2:-web}"
    ;;
  shell)
    docker compose exec web python manage.py shell
    ;;
  admin-reset)
    docker compose exec web python manage.py shell -c \
      "import os; from django.contrib.auth import get_user_model; u=get_user_model().objects.get(username=os.environ['DJANGO_ADMIN_USER']); u.set_password(os.environ['DJANGO_ADMIN_PASSWORD']); u.is_staff=True; u.is_superuser=True; u.is_active=True; u.save(); print('Admin password reset')"
    ;;
  static-fix)
    docker compose exec web python manage.py collectstatic --noinput
    docker compose exec web python manage.py compilejsi18n --output /vol/static/jsi18n
    docker compose exec web python manage.py shell -c \
      "from django.core.cache import cache; cache.clear(); print('Cache cleared')"
    docker compose restart web nginx
    ;;
  backup)
    mkdir -p backups
    stamp="$(date +%Y%m%d-%H%M%S)"
    db_name="$(grep '^DB_NAME=' .env | cut -d= -f2- | tr -d '"')"
    db_root="$(grep '^DB_ROOT_PASSWORD=' .env | cut -d= -f2- | tr -d '"')"
    docker compose exec -T db mariadb-dump -uroot -p"$db_root" "$db_name" \
      | gzip > "backups/db-$stamp.sql.gz"
    tar -czf "backups/files-$stamp.tar.gz" data/media data/problems .env
    echo "Backup created: backups/*-$stamp.*"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|rebuild|status|check|logs [service]|shell|admin-reset|static-fix|backup}"
    exit 2
    ;;
esac
MANAGE

  chmod +x "$INSTALL_DIR/manage.sh"
}

write_all_files() {
  CURRENT_STEP="generating deployment configuration"
  log "Generating Docker, Django, Nginx and startup configuration"

  [[ -f "$INSTALL_DIR/app/manage.py" ]] || fatal "Application source is missing"

  write_environment
  write_django_settings
  write_dockerfile
  write_entrypoint
  write_compose
  write_nginx
  write_management_script

  chown -R root:root "$INSTALL_DIR"
  chmod 600 "$INSTALL_DIR/.env"
}

validate_generated_config() {
  CURRENT_STEP="validating generated configuration"
  cd "$INSTALL_DIR"
  docker compose config >/dev/null
  bash -n "$INSTALL_DIR/app/docker-entrypoint.sh"
  bash -n "$INSTALL_DIR/manage.sh"

  grep -q "compressor.finders.CompressorFinder" "$INSTALL_DIR/app/dmoj/local_settings.py"
  grep -q "compilejsi18n" "$INSTALL_DIR/app/docker-entrypoint.sh"
  grep -q "worker-class" "$INSTALL_DIR/docker-compose.yml"
}

show_failure_diagnostics() {
  cd "$INSTALL_DIR" || return 0
  echo >&2
  echo "================ DEPLOY DIAGNOSTICS ================" >&2
  docker compose ps -a >&2 || true
  echo >&2
  docker compose logs --tail=180 web nginx >&2 || true
  echo "====================================================" >&2
}

deploy_services() {
  CURRENT_STEP="building and starting Docker services"
  cd "$INSTALL_DIR"

  log "Building VNGOJ Docker images"
  docker compose down --remove-orphans || true
  docker compose build --pull web celery

  log "Starting database and Redis"
  docker compose up -d db redis

  log "Starting web, Celery and Nginx"
  docker compose up -d web celery nginx

  log "Waiting for the website to become ready"
  local attempt status
  for attempt in $(seq 1 120); do
    status="$(curl -sS -o /dev/null -w '%{http_code}' \
      --max-time 10 "http://127.0.0.1:${HTTP_PORT}/" || true)"

    if [[ "$status" =~ ^(200|301|302)$ ]]; then
      log "Website is ready (HTTP $status)"
      docker compose ps
      return 0
    fi

    if (( attempt % 10 == 0 )); then
      echo "Waiting... attempt ${attempt}/120, HTTP=${status:-unreachable}"
      docker compose ps --format table || true
    fi
    sleep 3
  done

  show_failure_diagnostics
  fatal "Website did not return HTTP 200/301/302 after 6 minutes"
}

print_result() {
  CURRENT_STEP="printing deployment result"
  local host address password
  host="$DOMAIN"

  if [[ "$host" == "_" || "$host" == "*" || -z "$host" ]]; then
    host="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$host" ]] || host="SERVER_IP"
  fi

  if [[ "$HTTP_PORT" == "80" ]]; then
    address="http://${host}"
  else
    address="http://${host}:${HTTP_PORT}"
  fi

  password="$(read_env_value DJANGO_ADMIN_PASSWORD "$INSTALL_DIR/.env")"
  ADMIN_USER="$(read_env_value DJANGO_ADMIN_USER "$INSTALL_DIR/.env")"

  cat <<EOF

============================================================
 VNGOJ DEPLOYED SUCCESSFULLY
============================================================
 Website:        $address
 Admin page:     $address/admin/
 Admin user:     $ADMIN_USER
 Admin password: $password
 Install dir:    $INSTALL_DIR
 Credentials:    $INSTALL_DIR/.env
 Deploy log:     $LOG_FILE

 Management commands:
   cd $INSTALL_DIR
   ./manage.sh status
   ./manage.sh check
   ./manage.sh logs web
   ./manage.sh restart
   ./manage.sh rebuild
   ./manage.sh static-fix
   ./manage.sh backup

 Cloudflare:
   1. Point an A record to this VPS IP.
   2. Test with DNS only first.
   3. Current origin serves HTTP on port $HTTP_PORT.
============================================================
Protect $INSTALL_DIR/.env because it contains passwords.
EOF
}

main() {
  validate_inputs
  ensure_swap_if_needed
  install_dependencies
  prepare_source
  write_all_files
  validate_generated_config
  deploy_services
  print_result
}

main "$@"
