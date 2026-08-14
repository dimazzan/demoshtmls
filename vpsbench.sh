#!/usr/bin/env bash
# VPS responsiveness benchmark for Debian 13 / Ubuntu
# Local-only benchmark traffic: CPU/scheduler/crypto/MEM/storage.

set -u
set -o pipefail
export LC_ALL=C
export LANG=C
umask 077

SCRIPT_VERSION="1.6.0"
ITERATIONS="${VPSBENCH_ITERATIONS:-6}"
CYCLIC_SEC="${VPSBENCH_CYCLIC_SEC:-45}"
CRYPTO_SEC="${VPSBENCH_CRYPTO_SEC:-5}"
CPU_SEC="${VPSBENCH_CPU_SEC:-8}"
RAM_SEC="${VPSBENCH_RAM_SEC:-8}"
DISK_SEC="${VPSBENCH_DISK_SEC:-10}"
COOLDOWN_SEC="${VPSBENCH_COOLDOWN_SEC:-5}"
HIST_MAX_US="${VPSBENCH_HIST_MAX_US:-100000}"
FIO_SIZE_MB="${VPSBENCH_FIO_SIZE_MB:-256}"
TASKS_PER_ITER=8
DEBUG_MODE=0
DEBUG_ARCHIVE=""
DEBUG_BUNDLE_CREATED=0
RUN_COMPLETED=0
PROGRESS_ACTIVE=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; RESET=$'\033[0m'; CLR=$'\033[K'
else
    BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""; CLR=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[i]%s %s\n' "$CYAN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

TMP_BASE=""
FIO_FILE=""
STRESS_PID=""
ACTIVE_PID=""
CLEANUP_DONE=0
LOCK_FD=200
LOCK_FILE=""
RUN_BOOT_ID=""
RUN_START_TICKS=""

usage() {
    cat <<'EOF'
Usage: vpsbench.sh [--debug] [--help]

  --debug   Print detailed per-run diagnostics and save a raw .tar.gz bundle.
  --help    Show this help.

Pipe examples:
  curl -fsSL URL | bash
  curl -fsSL URL | bash -s -- --debug
  curl -fsSL URL | sudo bash -s -- --debug
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --debug) DEBUG_MODE=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
}

collect_process_tree() {
    local root="$1" child
    [[ "$root" =~ ^[0-9]+$ && -r "/proc/$root/task/$root/children" ]] || return 0
    for child in $(cat "/proc/$root/task/$root/children" 2>/dev/null); do
        collect_process_tree "$child"
    done
    printf '%s\n' "$root"
}

