#!/usr/bin/env bash
# VPS responsiveness benchmark for Debian 13 / Ubuntu
# Local-only benchmark traffic: CPU/scheduler/crypto/RAM/storage.

set -u
set -o pipefail
export LC_ALL=C
export LANG=C
umask 077

SCRIPT_VERSION="1.3.0"
ITERATIONS="${VPSBENCH_ITERATIONS:-5}"
CYCLIC_SEC="${VPSBENCH_CYCLIC_SEC:-45}"
CRYPTO_SEC="${VPSBENCH_CRYPTO_SEC:-5}"
RAM_SEC="${VPSBENCH_RAM_SEC:-8}"
DISK_SEC="${VPSBENCH_DISK_SEC:-10}"
COOLDOWN_SEC="${VPSBENCH_COOLDOWN_SEC:-5}"
HIST_MAX_US="${VPSBENCH_HIST_MAX_US:-100000}"
FIO_SIZE_MB="${VPSBENCH_FIO_SIZE_MB:-256}"
TASKS_PER_ITER=7

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

    if [[ -d /run/lock && -w /run/lock ]]; then
        LOCK_FILE="/run/lock/vpsbench.lock"
    else
        LOCK_FILE="${TMPDIR:-/tmp}/.vpsbench-${EUID}.lock"
    fi

    exec 200>"$LOCK_FILE" || die "Не удалось открыть lock-файл: $LOCK_FILE"
    if ! flock -w 5 200; then
        die "VPSBench уже запущен на этом сервере (lock занят более 5 секунд)."
    fi
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
PER_ITER_WORK=$(( CYCLIC_SEC + CRYPTO_SEC * 3 + RAM_SEC + DISK_SEC + CYCLIC_SEC ))
TOTAL_WORK=$(( PER_ITER_WORK * ITERATIONS ))
DONE_WORK=0
CURRENT_TASK=0
LAST_VALUE=""

progress_line() {
    local pct="$1" iter="$2" task="$3" name="$4" elapsed="$5" expected="$6"
    printf '\r%s[%3d%%]%s iter %d/%d  task %d/%d  %-25s %3ds/%3ds%s' \
        "$BOLD" "$pct" "$RESET" "$iter" "$ITERATIONS" "$task" "$TASKS_PER_ITER" "$name" "$elapsed" "$expected" "$CLR"
}

progress_log() {
    local pct="$1" iter="$2" task="$3" name="$4" elapsed="$5" expected="$6"
    printf '[%3d%%] iter %d/%d  task %d/%d  %-25s %3ds/%3ds\n' \
        "$pct" "$iter" "$ITERATIONS" "$task" "$TASKS_PER_ITER" "$name" "$elapsed" "$expected"
}