terminate_pid() {
    local pid="${1:-}" p n
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0

    local pids=()
    mapfile -t pids < <(collect_process_tree "$pid")
    ((${#pids[@]})) || pids=("$pid")

    # Signal leaves first, parent last. This prevents workers from being orphaned.
    for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    for n in 1 2 3 4; do
        local alive=0
        for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
        (( alive == 0 )) && break
        sleep 0.25 200>&-
    done
    for p in "${pids[@]}"; do
        kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
    done
    wait "$pid" 2>/dev/null || true
}

record_pid_state() {
    local file="$1" pid="$2" ticks uid
    [[ -n "${TMP_BASE:-}" && -d "$TMP_BASE" && "$pid" =~ ^[0-9]+$ ]] || return 0
    ticks="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
    uid="$(awk '/^Uid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
    [[ "$ticks" =~ ^[0-9]+$ && "$uid" =~ ^[0-9]+$ ]] || return 0
    printf '%s %s %s %s\n' "$pid" "$RUN_BOOT_ID" "$ticks" "$uid" >"$file"
}

terminate_recorded_pid() {
    local file="$1" pid boot ticks uid current_ticks current_uid
    [[ -r "$file" ]] || return 0
    read -r pid boot ticks uid <"$file" || return 0
    [[ "$pid" =~ ^[0-9]+$ && "$ticks" =~ ^[0-9]+$ && "$uid" =~ ^[0-9]+$ ]] || return 0
    [[ "$boot" == "$RUN_BOOT_ID" && -r "/proc/$pid/stat" ]] || return 0
    current_ticks="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
    current_uid="$(awk '/^Uid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
    [[ "$current_ticks" == "$ticks" && "$current_uid" == "$uid" && "$uid" == "$EUID" ]] || return 0
    terminate_pid "$pid"
}

cleanup() {
    (( CLEANUP_DONE == 0 )) || return 0
    CLEANUP_DONE=1

    terminate_pid "${ACTIVE_PID:-}"
    ACTIVE_PID=""
    [[ -n "${TMP_BASE:-}" ]] && rm -f -- "$TMP_BASE/.active-pid" 2>/dev/null || true
    terminate_pid "${STRESS_PID:-}"
    STRESS_PID=""
    [[ -n "${TMP_BASE:-}" ]] && rm -f -- "$TMP_BASE/.stress-pid" 2>/dev/null || true

    if (( DEBUG_MODE == 1 && DEBUG_BUNDLE_CREATED == 0 )) && [[ -n "${TMP_BASE:-}" && -d "$TMP_BASE" ]]; then
        if create_debug_bundle "partial"; then
            info "Partial raw debug bundle: $DEBUG_ARCHIVE"
        fi
    fi

    [[ -n "${FIO_FILE:-}" ]] && rm -f -- "$FIO_FILE" 2>/dev/null || true
    [[ -n "${TMP_BASE:-}" ]] && rm -rf -- "$TMP_BASE" 2>/dev/null || true
}

on_signal() {
    local name="$1" code="$2"
    warn "Получен сигнал $name; останавливаю активный тест и очищаю временные файлы"
    exit "$code"
}

trap cleanup EXIT
trap 'on_signal HUP 129' HUP
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0

    local lock_dir="" fallback_base=""

    # /run/lock is preferred on regular Linux systems, but WSL and unusual
    # mounts/ACLs may report the directory writable while opening a specific
    # lock file still fails. Treat it as an optimization, never a requirement.
    if [[ -d /run/lock && -w /run/lock ]]; then
        LOCK_FILE="/run/lock/vpsbench.lock"
        if { exec 200>"$LOCK_FILE"; } 2>/dev/null; then
            if flock -w 5 200; then
                return 0
            fi
            die "VPSBench уже запущен на этом сервере (lock занят более 5 секунд)."
        fi
    fi

    # Secure fallback that also works under WSL. Keep it outside HOME so a
    # sudo-run benchmark never creates root-owned files in the invoking user's
    # home directory. The per-UID directory is mode 0700 and its owner is
    # verified before the lock file is opened.
    lock_dir="/tmp/.vpsbench-lock-${EUID}"

    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p -- "$lock_dir" 2>/dev/null || die "Не удалось создать lock-каталог: $lock_dir"
    fi
    chmod 700 "$lock_dir" 2>/dev/null || true

    local lock_owner
    lock_owner="$(stat -c '%u' "$lock_dir" 2>/dev/null || printf unknown)"
    [[ "$lock_owner" == "$EUID" ]] || die "Небезопасный владелец lock-каталога: $lock_dir (uid=$lock_owner)"

    LOCK_FILE="$lock_dir/vpsbench.lock"
    { exec 200>"$LOCK_FILE"; } 2>/dev/null || die "Не удалось открыть fallback lock-файл: $LOCK_FILE"
    if ! flock -w 5 200; then
        die "VPSBench уже запущен на этом сервере (lock занят более 5 секунд)."
    fi

    info "Lock fallback: $LOCK_FILE"
}

cleanup_stale_artifacts() {
    local age_min="${VPSBENCH_STALE_MINUTES:-360}"
    [[ "$age_min" =~ ^[0-9]+$ ]] || age_min=360
    (( age_min >= 60 )) || age_min=60

    local removed=0 path dir owner pid boot ticks live current_ticks user_name
    user_name="$(id -un)"
    RUN_BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)"

    # v1.3+ run directories carry an owner marker. If the exact process no longer
    # exists (or the machine rebooted), their artifacts can be removed immediately.
    while IFS= read -r -d '' path; do
        owner="$path/.vpsbench-owner"
        if [[ -r "$owner" ]]; then
            read -r pid boot ticks <"$owner" || true
            live=0
            if [[ "$pid" =~ ^[0-9]+$ && "$ticks" =~ ^[0-9]+$ && "$boot" == "$RUN_BOOT_ID" && -r "/proc/$pid/stat" ]]; then
                current_ticks="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
                [[ "$current_ticks" == "$ticks" ]] && live=1
            fi
            if (( live == 0 )); then
                terminate_recorded_pid "$path/.active-pid"
                terminate_recorded_pid "$path/.stress-pid"
                for dir in /var/tmp "${HOME:-}" "${VPSBENCH_FIO_DIR:-}"; do
                    [[ -n "$dir" && -d "$dir" ]] || continue
                    find "$dir" -maxdepth 1 -type f -user "$user_name" \
                        \( -name ".vpsbench-fio-${pid}.*" -o -name ".vpsbench-fio-${pid}.bin" \) \
                        -delete 2>/dev/null || true
                done
                rm -rf -- "$path" 2>/dev/null && ((removed+=1)) || true
            fi
        elif find "$path" -maxdepth 0 -mmin "+$age_min" -print -quit 2>/dev/null | grep -q .; then
            # Legacy run directory from versions without owner markers.
            rm -rf -- "$path" 2>/dev/null && ((removed+=1)) || true
        fi
    done < <(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -user "$user_name" -name 'vpsbench.*' -print0 2>/dev/null)

    # Legacy/unassociated fio artifacts are removed only after a conservative age.
    for dir in /var/tmp "${HOME:-}" "${VPSBENCH_FIO_DIR:-}"; do
        [[ -n "$dir" && -d "$dir" && -w "$dir" ]] || continue
        while IFS= read -r -d '' path; do
            rm -f -- "$path" 2>/dev/null && ((removed+=1)) || true
        done < <(find "$dir" -maxdepth 1 -type f -user "$user_name" \
            \( -name '.vpsbench-fio.*' -o -name '.vpsbench-fio-*' \) \
            -mmin "+$age_min" -print0 2>/dev/null)
    done

    (( removed == 0 )) || info "Удалены осиротевшие/старые временные файлы VPSBench: $removed"
}

write_owner_marker() {
    RUN_BOOT_ID="${RUN_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)}"
    RUN_START_TICKS="$(awk '{print $22}' /proc/$$/stat 2>/dev/null || printf 0)"
    printf '%s %s %s\n' "$$" "$RUN_BOOT_ID" "$RUN_START_TICKS" >"$TMP_BASE/.vpsbench-owner"
}

is_num() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

need_cmds=(cyclictest stress-ng sysbench fio openssl jq flock)
declare -A PKG_FOR=(
    [cyclictest]="rt-tests"
    [stress-ng]="stress-ng"
    [sysbench]="sysbench"
    [fio]="fio"
    [openssl]="openssl"
    [jq]="jq"
    [flock]="util-linux"
)

validate_config() {
    local name value min max
    while read -r name value min max; do
        [[ "$value" =~ ^[0-9]+$ ]] || die "$name должен быть целым числом: $value"
        (( value >= min && value <= max )) || die "$name вне безопасного диапазона $min..$max: $value"
    done <<EOF
VPSBENCH_ITERATIONS $ITERATIONS 1 20
VPSBENCH_CYCLIC_SEC $CYCLIC_SEC 5 600
VPSBENCH_CRYPTO_SEC $CRYPTO_SEC 1 60
VPSBENCH_CPU_SEC $CPU_SEC 1 60
VPSBENCH_RAM_SEC $RAM_SEC 1 120
VPSBENCH_DISK_SEC $DISK_SEC 1 120
VPSBENCH_COOLDOWN_SEC $COOLDOWN_SEC 0 120
VPSBENCH_HIST_MAX_US $HIST_MAX_US 10000 1000000
VPSBENCH_FIO_SIZE_MB $FIO_SIZE_MB 64 4096
EOF
}

recover_dpkg_if_needed() {
    command -v dpkg >/dev/null 2>&1 || return 0
    local audit
    audit="$(dpkg --audit 2>&1 || true)"
    [[ -n "$audit" ]] || return 0

    warn "Обнаружено незавершённое состояние dpkg после предыдущей установки/обрыва"
    info "Восстановление: dpkg --configure -a"
    if ! DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
        warn "dpkg --configure -a не завершился; пробую apt-get -f install"
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 \
            -f install -y --no-install-recommends \
            || die "Не удалось восстановить состояние пакетного менеджера"
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
            || die "dpkg остаётся в незавершённом состоянии"
    fi
}

check_os_and_install() {
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release. Поддерживаются Debian/Ubuntu."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "Неподдерживаемая ОС: ${PRETTY_NAME:-${ID:-unknown}}. Нужен Debian/Ubuntu." ;;
    esac

    local missing=() pkgs=() c p found
    for c in "${need_cmds[@]}"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
            p="${PKG_FOR[$c]}"
            found=0
            for x in "${pkgs[@]:-}"; do [[ "$x" == "$p" ]] && found=1; done
            [[ $found -eq 0 ]] && pkgs+=("$p")
        fi
    done

    if ((${#missing[@]})); then
        (( EUID == 0 )) || die "Не хватает: ${missing[*]}. Для автоматической установки запустите скрипт от root."
        info "Не хватает: ${missing[*]}"
        recover_dpkg_if_needed
        info "apt-get update"
        apt-get -o DPkg::Lock::Timeout=60 update -qq || die "apt-get update завершился ошибкой"
        info "apt-get install: ${pkgs[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 install -y -qq --no-install-recommends "${pkgs[@]}" \
            || die "apt-get install завершился ошибкой"
    else
        info "Все зависимости уже установлены"
    fi

    for c in "${need_cmds[@]}"; do command -v "$c" >/dev/null 2>&1 || die "Команда $c всё ещё недоступна"; done
}

cpu_model() {
    awk -F: '/model name|Hardware|Processor/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null
}

isa_short() {
    local flags out=""
    flags="$(awk -F: '/^flags|^Features/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    for f in aes avx2 avx512f sha_ni; do
        if grep -qw "$f" <<<"$flags"; then
            case "$f" in
                aes) out+="AES " ;;
                avx2) out+="AVX2 " ;;
                avx512f) out+="AVX512 " ;;
                sha_ni) out+="SHA-NI " ;;
            esac
        fi
    done
    [[ -n "$out" ]] && printf '%s' "${out% }" || printf '%s' "n/a"
}

prepare_fio_file() {
    local dir="${VPSBENCH_FIO_DIR:-/var/tmp}" fstype avail
    [[ -d "$dir" && -w "$dir" ]] || dir="${HOME:-/root}"
    if command -v findmnt >/dev/null 2>&1; then
        fstype="$(findmnt -n -o FSTYPE --target "$dir" 2>/dev/null || true)"
        if [[ "$fstype" == "tmpfs" || "$fstype" == "ramfs" ]]; then
            warn "$dir расположен на $fstype; для fio переключаюсь на ${HOME:-/root}"
            dir="${HOME:-/root}"
        fi
    fi
    [[ -d "$dir" && -w "$dir" ]] || die "Нет подходящего каталога для временного fio-файла"

    avail="$(df -Pm "$dir" | awk 'NR==2 {print $4}')"
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < FIO_SIZE_MB + 128 )); then
        if (( avail >= 192 )); then
            FIO_SIZE_MB=64
            warn "Мало свободного места; fio-файл уменьшен до 64 MiB"
        else
            die "Недостаточно свободного места для безопасного fio-теста в $dir"
        fi
    fi

    FIO_FILE="$(mktemp "$dir/.vpsbench-fio-$$.XXXXXX")" || die "Не удалось создать временный fio-файл в $dir"
    info "Подготовка fio-файла ${FIO_SIZE_MB} MiB в $dir (не входит в замер)"
    fio --name=prepare --filename="$FIO_FILE" --size="${FIO_SIZE_MB}M" \
        --rw=write --bs=1M --ioengine=sync --direct=1 --end_fsync=1 \
        --output=/dev/null >/dev/null 2>&1 || die "Не удалось подготовить fio-файл"
}

# Weighted benchmark time, used only for terminal progress.
PER_ITER_WORK=$(( CYCLIC_SEC + CRYPTO_SEC * 3 + CPU_SEC + RAM_SEC + DISK_SEC + CYCLIC_SEC ))
TOTAL_WORK=$(( PER_ITER_WORK * ITERATIONS ))
EST_RUNTIME=$(( TOTAL_WORK + COOLDOWN_SEC * (ITERATIONS - 1) + 2 ))
DONE_WORK=0
CURRENT_TASK=0
LAST_VALUE=""

progress_line() {
    local pct="$1" iter="$2" task="$3" name="$4" elapsed="$5" expected="$6"
    PROGRESS_ACTIVE=1
    printf '\r%s[%3d%%]%s iter %d/%d  task %d/%d  %-25s %3ds/%3ds%s' \
        "$BOLD" "$pct" "$RESET" "$iter" "$ITERATIONS" "$task" "$TASKS_PER_ITER" "$name" "$elapsed" "$expected" "$CLR"
}

progress_finish() {
    if (( PROGRESS_ACTIVE == 1 )); then
        printf '\r%s[100%%]%s benchmark complete%s\n' "$BOLD" "$RESET" "$CLR"
        PROGRESS_ACTIVE=0
    else
        say "[100%] benchmark complete"
    fi
}

progress_cooldown() {
    local iter="$1" sec="$2" left pct
    [[ -t 1 ]] || return 0
    pct=$(( DONE_WORK * 100 / TOTAL_WORK ))
    for ((left=sec; left>0; left--)); do
        printf '\r%s[%3d%%]%s iter %d/%d  cooldown                  %3ds    %s' \
            "$BOLD" "$pct" "$RESET" "$iter" "$ITERATIONS" "$left" "$CLR"
        PROGRESS_ACTIVE=1
        sleep 1 200>&-
    done
}

run_timed_capture() {
    local expected="$1" iter="$2" task="$3" name="$4" outfile="$5"; shift 5
    local pid start now elapsed shown pct rc
    : >"$outfile"
    "$@" 200>&- </dev/null >"$outfile" 2>&1 &
    pid=$!
    ACTIVE_PID="$pid"
    record_pid_state "$TMP_BASE/.active-pid" "$pid"
    start=$(date +%s)
    shown=-1

    # Interactive terminals get exactly one continuously updated progress line.
    # Non-TTY output is intentionally quiet to avoid log spam; failures still
    # print their normal error message and the final result is always emitted.
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$(( now - start ))
        (( elapsed > expected )) && elapsed=$expected
        pct=$(( (DONE_WORK + elapsed) * 100 / TOTAL_WORK ))
        (( pct > 99 )) && pct=99
        if [[ -t 1 && $elapsed -ne $shown ]]; then
            progress_line "$pct" "$iter" "$task" "$name" "$elapsed" "$expected"
            shown=$elapsed
        fi
        sleep 1 200>&-
    done

    wait "$pid"; rc=$?
    ACTIVE_PID=""
    rm -f -- "$TMP_BASE/.active-pid" 2>/dev/null || true
    DONE_WORK=$(( DONE_WORK + expected ))
    (( DONE_WORK > TOTAL_WORK )) && DONE_WORK=$TOTAL_WORK

    # Do not print a newline here: the next task overwrites the same line.
    if [[ -t 1 ]]; then
        pct=$(( DONE_WORK * 100 / TOTAL_WORK ))
        progress_line "$pct" "$iter" "$task" "$name" "$expected" "$expected"
    fi
    return "$rc"
}

# Output: p99.9_us max_us count_ge_1ms count_ge_5ms count_ge_10ms avg_us
parse_cyclic_hist() {
    local file="$1"
    awk '
        /^[0-9]/ {
            b[++n]=$1+0; c[n]=$2+0; total+=$2;
            if (($1+0) >= 1000) gt1+=$2;
            if (($1+0) >= 5000) gt5+=$2;
            if (($1+0) >= 10000) gt10+=$2;
        }
        /^# Avg Latencies:/ {avg=$4+0}
        /^# Max Latencies:/ {mx=$4+0}
        /^# Histogram Overflows:/ {of=$4+0}
        END {
            total += of; gt1 += of; gt5 += of; gt10 += of;
            target=total*0.999; acc=0; q=-1;
            for (i=1; i<=n; i++) {acc+=c[i]; if (q<0 && acc>=target) q=b[i]}
            if (q<0) q=(n ? b[n] : mx);
            printf "%.0f %.0f %.0f %.0f %.0f %.0f\n", q, mx, gt1, gt5, gt10, avg;
        }
    ' "$file"
}

# Aggregate multiple cyclictest histogram files.
# Output: p99.99_us max_us count_ge_1ms count_ge_5ms count_ge_10ms total_samples
aggregate_cyclic_hists() {
    awk -v hist_max="$HIST_MAX_US" '
        /^[0-9]/ {
            b=$1+0; n=$2+0; bins[b]+=n; hist_total+=n; if (b>maxb) maxb=b;
            if (b >= 1000) gt1+=n;
            if (b >= 5000) gt5+=n;
            if (b >= 10000) gt10+=n;
        }
        /^# Max Latencies:/ {v=$4+0; if (v>mx) mx=v}
        /^# Histogram Overflows:/ {of+=$4+0}
        END {
            total=hist_total+of; gt1+=of; gt5+=of; gt10+=of;
            if (total<=0) {printf "0 %.0f 0 0 0 0\n", mx; exit}
            target=total*0.9999; acc=0; q=-1;
            for (i=0; i<=maxb; i++) {
                if (i in bins) {acc+=bins[i]; if (q<0 && acc>=target) q=i}
            }
            # If p99.99 lands in histogram overflow, exact latency is unknown.
            # Use the histogram ceiling as a conservative lower bound, not MAX.
            if (q<0) q=hist_max;
            printf "%.0f %.0f %.0f %.0f %.0f %.0f\n", q, mx, gt1, gt5, gt10, total;
        }
    ' "$@"
}

cyclic_cmd=()
setup_cyclic_cmd() {
    local help_text
    cyclic_cmd=(cyclictest --policy=other -q -t1 -i1000 -h "$HIST_MAX_US")

    # Do not use `cyclictest --help | grep -q` here: with `set -o pipefail`,
    # grep may close the pipe early and cyclictest can exit on SIGPIPE, producing
    # a false "option not supported" result. Capture the complete help first.
    help_text="$(cyclictest --help 2>&1 || true)"
    if grep -F -- '--default-system' <<<"$help_text" >/dev/null; then
        cyclic_cmd+=(--default-system)
        info "cyclictest: --default-system enabled"
    else
        warn "cyclictest действительно не поддерживает --default-system; latency results may not be directly comparable with hosts where it is available"
    fi
}

run_cyclic() {
    local mode="$1" iter="$2" task="$3" hist="$4" log="$5"
    local name="latency idle"
    local stress_log="$TMP_BASE/stress-${iter}.log"
    STRESS_PID=""

    if [[ "$mode" == "load" ]]; then
        name="latency CPU 50%"
        stress-ng --cpu "$(nproc)" --cpu-load 50 --cpu-load-slice 10 --cpu-method all \
            --timeout "$((CYCLIC_SEC + 4))s" --quiet 200>&- </dev/null >"$stress_log" 2>&1 &
        STRESS_PID=$!
        record_pid_state "$TMP_BASE/.stress-pid" "$STRESS_PID"
        sleep 1 200>&-
    fi

    if ! run_timed_capture "$CYCLIC_SEC" "$iter" "$task" "$name" "$log" \
        "${cyclic_cmd[@]}" -D "${CYCLIC_SEC}s" --histfile="$hist"; then
        [[ -n "$STRESS_PID" ]] && terminate_pid "$STRESS_PID"
        STRESS_PID=""
        rm -f -- "$TMP_BASE/.stress-pid" 2>/dev/null || true
        die "cyclictest завершился ошибкой; подробности: $log"
    fi

    if [[ -n "$STRESS_PID" ]]; then
        terminate_pid "$STRESS_PID"
        STRESS_PID=""
        rm -f -- "$TMP_BASE/.stress-pid" 2>/dev/null || true
    fi
    [[ -s "$hist" ]] || die "cyclictest не создал histogram: $hist"
}