run_timed_capture() {
    local expected="$1" iter="$2" task="$3" name="$4" outfile="$5"; shift 5
    local pid start now elapsed shown pct rc next_log
    : >"$outfile"
    "$@" 200>&- </dev/null >"$outfile" 2>&1 &
    pid=$!
    ACTIVE_PID="$pid"
    record_pid_state "$TMP_BASE/.active-pid" "$pid"
    start=$(date +%s)
    shown=-1
    next_log=0

    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$(( now - start ))
        (( elapsed > expected )) && elapsed=$expected
        pct=$(( (DONE_WORK + elapsed) * 100 / TOTAL_WORK ))
        (( pct > 99 )) && pct=99

        if [[ -t 1 ]]; then
            if (( elapsed != shown )); then
                progress_line "$pct" "$iter" "$task" "$name" "$elapsed" "$expected"
                shown=$elapsed
            fi
        elif (( elapsed >= next_log )); then
            progress_log "$pct" "$iter" "$task" "$name" "$elapsed" "$expected"
            next_log=$(( elapsed + 5 ))
        fi
        sleep 1 200>&-
    done

    wait "$pid"; rc=$?
    ACTIVE_PID=""
    rm -f -- "$TMP_BASE/.active-pid" 2>/dev/null || true
    DONE_WORK=$(( DONE_WORK + expected ))
    (( DONE_WORK > TOTAL_WORK )) && DONE_WORK=$TOTAL_WORK
    pct=$(( DONE_WORK * 100 / TOTAL_WORK ))
    if [[ -t 1 ]]; then
        progress_line "$pct" "$iter" "$task" "$name" "$expected" "$expected"
        printf '\n'
    else
        printf '[%3d%%] iter %d/%d  task %d/%d  %-25s done\n' \
            "$pct" "$iter" "$ITERATIONS" "$task" "$TASKS_PER_ITER" "$name"
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

cyclic_cmd=()
setup_cyclic_cmd() {
    cyclic_cmd=(cyclictest --policy=other -q -t1 -i1000 -h "$HIST_MAX_US")
    if cyclictest --help 2>&1 | grep -q -- '--default-system'; then
        cyclic_cmd+=(--default-system)
    else
        warn "cyclictest не поддерживает --default-system: power-management tuning может немного улучшить latency"
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

run_memory() {
    local iter="$1" task="$2" out="$3" value
    run_timed_capture "$RAM_SEC" "$iter" "$task" "RAM 64M seq read" "$out" \
        sysbench memory --threads=1 --time="$RAM_SEC" --events=0 \
        --memory-block-size=64M --memory-total-size=17592186044416 --memory-access-mode=seq \
        --memory-oper=read run || die "sysbench memory завершился ошибкой: $out"
    value="$(awk -F'[()]' '/MiB transferred/ {split($2,a," "); print a[1]}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать sysbench memory result: $out"
    LAST_VALUE="$value"
}

fio_engine="io_uring"
choose_fio_engine() {
    if ! fio --enghelp 2>/dev/null | grep -qw 'io_uring'; then
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

anomaly_flag() {
    awk -v i="$1" -v l="$2" -v x="$3" -v a="$4" -v c="$5" -v r="$6" -v d="$7" \
        -v im="$8" -v lm="$9" -v xm="${10}" -v am="${11}" -v cm="${12}" -v rm="${13}" -v dm="${14}" 'BEGIN {
        it=(im*2.5 > im+500 ? im*2.5 : im+500);
        lt=(lm*2.5 > lm+500 ? lm*2.5 : lm+500);
        dt=(dm*2.5 > dm+0.5 ? dm*2.5 : dm+0.5);
        bad=(i>it || l>lt || d>dt || (xm>0 && x<xm*.8) || (am>0 && a<am*.8) || (cm>0 && c<cm*.8) || (rm>0 && r<rm*.8));
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

color_score() {
    local v="$1"
    if (( v >= 90 )); then printf '%s%3d%s' "$GREEN$BOLD" "$v" "$RESET"
    elif (( v >= 75 )); then printf '%s%3d%s' "$YELLOW$BOLD" "$v" "$RESET"
    else printf '%s%3d%s' "$RED$BOLD" "$v" "$RESET"
    fi
}

main() {
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
    say "vCPU:    $(nproc)    RAM: ${mem_mb} MiB    ISA: $(isa_short)"
    say "Load1:   $load1"
    say "Plan:    ${ITERATIONS} итераций, ~${PER_ITER_WORK}s измерений/итерация (~$((TOTAL_WORK/60))m$((TOTAL_WORK%60))s чистого benchmark time)"
    say "Tests:   idle latency -> X25519 -> AES-GCM -> ChaCha20 -> RAM -> disk QD1 -> latency @ CPU 50%"
    say "Network: внешних соединений во время benchmark-фазы нет"
    say "Safety:  single-run lock, signal cleanup, orphan recovery + legacy cleanup"
    say ""

    prepare_fio_file
    sleep 2 200>&-

    local f
    for f in idle_p999 idle_max idle_gt1 idle_gt5 idle_gt10 load_p999 load_max load_gt1 load_gt5 load_gt10 x255 aes cha ram disk; do
        : >"$TMP_BASE/$f.dat"
    done
    : >"$TMP_BASE/iterations.tsv"

    local i task hist log vals idle_p999 idle_max idle_gt1 idle_gt5 idle_gt10 idle_avg
    local load_p999 load_max load_gt1 load_gt5 load_gt10 load_avg x255 aes cha ram disk

    for ((i=1; i<=ITERATIONS; i++)); do
        say "${DIM}--- итерация $i/$ITERATIONS ---${RESET}"
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
        ((task++)); run_memory "$i" "$task" "$TMP_BASE/ram-$i.log"; ram="$LAST_VALUE"; printf '%s\n' "$ram" >>"$TMP_BASE/ram.dat"
        ((task++)); run_disk "$i" "$task" "$TMP_BASE/fio-$i.json" "$TMP_BASE/fio-$i.log"; disk="$LAST_VALUE"; printf '%s\n' "$disk" >>"$TMP_BASE/disk.dat"

        ((task++)); hist="$TMP_BASE/cyclic-load-$i.hist"; log="$TMP_BASE/cyclic-load-$i.log"
        run_cyclic load "$i" "$task" "$hist" "$log"
        vals="$(parse_cyclic_hist "$hist")"
        read -r load_p999 load_max load_gt1 load_gt5 load_gt10 load_avg <<<"$vals"
        printf '%s\n' "$load_p999" >>"$TMP_BASE/load_p999.dat"; printf '%s\n' "$load_max" >>"$TMP_BASE/load_max.dat"
        printf '%s\n' "$load_gt1" >>"$TMP_BASE/load_gt1.dat"; printf '%s\n' "$load_gt5" >>"$TMP_BASE/load_gt5.dat"; printf '%s\n' "$load_gt10" >>"$TMP_BASE/load_gt10.dat"

        printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$idle_p999" "$load_p999" "$idle_max" "$load_max" "$x255" "$aes" "$cha" "$ram" "$disk" >>"$TMP_BASE/iterations.tsv"

        if (( i < ITERATIONS )); then
            printf '%s cooldown %ds перед следующей итерацией%s\n' "$DIM" "$COOLDOWN_SEC" "$RESET"
            sleep "$COOLDOWN_SEC" 200>&-
        fi
    done

    DONE_WORK=$TOTAL_WORK
    [[ -t 1 ]] && printf '\r%s[100%%]%s benchmark complete%s\n\n' "$BOLD" "$RESET" "$CLR" || say "[100%] benchmark complete"

    local idle_med idle_cv idle_min idle_worst idle_mean load_med load_cv load_min load_worst load_mean
    local x_med x_cv x_min x_max x_mean aes_med aes_cv aes_min aes_max aes_mean
    local cha_med cha_cv cha_min cha_max cha_mean ram_med ram_cv ram_min ram_max ram_mean
    local disk_med disk_cv disk_min disk_max disk_mean
    read -r idle_med idle_cv idle_min idle_worst idle_mean < <(calc_stats "$TMP_BASE/idle_p999.dat")
    read -r load_med load_cv load_min load_worst load_mean < <(calc_stats "$TMP_BASE/load_p999.dat")
    read -r x_med x_cv x_min x_max x_mean < <(calc_stats "$TMP_BASE/x255.dat")
    read -r aes_med aes_cv aes_min aes_max aes_mean < <(calc_stats "$TMP_BASE/aes.dat")
    read -r cha_med cha_cv cha_min cha_max cha_mean < <(calc_stats "$TMP_BASE/cha.dat")
    read -r ram_med ram_cv ram_min ram_max ram_mean < <(calc_stats "$TMP_BASE/ram.dat")
    read -r disk_med disk_cv disk_min disk_max disk_mean < <(calc_stats "$TMP_BASE/disk.dat")

    local idle_max_all load_max_all idle_gt1_avg idle_gt5_avg idle_gt10_avg load_gt1_avg load_gt5_avg load_gt10_avg
    idle_max_all="$(max_file "$TMP_BASE/idle_max.dat")"; load_max_all="$(max_file "$TMP_BASE/load_max.dat")"
    idle_gt1_avg="$(avg_file "$TMP_BASE/idle_gt1.dat")"; idle_gt5_avg="$(avg_file "$TMP_BASE/idle_gt5.dat")"; idle_gt10_avg="$(avg_file "$TMP_BASE/idle_gt10.dat")"
    load_gt1_avg="$(avg_file "$TMP_BASE/load_gt1.dat")"; load_gt5_avg="$(avg_file "$TMP_BASE/load_gt5.dat")"; load_gt10_avg="$(avg_file "$TMP_BASE/load_gt10.dat")"

    local s_idle s_load s_imax s_lmax resp_f resp stab_f resp stab
    s_idle="$(lat_score "$idle_med" 100 10000)"
    s_load="$(lat_score "$load_med" 500 20000)"
    s_imax="$(lat_score "$idle_max_all" 2000 50000)"
    s_lmax="$(lat_score "$load_max_all" 5000 100000)"
    resp_f="$(awk -v a="$s_idle" -v b="$s_load" -v c="$s_imax" -v d="$s_lmax" 'BEGIN{printf "%.2f",a*.25+b*.45+c*.10+d*.20}')"
    stab_f="$(awk -v i="$idle_cv" -v l="$load_cv" -v x="$x_cv" -v a="$aes_cv" -v c="$cha_cv" -v r="$ram_cv" -v d="$disk_cv" 'BEGIN{v=i*.25+l*.35+x*.10+a*.075+c*.075+r*.05+d*.10; s=100-v; if(s<0)s=0;if(s>100)s=100;printf "%.2f",s}')"
    resp="$(awk -v v="$resp_f" 'BEGIN{printf "%d",v+0.5}')"; stab="$(awk -v v="$stab_f" 'BEGIN{printf "%d",v+0.5}')"

    local idle_gt1_count idle_gt5_count idle_gt10_count load_gt1_count load_gt5_count load_gt10_count
    idle_gt1_count="$(sum_file "$TMP_BASE/idle_gt1.dat")"; idle_gt5_count="$(sum_file "$TMP_BASE/idle_gt5.dat")"; idle_gt10_count="$(sum_file "$TMP_BASE/idle_gt10.dat")"
    load_gt1_count="$(sum_file "$TMP_BASE/load_gt1.dat")"; load_gt5_count="$(sum_file "$TMP_BASE/load_gt5.dat")"; load_gt10_count="$(sum_file "$TMP_BASE/load_gt10.dat")"

    say "${BOLD}LATENCY${RESET}  ${DIM}(cyclictest p99.9; WORST = worst sample in iteration)${RESET}"
    printf '%-5s %10s %10s %10s %3s\n' "ITER" "IDLE" "LOAD" "WORST" ""
    printf '%s\n' "---------------------------------------------"
    while IFS=$'\t' read -r ri r_idle r_load r_imax r_lmax r_x r_a r_c r_r r_d; do
        local r_worst flag
        r_worst="$(awk -v a="$r_imax" -v b="$r_lmax" 'BEGIN{print (a>b?a:b)}')"
        flag="$(anomaly_flag "$r_idle" "$r_load" "$r_x" "$r_a" "$r_c" "$r_r" "$r_d" "$idle_med" "$load_med" "$x_med" "$aes_med" "$cha_med" "$ram_med" "$disk_med")"
        printf '%-5s %10s %10s %10s %3s\n' "$ri" "$(fmt_latency_us "$r_idle")" "$(fmt_latency_us "$r_load")" "$(fmt_latency_us "$r_worst")" "$flag"
    done <"$TMP_BASE/iterations.tsv"

    say ""
    say "${BOLD}PERFORMANCE${RESET}"
    printf '%-5s %10s %10s %10s %10s %10s %3s\n' "ITER" "X25519" "AES" "CHACHA" "RAM" "DISK" ""
    printf '%s\n' "--------------------------------------------------------------------"
    while IFS=$'\t' read -r ri r_idle r_load r_imax r_lmax r_x r_a r_c r_r r_d; do
        local flag
        flag="$(anomaly_flag "$r_idle" "$r_load" "$r_x" "$r_a" "$r_c" "$r_r" "$r_d" "$idle_med" "$load_med" "$x_med" "$aes_med" "$cha_med" "$ram_med" "$disk_med")"
        printf '%-5s %10s %10s %10s %10s %10s %3s\n' \
            "$ri" "$(fmt_x25519 "$r_x")" "$(fmt_crypto "$r_a")" "$(fmt_crypto "$r_c")" "$(fmt_ram "$r_r")" "$(fmt_latency_ms "$r_d")" "$flag"
    done <"$TMP_BASE/iterations.tsv"

    say ""
    local worst_all
    worst_all="$(awk -v a="$idle_max_all" -v b="$load_max_all" 'BEGIN{print (a>b?a:b)}')"

    say "${BOLD}RESULT${RESET}  ${DIM}(median of $ITERATIONS iterations)${RESET}"
    printf '  RESP  '; color_score "$resp"; printf '      STAB  '; color_score "$stab"; printf '\n\n'
    printf '  %-10s idle %-9s  load %-9s  worst %s\n' "Latency" "$(fmt_latency_us "$idle_med")" "$(fmt_latency_us "$load_med")" "$(fmt_latency_us "$worst_all")"
    printf '  %-10s X25  %-9s  AES  %-9s  CHA   %s\n' "Crypto" "$(fmt_x25519 "$x_med")" "$(fmt_crypto "$aes_med")" "$(fmt_crypto "$cha_med")"
    printf '  %-10s RAM  %-9s  disk %s\n' "System" "$(fmt_ram "$ram_med")" "$(fmt_latency_ms "$disk_med")"

    say ""
    say "${BOLD}TAIL${RESET}  ${DIM}(spike counts across all $ITERATIONS iterations)${RESET}"
    printf '             >1ms     >5ms    >10ms    worst\n'
    printf '  Idle  %9s %8s %8s %10s\n' "$idle_gt1_count" "$idle_gt5_count" "$idle_gt10_count" "$(fmt_latency_us "$idle_max_all")"
    printf '  Load  %9s %8s %8s %10s\n' "$load_gt1_count" "$load_gt5_count" "$load_gt10_count" "$(fmt_latency_us "$load_max_all")"

    say ""
    say "${BOLD}VARIATION${RESET}  ${DIM}(CV between iterations)${RESET}"
    printf '  Idle %3s%%   Load %3s%%   Disk %3s%%   X25519 %3s%%   AES %3s%%   ChaCha %3s%%   RAM %3s%%\n' \
        "$(fmt_cv "$idle_cv")" "$(fmt_cv "$load_cv")" "$(fmt_cv "$disk_cv")" "$(fmt_cv "$x_cv")" "$(fmt_cv "$aes_cv")" "$(fmt_cv "$cha_cv")" "$(fmt_cv "$ram_cv")"

    say ""
    say "${DIM}! marks an iteration with a large deviation from the run median. Lower latency/disk is better; higher crypto/RAM is better.${RESET}"

}

main "$@"