run_crypto_x25519() {
    local iter="$1" task="$2" out="$3" value
    run_timed_capture "$CRYPTO_SEC" "$iter" "$task" "crypto X25519" "$out" \
        openssl speed -elapsed -seconds "$CRYPTO_SEC" -mr ecdhx25519 \
        || die "OpenSSL X25519 benchmark завершился ошибкой: $out"
    value="$(awk -F: '$1=="+F5" {print $4}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать X25519 result: $out"
    LAST_VALUE="$value"
}

run_crypto_evp() {
    local algo="$1" label="$2" iter="$3" task="$4" out="$5" value
    run_timed_capture "$CRYPTO_SEC" "$iter" "$task" "$label" "$out" \
        openssl speed -elapsed -seconds "$CRYPTO_SEC" -bytes 16384 -mr -evp "$algo" -aead \
        || die "OpenSSL $algo benchmark завершился ошибкой: $out"
    value="$(awk -F: '$1=="+F" {print $NF}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать $algo result: $out"
    LAST_VALUE="$value"
}

run_cpu() {
    local iter="$1" task="$2" out="$3" value
    run_timed_capture "$CPU_SEC" "$iter" "$task" "CPU sysbench 1T" "$out" \
        sysbench cpu --threads=1 --time="$CPU_SEC" --events=0 --cpu-max-prime=20000 run \
        || die "sysbench CPU завершился ошибкой: $out"
    value="$(awk '/events per second:/ {print $4}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать sysbench CPU result: $out"
    LAST_VALUE="$value"
}

run_memory() {
    local iter="$1" task="$2" out="$3" value
    run_timed_capture "$RAM_SEC" "$iter" "$task" "MEM 64M seq read" "$out" \
        sysbench memory --threads=1 --time="$RAM_SEC" --events=0 \
        --memory-block-size=64M --memory-total-size=17592186044416 --memory-access-mode=seq \
        --memory-oper=read run || die "sysbench memory завершился ошибкой: $out"
    value="$(awk -F'[()]' '/MiB transferred/ {split($2,a," "); print a[1]}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать sysbench memory result: $out"
    LAST_VALUE="$value"
}

fio_engine="io_uring"
choose_fio_engine() {
    local enghelp
    enghelp="$(fio --enghelp 2>/dev/null || true)"
    if ! grep -qw 'io_uring' <<<"$enghelp"; then
        fio_engine="libaio"
        info "fio io_uring недоступен; используется libaio"
    fi
}

run_disk() {
    local iter="$1" task="$2" out="$3" log="$4" value
    if ! run_timed_capture "$DISK_SEC" "$iter" "$task" "disk 4K QD1" "$log" \
        fio --name=vpsbench --filename="$FIO_FILE" --size="${FIO_SIZE_MB}M" \
        --rw=randrw --rwmixread=70 --bs=4k --ioengine="$fio_engine" --iodepth=1 --numjobs=1 \
        --direct=1 --time_based=1 --runtime="$DISK_SEC" --randrepeat=1 \
        --lat_percentiles=1 --percentile_list=99:99.9 --group_reporting \
        --output-format=json --output="$out" --eta=never; then
        die "fio benchmark завершился ошибкой: $log"
    fi
    [[ -s "$out" ]] || die "fio не создал JSON: $out"

    value="$(jq -r '
      def p999($x):
        if ($x.clat_ns? != null) then (($x.clat_ns.percentile["99.900000"] // 0) / 1000000)
        elif ($x.clat_us? != null) then (($x.clat_us.percentile["99.900000"] // 0) / 1000)
        elif ($x.clat_ms? != null) then ($x.clat_ms.percentile["99.900000"] // 0)
        else 0 end;
      [p999(.jobs[0].read), p999(.jobs[0].write)] | max
    ' "$out")"
    is_num "$value" || die "Не удалось разобрать fio p99.9: $out"
    LAST_VALUE="$value"
}

calc_stats() {
    # median cv min max mean
    sort -n "$1" | awk '
        {a[NR]=$1+0; sum+=$1; sumsq+=($1*$1)}
        END {
            if (!NR) {print "0 0 0 0 0"; exit}
            mean=sum/NR;
            var=sumsq/NR - mean*mean; if (var<0) var=0;
            sd=sqrt(var); cv=(mean!=0 ? sd/mean*100 : 0);
            if (NR%2) med=a[(NR+1)/2]; else med=(a[NR/2]+a[NR/2+1])/2;
            printf "%.6f %.3f %.6f %.6f %.6f\n", med, cv, a[1], a[NR], mean;
        }
    '
}

avg_file() { awk '{s+=$1;n++} END {printf "%.6f", n?s/n:0}' "$1"; }
max_file() { sort -n "$1" | tail -n1; }

fmt_trim() {
    awk -v v="$1" -v d="${2:-2}" 'BEGIN {
        if (d==0) s=sprintf("%.0f",v);
        else if (d==1) s=sprintf("%.1f",v);
        else s=sprintf("%.2f",v);
        if (index(s,".")) {sub(/0+$/, "", s); sub(/\.$/, "", s)}
        printf "%s", s
    }'
}

fmt_latency_us() {
    awk -v u="$1" 'function trim(s){if(index(s,".")){sub(/0+$/, "", s);sub(/\.$/, "", s)}return s}
        BEGIN {
            if (u < 1000) printf "%.0fus", u;
            else {
                m=u/1000;
                if (m < 10) s=sprintf("%.2f",m);
                else if (m < 100) s=sprintf("%.1f",m);
                else s=sprintf("%.0f",m);
                printf "%sms", trim(s);
            }
        }'
}

fmt_latency_ms() {
    awk -v m="$1" 'function trim(s){if(index(s,".")){sub(/0+$/, "", s);sub(/\.$/, "", s)}return s}
        BEGIN {
            u=m*1000;
            if (u < 1000) printf "%.0fus", u;
            else {
                if (m < 10) s=sprintf("%.2f",m);
                else if (m < 100) s=sprintf("%.1f",m);
                else s=sprintf("%.0f",m);
                printf "%sms", trim(s);
            }
        }'
}

fmt_x25519() {
    awk -v v="$1" 'function trim(s){if(index(s,".")){sub(/0+$/, "", s);sub(/\.$/, "", s)}return s}
        BEGIN {
            if (v >= 1000) {x=v/1000; s=(x<10?sprintf("%.2f",x):x<100?sprintf("%.1f",x):sprintf("%.0f",x)); printf "%sk/s",trim(s)}
            else printf "%.0f/s",v
        }'
}

fmt_cpu() {
    awk -v v="$1" 'function trim(s){if(index(s,".")){sub(/0+$/, "", s);sub(/\.$/, "", s)}return s}
        BEGIN {
            if (v >= 1000) {x=v/1000; s=(x<10?sprintf("%.2f",x):x<100?sprintf("%.1f",x):sprintf("%.0f",x)); printf "%sk/s",trim(s)}
            else printf "%.0f/s",v
        }'
}

fmt_crypto() {
    awk -v v="$1" 'function trim(s){if(index(s,".")){sub(/0+$/, "", s);sub(/\.$/, "", s)}return s}
        BEGIN {
            if (v >= 1000000000) {x=v/1000000000; s=(x<10?sprintf("%.2f",x):x<100?sprintf("%.1f",x):sprintf("%.0f",x)); printf "%sG/s",trim(s)}
            else {x=v/1000000; s=(x<10?sprintf("%.2f",x):x<100?sprintf("%.1f",x):sprintf("%.0f",x)); printf "%sM/s",trim(s)}
        }'
}

fmt_ram() {
    awk -v v="$1" 'function trim(s){if(index(s,".")){sub(/0+$/, "", s);sub(/\.$/, "", s)}return s}
        BEGIN {
            if (v >= 1024) {x=v/1024; s=(x<10?sprintf("%.2f",x):x<100?sprintf("%.1f",x):sprintf("%.0f",x)); printf "%sGi/s",trim(s)}
            else {s=(v<10?sprintf("%.2f",v):v<100?sprintf("%.1f",v):sprintf("%.0f",v)); printf "%sMi/s",trim(s)}
        }'
}

fmt_cv() { awk -v v="$1" 'BEGIN {printf "%.0f",v}' ; }
sum_file() { awk '{s+=$1} END {printf "%.0f",s+0}' "$1"; }

latency_anomaly_flag() {
    # Per-iteration latency anomaly only. Performance metrics must not affect this flag.
    awk -v i="$1" -v l="$2" -v w="$3" -v im="$4" -v lm="$5" -v wm="$6" 'BEGIN {
        it=(im*1.8 > im+500 ? im*1.8 : im+500);
        lt=(lm*1.6 > lm+1000 ? lm*1.6 : lm+1000);
        wt=(wm*2.0 > wm+5000 ? wm*2.0 : wm+5000);
        if (i>it || l>lt || w>wt) printf "!";
    }'
}

performance_anomaly_flag() {
    # Per-iteration performance anomaly only. Disk is shown here but has only a
    # small weight in SYSTEM and never enters STABILITY.
    awk -v x="$1" -v a="$2" -v c="$3" -v cpu="$4" -v m="$5" -v d="$6" \
        -v xm="$7" -v am="$8" -v cm="$9" -v cpum="${10}" -v mm="${11}" -v dm="${12}" 'BEGIN {
        dt=(dm*2.5 > dm+0.5 ? dm*2.5 : dm+0.5);
        bad=(d>dt || (xm>0 && x<xm*.8) || (am>0 && a<am*.8) || (cm>0 && c<cm*.8) ||
             (cpum>0 && cpu<cpum*.8) || (mm>0 && m<mm*.8));
        if (bad) printf "!";
    }'
}

lat_score() {
    # Log interpolation: 100 at/below good, 0 at/above bad.
    awk -v x="$1" -v good="$2" -v bad="$3" 'BEGIN {
        if(x<=good) s=100; else if(x>=bad) s=0; else s=100*(log(bad)-log(x))/(log(bad)-log(good));
        if(s<0)s=0;if(s>100)s=100; printf "%.2f",s
    }'
}

perf_score() {
    # Provisional fixed throughput scale: 0 at/below bad, 100 at/above good.
    # Log interpolation keeps a single very fast architecture from dominating.
    awk -v x="$1" -v bad="$2" -v good="$3" 'BEGIN {
        if(x<=bad) s=0; else if(x>=good) s=100; else s=100*(log(x)-log(bad))/(log(good)-log(bad));
        if(s<0)s=0;if(s>100)s=100; printf "%.2f",s
    }'
}

cv_score() {
    # Repeatability component: full score <=2% CV, zero >=30% CV.
    awk -v x="$1" 'BEGIN {
        if (x<=2) s=100; else if (x>=30) s=0; else s=100*(30-x)/28;
        if(s<0)s=0;if(s>100)s=100; printf "%.2f",s
    }'
}

rate_score() {
    # Linear score for spike rate expressed as events per million samples.
    awk -v x="$1" -v good="$2" -v bad="$3" 'BEGIN {
        if (x<=good) s=100; else if (x>=bad) s=0; else s=100*(bad-x)/(bad-good);
        if(s<0)s=0;if(s>100)s=100; printf "%.2f",s
    }'
}

color_score() {
    local v="$1"
    if (( v >= 90 )); then printf '%s%d%s' "$GREEN$BOLD" "$v" "$RESET"
    elif (( v >= 75 )); then printf '%s%d%s' "$YELLOW$BOLD" "$v" "$RESET"
    else printf '%s%d%s' "$RED$BOLD" "$v" "$RESET"
    fi
}


command_version_line() {
    local name="$1"; shift
    local out
    out="$("$@" 2>&1 | head -n 1 || true)"
    printf '%-12s %s\n' "$name" "${out:-unknown}"
}


capture_debug_environment() {
    (( DEBUG_MODE == 1 )) || return 0
    local d="$TMP_BASE/environment"
    mkdir -p "$d" 2>/dev/null || return 0
    cp /etc/os-release "$d/os-release.txt" 2>/dev/null || true
    cp /proc/cpuinfo "$d/proc-cpuinfo.txt" 2>/dev/null || true
    cp /proc/meminfo "$d/proc-meminfo.txt" 2>/dev/null || true
    cp /proc/loadavg "$d/proc-loadavg.txt" 2>/dev/null || true
    uname -a >"$d/uname.txt" 2>&1 || true
    lscpu >"$d/lscpu.txt" 2>&1 || true
    systemd-detect-virt >"$d/virt.txt" 2>&1 || true
    df -hT >"$d/df.txt" 2>&1 || true
    findmnt >"$d/findmnt.txt" 2>&1 || true
    lsblk -a -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,ROTA,DISC-MAX,MODEL >"$d/lsblk.txt" 2>&1 || true
    openssl version -a >"$d/openssl-version.txt" 2>&1 || true
    cyclictest --version >"$d/cyclictest-version.txt" 2>&1 || true
    stress-ng --version >"$d/stress-ng-version.txt" 2>&1 || true
    sysbench --version >"$d/sysbench-version.txt" 2>&1 || true
    fio --version >"$d/fio-version.txt" 2>&1 || true
}

write_debug_report() {
    local report="$TMP_BASE/debug-report.txt"
    {
        echo "VPSBENCH DEBUG REPORT"
        echo "version=$SCRIPT_VERSION"
        echo "completed=$RUN_COMPLETED"
        echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "uid=$EUID"
        echo
        echo "[CONFIG]"
        printf 'iterations=%s cyclic_sec=%s crypto_sec=%s cpu_sec=%s mem_sec=%s disk_sec=%s cooldown_sec=%s hist_max_us=%s fio_size_mb=%s fio_engine=%s\n' \
            "$ITERATIONS" "$CYCLIC_SEC" "$CRYPTO_SEC" "$CPU_SEC" "$RAM_SEC" "$DISK_SEC" "$COOLDOWN_SEC" "$HIST_MAX_US" "$FIO_SIZE_MB" "$fio_engine"
        printf 'cyclic_cmd='; printf '%q ' "${cyclic_cmd[@]}"; printf '\n'
        echo
        echo "[SYSTEM]"
        printf 'os=%s\n' "${os_name:-unknown}"
        printf 'kernel=%s\n' "$(uname -a)"
        printf 'virt=%s\n' "${virt:-unknown}"
        printf 'cpu=%s\n' "${model:-unknown}"
        printf 'vcpu=%s mem_mib=%s isa=%s\n' "$(nproc)" "${mem_mb:-unknown}" "$(isa_short)"
        printf 'loadavg=%s\n' "$(cat /proc/loadavg 2>/dev/null || true)"
        echo
        echo "[VERSIONS]"
        command_version_line cyclictest cyclictest --version
        command_version_line stress-ng stress-ng --version
        command_version_line sysbench sysbench --version
        command_version_line fio fio --version
        command_version_line openssl openssl version
        command_version_line jq jq --version
        echo
        echo "[ITERATIONS]"
        echo -e "iter\tidle_p999_us\tload_p999_us\tidle_max_us\tload_max_us\tx25519_ops_s\taes_B_s\tchacha_B_s\tcpu_events_s\tmem_MiB_s\tdisk_p999_ms"
        cat "$TMP_BASE/iterations.tsv" 2>/dev/null || true
        echo
        echo "[CYCLIC_PER_ITERATION]"
        echo -e "iter\tidle_p999_us\tidle_avg_us\tidle_max_us\tidle_ge1ms\tidle_ge5ms\tidle_ge10ms\tload_p999_us\tload_avg_us\tload_max_us\tload_ge1ms\tload_ge5ms\tload_ge10ms"
        cat "$TMP_BASE/cyclic-details.tsv" 2>/dev/null || true
        if (( RUN_COMPLETED == 1 )); then
            echo
            echo "[AGGREGATE]"
            printf 'idle_p9999_us=%s idle_max_us=%s idle_ge1ms=%s idle_ge5ms=%s idle_ge10ms=%s idle_samples=%s\n' \
                "$idle_p9999" "$idle_max_all" "$idle_gt1_count" "$idle_gt5_count" "$idle_gt10_count" "$idle_samples"
            printf 'load_p9999_us=%s load_max_us=%s load_ge1ms=%s load_ge5ms=%s load_ge10ms=%s load_samples=%s\n' \
                "$load_p9999" "$load_max_all" "$load_gt1_count" "$load_gt5_count" "$load_gt10_count" "$load_samples"
            echo
            echo "[STATS]"
            printf 'idle median=%s cv=%s min=%s max=%s mean=%s\n' "$idle_med" "$idle_cv" "$idle_min" "$idle_worst" "$idle_mean"
            printf 'load median=%s cv=%s min=%s max=%s mean=%s\n' "$load_med" "$load_cv" "$load_min" "$load_worst" "$load_mean"
            printf 'x25519 median=%s cv=%s min=%s max=%s mean=%s\n' "$x_med" "$x_cv" "$x_min" "$x_max" "$x_mean"
            printf 'aes median=%s cv=%s min=%s max=%s mean=%s\n' "$aes_med" "$aes_cv" "$aes_min" "$aes_max" "$aes_mean"
            printf 'chacha median=%s cv=%s min=%s max=%s mean=%s\n' "$cha_med" "$cha_cv" "$cha_min" "$cha_max" "$cha_mean"
            printf 'cpu median=%s cv=%s min=%s max=%s mean=%s\n' "$cpu_med" "$cpu_cv" "$cpu_min" "$cpu_max" "$cpu_mean"
            printf 'mem median=%s cv=%s min=%s max=%s mean=%s\n' "$ram_med" "$ram_cv" "$ram_min" "$ram_max" "$ram_mean"
            printf 'disk median=%s cv=%s min=%s max=%s mean=%s\n' "$disk_med" "$disk_cv" "$disk_min" "$disk_max" "$disk_mean"
            echo
            echo "[SCORE_COMPONENTS]"
            printf 'latency_score=%s crypto_score=%s system_score=%s overall_score=%s stability=%s\n' \
                "$latency_score" "$crypto_score" "$system_score" "$overall_score" "$stab"
            printf 'latency_subscores idle=%s load=%s idle_p9999=%s load_p9999=%s worst=%s\n' \
                "$s_idle" "$s_load" "$s_idle9999" "$s_load9999" "$s_worst"
            printf 'crypto_subscores x25519=%s aes=%s chacha=%s\n' "$sx" "$sa" "$sc"
            printf 'system_subscores cpu=%s mem=%s disk=%s\n' "$scpu" "$smem" "$sdisk"
            printf 'spike_rates_per_million ge5=%s ge10=%s spike_scores ge5=%s ge10=%s\n' \
                "$gt5_rate" "$gt10_rate" "$spike5_s" "$spike10_s"
        fi
        echo
        echo "[RAW_FILES_IN_ARCHIVE]"
        find "$TMP_BASE" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
    } >"$report"
}

create_debug_bundle() {
    local state="${1:-complete}" debug_dir stamp base
    (( DEBUG_MODE == 1 )) || return 0
    (( DEBUG_BUNDLE_CREATED == 0 )) || return 0
    [[ -n "${TMP_BASE:-}" && -d "$TMP_BASE" ]] || return 0

    write_debug_report || true
    debug_dir="${VPSBENCH_DEBUG_DIR:-/var/tmp}"
    [[ -d "$debug_dir" && -w "$debug_dir" ]] || debug_dir="${TMPDIR:-/tmp}"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    base="vpsbench-debug-${SCRIPT_VERSION}-${state}-${stamp}-$$.tar.gz"
    DEBUG_ARCHIVE="$debug_dir/$base"
    if tar -C "$TMP_BASE" -czf "$DEBUG_ARCHIVE" . 2>/dev/null; then
        chmod 0644 "$DEBUG_ARCHIVE" 2>/dev/null || true
        DEBUG_BUNDLE_CREATED=1
        return 0
    fi
    DEBUG_ARCHIVE=""
    return 1
}

print_debug_report() {
    (( DEBUG_MODE == 1 )) || return 0
    write_debug_report
    say ""
    say "${BOLD}DEBUG${RESET}"
    cat "$TMP_BASE/debug-report.txt"
    if create_debug_bundle "complete"; then
        say ""
        info "Raw debug bundle: $DEBUG_ARCHIVE"
        info "Upload this .tar.gz for full analysis; it contains raw logs, fio JSON and cyclictest histograms."
    else
        warn "Could not create raw debug bundle"
    fi
}

main() {
    parse_args "$@"
    info "VPSBench ${SCRIPT_VERSION}: starting"
    validate_config
    acquire_lock
    cleanup_stale_artifacts
    info "Checking system and dependencies"
    check_os_and_install
    TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/vpsbench.$$.XXXXXX")" || die "mktemp failed"
    write_owner_marker
    setup_cyclic_cmd
    choose_fio_engine
    capture_debug_environment

    local os_name virt model mem_mb load1
    # shellcheck disable=SC1091
    . /etc/os-release
    os_name="${PRETTY_NAME:-${ID:-unknown}}"
    virt="$(systemd-detect-virt 2>/dev/null || true)"; [[ -n "$virt" && "$virt" != "none" ]] || virt="unknown"
    model="$(cpu_model)"; [[ -n "$model" ]] || model="unknown"
    mem_mb="$(awk '/MemTotal/ {printf "%.0f",$2/1024}' /proc/meminfo)"
    load1="$(awk '{print $1}' /proc/loadavg)"

    say ""
    say "${BOLD}VPSBench responsiveness ${SCRIPT_VERSION}${RESET}"
    say "OS:      $os_name"
    say "Kernel:  $(uname -r) / $(uname -m)"
    say "Virt:    $virt"
    say "CPU:     $model"
    say "vCPU:    $(nproc)    Mem: ${mem_mb} MiB    ISA: $(isa_short)"
    say "Load1:   $load1"
    say "Plan:    ${ITERATIONS} итераций, ~${PER_ITER_WORK}s измерений/итерация (~$((EST_RUNTIME/60))m$((EST_RUNTIME%60))s + preparation)"
    say "Tests:   idle latency -> X25519 -> AES-GCM -> ChaCha20 -> CPU 1T -> MEM -> disk QD1 -> latency @ CPU 50%"
    say "Network: внешних соединений во время benchmark-фазы нет"
    say "Safety:  single-run lock, signal cleanup, orphan recovery + legacy cleanup"
    say ""

    prepare_fio_file
    sleep 2 200>&-

    local f
    for f in idle_p999 idle_max idle_gt1 idle_gt5 idle_gt10 load_p999 load_max load_gt1 load_gt5 load_gt10 x255 aes cha cpu ram disk; do
        : >"$TMP_BASE/$f.dat"
    done
    : >"$TMP_BASE/iterations.tsv"
    : >"$TMP_BASE/cyclic-details.tsv"

    local i task hist log vals idle_p999 idle_max idle_gt1 idle_gt5 idle_gt10 idle_avg
    local load_p999 load_max load_gt1 load_gt5 load_gt10 load_avg x255 aes cha cpu ram disk

    for ((i=1; i<=ITERATIONS; i++)); do
        # Iteration/task state is shown in the single live progress line.
        :
        task=1

        hist="$TMP_BASE/cyclic-idle-$i.hist"; log="$TMP_BASE/cyclic-idle-$i.log"
        run_cyclic idle "$i" "$task" "$hist" "$log"
        vals="$(parse_cyclic_hist "$hist")"
        read -r idle_p999 idle_max idle_gt1 idle_gt5 idle_gt10 idle_avg <<<"$vals"
        printf '%s\n' "$idle_p999" >>"$TMP_BASE/idle_p999.dat"; printf '%s\n' "$idle_max" >>"$TMP_BASE/idle_max.dat"
        printf '%s\n' "$idle_gt1" >>"$TMP_BASE/idle_gt1.dat"; printf '%s\n' "$idle_gt5" >>"$TMP_BASE/idle_gt5.dat"; printf '%s\n' "$idle_gt10" >>"$TMP_BASE/idle_gt10.dat"

        ((task++)); run_crypto_x25519 "$i" "$task" "$TMP_BASE/x255-$i.log"; x255="$LAST_VALUE"; printf '%s\n' "$x255" >>"$TMP_BASE/x255.dat"
        ((task++)); run_crypto_evp aes-128-gcm "crypto AES-GCM" "$i" "$task" "$TMP_BASE/aes-$i.log"; aes="$LAST_VALUE"; printf '%s\n' "$aes" >>"$TMP_BASE/aes.dat"
        ((task++)); run_crypto_evp chacha20-poly1305 "crypto ChaCha20" "$i" "$task" "$TMP_BASE/cha-$i.log"; cha="$LAST_VALUE"; printf '%s\n' "$cha" >>"$TMP_BASE/cha.dat"
        ((task++)); run_cpu "$i" "$task" "$TMP_BASE/cpu-$i.log"; cpu="$LAST_VALUE"; printf '%s\n' "$cpu" >>"$TMP_BASE/cpu.dat"
        ((task++)); run_memory "$i" "$task" "$TMP_BASE/ram-$i.log"; ram="$LAST_VALUE"; printf '%s\n' "$ram" >>"$TMP_BASE/ram.dat"
        ((task++)); run_disk "$i" "$task" "$TMP_BASE/fio-$i.json" "$TMP_BASE/fio-$i.log"; disk="$LAST_VALUE"; printf '%s\n' "$disk" >>"$TMP_BASE/disk.dat"

        ((task++)); hist="$TMP_BASE/cyclic-load-$i.hist"; log="$TMP_BASE/cyclic-load-$i.log"
        run_cyclic load "$i" "$task" "$hist" "$log"
        vals="$(parse_cyclic_hist "$hist")"
        read -r load_p999 load_max load_gt1 load_gt5 load_gt10 load_avg <<<"$vals"
        printf '%s\n' "$load_p999" >>"$TMP_BASE/load_p999.dat"; printf '%s\n' "$load_max" >>"$TMP_BASE/load_max.dat"
        printf '%s\n' "$load_gt1" >>"$TMP_BASE/load_gt1.dat"; printf '%s\n' "$load_gt5" >>"$TMP_BASE/load_gt5.dat"; printf '%s\n' "$load_gt10" >>"$TMP_BASE/load_gt10.dat"

        printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$i" "$idle_p999" "$idle_avg" "$idle_max" "$idle_gt1" "$idle_gt5" "$idle_gt10" \
            "$load_p999" "$load_avg" "$load_max" "$load_gt1" "$load_gt5" "$load_gt10" >>"$TMP_BASE/cyclic-details.tsv"

        printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$idle_p999" "$load_p999" "$idle_max" "$load_max" "$x255" "$aes" "$cha" "$cpu" "$ram" "$disk" >>"$TMP_BASE/iterations.tsv"

        if (( i < ITERATIONS )); then
            if [[ -t 1 ]]; then
                progress_cooldown "$i" "$COOLDOWN_SEC"
            else
                sleep "$COOLDOWN_SEC" 200>&-
            fi
        fi
    done

    DONE_WORK=$TOTAL_WORK
    progress_finish
    say ""

    local idle_med idle_cv idle_min idle_worst idle_mean load_med load_cv load_min load_worst load_mean
    local x_med x_cv x_min x_max x_mean aes_med aes_cv aes_min aes_max aes_mean
    local cha_med cha_cv cha_min cha_max cha_mean cpu_med cpu_cv cpu_min cpu_max cpu_mean
    local ram_med ram_cv ram_min ram_max ram_mean disk_med disk_cv disk_min disk_max disk_mean
    read -r idle_med idle_cv idle_min idle_worst idle_mean < <(calc_stats "$TMP_BASE/idle_p999.dat")
    read -r load_med load_cv load_min load_worst load_mean < <(calc_stats "$TMP_BASE/load_p999.dat")
    read -r x_med x_cv x_min x_max x_mean < <(calc_stats "$TMP_BASE/x255.dat")
    read -r aes_med aes_cv aes_min aes_max aes_mean < <(calc_stats "$TMP_BASE/aes.dat")
    read -r cha_med cha_cv cha_min cha_max cha_mean < <(calc_stats "$TMP_BASE/cha.dat")
    read -r cpu_med cpu_cv cpu_min cpu_max cpu_mean < <(calc_stats "$TMP_BASE/cpu.dat")
    read -r ram_med ram_cv ram_min ram_max ram_mean < <(calc_stats "$TMP_BASE/ram.dat")
    read -r disk_med disk_cv disk_min disk_max disk_mean < <(calc_stats "$TMP_BASE/disk.dat")

    # Aggregate all cyclictest histograms. p99.99 is intentionally computed from
    # the combined distribution, not as a median of per-iteration percentiles.
    local idle_p9999 idle_max_all idle_gt1_count idle_gt5_count idle_gt10_count idle_samples
    local load_p9999 load_max_all load_gt1_count load_gt5_count load_gt10_count load_samples
    read -r idle_p9999 idle_max_all idle_gt1_count idle_gt5_count idle_gt10_count idle_samples \
        < <(aggregate_cyclic_hists "$TMP_BASE"/cyclic-idle-*.hist)
    read -r load_p9999 load_max_all load_gt1_count load_gt5_count load_gt10_count load_samples \
        < <(aggregate_cyclic_hists "$TMP_BASE"/cyclic-load-*.hist)

    local worst_all worst_med worst_cv worst_min worst_max worst_mean
    worst_all="$(awk -v a="$idle_max_all" -v b="$load_max_all" 'BEGIN{print (a>b?a:b)}')"
    awk -F '\t' '{print ($4>$5?$4:$5)}' "$TMP_BASE/iterations.tsv" >"$TMP_BASE/worst.dat"
    read -r worst_med worst_cv worst_min worst_max worst_mean < <(calc_stats "$TMP_BASE/worst.dat")

    # LATENCY score. MAX is deliberately only 10%; aggregate p99.99 carries
    # much more information about persistent tail behaviour than one worst sample.
    local s_idle s_load s_idle9999 s_load9999 s_worst latency_f latency_score
    s_idle="$(lat_score "$idle_med" 100 10000)"
    s_load="$(lat_score "$load_med" 500 20000)"
    s_idle9999="$(lat_score "$idle_p9999" 1000 20000)"
    s_load9999="$(lat_score "$load_p9999" 3000 30000)"
    s_worst="$(lat_score "$worst_all" 5000 100000)"
    latency_f="$(awk -v a="$s_idle" -v b="$s_load" -v c="$s_idle9999" -v d="$s_load9999" -v e="$s_worst" \
        'BEGIN{printf "%.2f",a*.20+b*.35+c*.10+d*.25+e*.10}')"
    latency_score="$(awk -v v="$latency_f" 'BEGIN{printf "%d",v+0.5}')"

    # STAB: repeatability + tail health. Storage is intentionally excluded because
    # it is not on the critical path for the target VPN workload.
    local cv_idle_s cv_load_s cv_x_s cv_aes_s cv_cha_s cv_cpu_s cv_mem_s perf_cv_s
    local total_samples gt5_total gt10_total gt5_rate gt10_rate spike5_s spike10_s stab_f stab
    cv_idle_s="$(cv_score "$idle_cv")"; cv_load_s="$(cv_score "$load_cv")"
    cv_x_s="$(cv_score "$x_cv")"; cv_aes_s="$(cv_score "$aes_cv")"
    cv_cha_s="$(cv_score "$cha_cv")"; cv_cpu_s="$(cv_score "$cpu_cv")"; cv_mem_s="$(cv_score "$ram_cv")"
    perf_cv_s="$(awk -v x="$cv_x_s" -v a="$cv_aes_s" -v c="$cv_cha_s" -v p="$cv_cpu_s" -v m="$cv_mem_s" \
        'BEGIN{printf "%.2f",x*.30+a*.15+c*.15+p*.20+m*.20}')"

    total_samples=$(( idle_samples + load_samples ))
    gt5_total=$(( idle_gt5_count + load_gt5_count ))
    gt10_total=$(( idle_gt10_count + load_gt10_count ))
    gt5_rate="$(awk -v c="$gt5_total" -v n="$total_samples" 'BEGIN{printf "%.3f", n?c*1000000/n:0}')"
    gt10_rate="$(awk -v c="$gt10_total" -v n="$total_samples" 'BEGIN{printf "%.3f", n?c*1000000/n:0}')"
    spike5_s="$(rate_score "$gt5_rate" 20 500)"
    spike10_s="$(rate_score "$gt10_rate" 2 100)"

    stab_f="$(awk -v ci="$cv_idle_s" -v cl="$cv_load_s" -v cp="$perf_cv_s" \
        -v pi="$s_idle9999" -v pl="$s_load9999" -v s5="$spike5_s" -v s10="$spike10_s" -v mw="$s_worst" \
        'BEGIN{printf "%.2f",ci*.15+cl*.20+cp*.15+pi*.10+pl*.15+s5*.10+s10*.10+mw*.05}')"
    stab="$(awk -v v="$stab_f" 'BEGIN{printf "%d",v+0.5}')"

    # Provisional fixed performance scales (v1). These are intentionally kept
    # independent of the current comparison set so a server's score does not
    # change just because a faster/slower host is added later. We will calibrate
    # the thresholds after collecting more real-world VPS results.
    local sx sa sc crypto_f crypto_score scpu smem sdisk system_f system_score overall_f overall_score
    sx="$(perf_score "$x_med" 10000 40000)"
    sa="$(perf_score "$aes_med" 1000000000 12000000000)"
    sc="$(perf_score "$cha_med" 700000000 4500000000)"
    crypto_f="$(awk -v x="$sx" -v a="$sa" -v c="$sc" 'BEGIN{printf "%.2f",x*.40+a*.30+c*.30}')"
    crypto_score="$(awk -v v="$crypto_f" 'BEGIN{printf "%d",v+0.5}')"

    scpu="$(perf_score "$cpu_med" 400 2500)"
    smem="$(perf_score "$ram_med" 4096 45056)"
    sdisk="$(lat_score "$(awk -v m="$disk_med" 'BEGIN{printf "%.3f",m*1000}')" 300 20000)"
    system_f="$(awk -v p="$scpu" -v m="$smem" -v d="$sdisk" 'BEGIN{printf "%.2f",p*.55+m*.35+d*.10}')"
    system_score="$(awk -v v="$system_f" 'BEGIN{printf "%d",v+0.5}')"

    overall_f="$(awk -v l="$latency_score" -v c="$crypto_score" -v s="$system_score" \
        'BEGIN{printf "%.2f",l*.50+c*.35+s*.15}')"
    overall_score="$(awk -v v="$overall_f" 'BEGIN{printf "%d",v+0.5}')"

    say "${BOLD}LATENCY${RESET}  ${DIM}(cyclictest p99.9; WORST = worst sample in iteration)${RESET}"
    printf '%-5s %10s %10s %10s %3s\n' "ITER" "IDLE" "LOAD" "WORST" ""
    printf '%s\n' "---------------------------------------------"
    while IFS=$'\t' read -r ri r_idle r_load r_imax r_lmax r_x r_a r_c r_cpu r_r r_d; do
        local r_worst flag
        r_worst="$(awk -v a="$r_imax" -v b="$r_lmax" 'BEGIN{print (a>b?a:b)}')"
        flag="$(latency_anomaly_flag "$r_idle" "$r_load" "$r_worst" "$idle_med" "$load_med" "$worst_med")"
        printf '%-5s %10s %10s %10s %3s\n' "$ri" "$(fmt_latency_us "$r_idle")" "$(fmt_latency_us "$r_load")" "$(fmt_latency_us "$r_worst")" "$flag"
    done <"$TMP_BASE/iterations.tsv"

    say ""
    say "${BOLD}PERFORMANCE${RESET}"
    printf '%-5s %10s %10s %10s %10s %10s %10s %3s\n' "ITER" "X25519" "AES" "CHACHA" "CPU" "MEM" "DISK" ""
    printf '%s\n' "-------------------------------------------------------------------------------"
    while IFS=$'\t' read -r ri r_idle r_load r_imax r_lmax r_x r_a r_c r_cpu r_r r_d; do
        local flag
        flag="$(performance_anomaly_flag "$r_x" "$r_a" "$r_c" "$r_cpu" "$r_r" "$r_d" "$x_med" "$aes_med" "$cha_med" "$cpu_med" "$ram_med" "$disk_med")"
        printf '%-5s %10s %10s %10s %10s %10s %10s %3s\n' \
            "$ri" "$(fmt_x25519 "$r_x")" "$(fmt_crypto "$r_a")" "$(fmt_crypto "$r_c")" "$(fmt_cpu "$r_cpu")" "$(fmt_ram "$r_r")" "$(fmt_latency_ms "$r_d")" "$flag"
    done <"$TMP_BASE/iterations.tsv"

    say ""
    printf '%sLATENCY%s ' "$BOLD" "$RESET"; color_score "$latency_score"; printf '/100\n'
    printf '  idle     %-9s (CV %s%%)   tail %s\n' "$(fmt_latency_us "$idle_med")" "$(fmt_cv "$idle_cv")" "$(fmt_latency_us "$idle_p9999")"
    printf '  load     %-9s (CV %s%%)   tail %s\n' "$(fmt_latency_us "$load_med")" "$(fmt_cv "$load_cv")" "$(fmt_latency_us "$load_p9999")"
    printf '  worst    %s\n' "$(fmt_latency_us "$worst_all")"
    printf '  spikes   >=5ms  idle %s  load %s\n' "$idle_gt5_count" "$load_gt5_count"
    printf '           >=10ms idle %s  load %s\n' "$idle_gt10_count" "$load_gt10_count"

    say ""
    printf '%sCRYPTO%s ' "$BOLD" "$RESET"; color_score "$crypto_score"; printf '/100\n'
    printf '  X25519   %-9s (CV %s%%)\n' "$(fmt_x25519 "$x_med")" "$(fmt_cv "$x_cv")"
    printf '  AES      %-9s (CV %s%%)\n' "$(fmt_crypto "$aes_med")" "$(fmt_cv "$aes_cv")"
    printf '  ChaCha   %-9s (CV %s%%)\n' "$(fmt_crypto "$cha_med")" "$(fmt_cv "$cha_cv")"

    say ""
    printf '%sSYSTEM%s ' "$BOLD" "$RESET"; color_score "$system_score"; printf '/100\n'
    printf '  CPU      %-9s (CV %s%%)\n' "$(fmt_cpu "$cpu_med")" "$(fmt_cv "$cpu_cv")"
    printf '  MEM      %-9s (CV %s%%)\n' "$(fmt_ram "$ram_med")" "$(fmt_cv "$ram_cv")"
    printf '  Disk     %-9s (CV %s%%)\n' "$(fmt_latency_ms "$disk_med")" "$(fmt_cv "$disk_cv")"

    say ""
    say "${BOLD}RESULT${RESET}"
    printf '  SCORE '; color_score "$overall_score"; printf '/100\n'
    printf '  STABILITY '; color_score "$stab"; printf '/100\n'

    RUN_COMPLETED=1
    print_debug_report

    say ""
    say "${DIM}CV = variation between $ITERATIONS iterations; tail = aggregate p99.99 of cyclictest.${RESET}"
    say "${DIM}SCORE = 50% LATENCY + 35% CRYPTO + 15% SYSTEM. CRYPTO/SYSTEM scales are provisional v1 and will be calibrated after more VPS runs.${RESET}"
    say "${DIM}! is local to each table: latency deviations do not mark PERFORMANCE and vice versa.${RESET}"

}

main "$@"
