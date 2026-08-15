#!/usr/bin/env bash
# VPS responsiveness benchmark for Debian 13 / Ubuntu
# Local-only benchmark traffic: CPU/scheduler/crypto/MEM/storage.

set -u
set -o pipefail
export LC_ALL=C
export LANG=C
umask 077

SCRIPT_VERSION="2.0.0"
ITERATIONS="${VPSBENCH_ITERATIONS:-6}"
CYCLIC_SEC="${VPSBENCH_CYCLIC_SEC:-45}"
CRYPTO_SEC="${VPSBENCH_CRYPTO_SEC:-5}"
CPU_SEC="${VPSBENCH_CPU_SEC:-8}"
RAM_SEC="${VPSBENCH_RAM_SEC:-8}"
DISK_SEC="${VPSBENCH_DISK_SEC:-10}"
COOLDOWN_SEC="${VPSBENCH_COOLDOWN_SEC:-5}"
HIST_MAX_US="${VPSBENCH_HIST_MAX_US:-100000}"
FIO_SIZE_MB="${VPSBENCH_FIO_SIZE_MB:-256}"
MEM_BLOCK_REQUEST_MIB="${VPSBENCH_MEM_MIB:-256}"
LOAD_SLICE_MS="${VPSBENCH_LOAD_SLICE_MS:-1}"
LOAD_CPU_METHOD="int64"
WARMUP_SEC=1
TASKS_PER_ITER=10
DEBUG_MODE=0
DEBUG_JSON=""
DEBUG_JSON_CREATED=0
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
LOCK_FILE=""
RUN_BOOT_ID=""
RUN_START_TICKS=""
BENCH_CPU=""
BENCH_PREFIX=()
AFFINITY_ACTIVE=0
SINGLE_CORE_COMPARABLE=0
MEM_BLOCK_MIB=0
MEM_BLOCK_REDUCED=0
CGROUP_CPU_STAT=""
DIAG_START_EPOCH=0
CPU_TOTAL_START=0
CPU_STEAL_START=0
CG_NR_THROTTLED_START=0
CG_THROTTLED_USEC_START=0

usage() {
    cat <<'EOF'
Usage: vpsbench.sh [--debug] [--help]

  --debug   Save one compact JSON file with per-iteration data, aggregates and scoring inputs.
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

    if (( DEBUG_MODE == 1 && DEBUG_JSON_CREATED == 0 && RUN_COMPLETED == 0 )) && [[ -n "${TMP_BASE:-}" && -d "$TMP_BASE" ]]; then
        if create_debug_json "partial"; then
            info "Partial debug data: $DEBUG_JSON"
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

    local lock_dir=""

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

need_cmds=(cyclictest stress-ng sysbench fio openssl jq flock taskset)
declare -A PKG_FOR=(
    [cyclictest]="rt-tests"
    [stress-ng]="stress-ng"
    [sysbench]="sysbench"
    [fio]="fio"
    [openssl]="openssl"
    [jq]="jq"
    [flock]="util-linux"
    [taskset]="util-linux"
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
VPSBENCH_MEM_MIB $MEM_BLOCK_REQUEST_MIB 64 256
VPSBENCH_LOAD_SLICE_MS $LOAD_SLICE_MS 1 100
EOF

    # sysbench requires a power-of-two block size. Restricting the public knob
    # to 64/128/256 MiB keeps results reasonably comparable and avoids OOM risk.
    case "$MEM_BLOCK_REQUEST_MIB" in
        64|128|256) ;;
        *) die "VPSBENCH_MEM_MIB должен быть 64, 128 или 256: $MEM_BLOCK_REQUEST_MIB" ;;
    esac
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

setup_affinity() {
    local allowed first vcpus
    vcpus="$(nproc)"
    allowed="$(awk '/^Cpus_allowed_list:/ {print $2; exit}' /proc/self/status 2>/dev/null || true)"
    first="${allowed%%,*}"
    first="${first%%-*}"

    if [[ "$first" =~ ^[0-9]+$ ]] && taskset -c "$first" true >/dev/null 2>&1; then
        BENCH_CPU="$first"
        BENCH_PREFIX=(taskset -c "$BENCH_CPU")
        AFFINITY_ACTIVE=1
        SINGLE_CORE_COMPARABLE=1
        info "Single-vCPU affinity: CPU $BENCH_CPU (allowed: ${allowed:-unknown})"
    elif (( vcpus == 1 )); then
        BENCH_CPU="${first:-0}"
        BENCH_PREFIX=()
        AFFINITY_ACTIVE=0
        SINGLE_CORE_COMPARABLE=1
        warn "taskset affinity недоступна, но системе виден только 1 vCPU; сравнение остаётся одноядерным"
    else
        BENCH_CPU="n/a"
        BENCH_PREFIX=()
        AFFINITY_ACTIVE=0
        SINGLE_CORE_COMPARABLE=0
        warn "Не удалось закрепить тесты за одним vCPU: multi-vCPU LATENCY/profile scores будут N/A"
    fi
}

choose_memory_block() {
    local avail reserve=128 block
    avail="$(awk '/MemAvailable:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || true)"
    [[ "$avail" =~ ^[0-9]+$ ]] || avail=0
    block="$MEM_BLOCK_REQUEST_MIB"

    # Keep at least ~128 MiB available on small VPSes. 256 MiB is preferred
    # because it is much less likely to fit in a shared LLC than the old 64 MiB
    # working set. Fallbacks remain powers of two as required by sysbench.
    while (( block > 64 && avail > 0 && avail < block + reserve )); do
        block=$(( block / 2 ))
        MEM_BLOCK_REDUCED=1
    done
    MEM_BLOCK_MIB="$block"

    if (( MEM_BLOCK_REDUCED == 1 )); then
        warn "MEM working set уменьшен до ${MEM_BLOCK_MIB} MiB (MemAvailable ${avail} MiB)"
    elif (( avail > 0 && avail < MEM_BLOCK_MIB + 64 )); then
        warn "Низкий MemAvailable (${avail} MiB) для MEM ${MEM_BLOCK_MIB} MiB; возможен reclaim"
    else
        info "MEM working set: ${MEM_BLOCK_MIB} MiB sequential read (MemAvailable ${avail:-0} MiB)"
    fi
}

find_cgroup_cpu_stat() {
    local rel path
    rel="$(awk -F: '$1=="0" {print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
    if [[ -n "$rel" ]]; then
        path="/sys/fs/cgroup${rel%/}/cpu.stat"
        [[ "$rel" == "/" ]] && path="/sys/fs/cgroup/cpu.stat"
        if [[ -r "$path" ]]; then
            CGROUP_CPU_STAT="$path"
            return 0
        fi
    fi
    if [[ -r /sys/fs/cgroup/cpu.stat ]]; then
        CGROUP_CPU_STAT="/sys/fs/cgroup/cpu.stat"
        return 0
    fi
    CGROUP_CPU_STAT=""
}

read_cpu_totals() {
    local cpu="${1:-}"
    local row="cpu"
    [[ "$cpu" =~ ^[0-9]+$ ]] && row="cpu${cpu}"
    awk -v row="$row" '$1==row {
        total=0;
        for (i=2; i<=9 && i<=NF; i++) total+=$i;
        printf "%.0f %.0f\n", total, ($9+0);
        exit
    }' /proc/stat 2>/dev/null
}

read_cgroup_value() {
    local key="$1" file="$2"
    [[ -r "$file" ]] || { printf '0'; return 0; }
    awk -v k="$key" '$1==k {print $2; found=1; exit} END{if(!found) print 0}' "$file" 2>/dev/null
}

start_host_diagnostics() {
    local vals
    DIAG_START_EPOCH="$(date +%s)"
    vals="$(read_cpu_totals "$BENCH_CPU")"
    read -r CPU_TOTAL_START CPU_STEAL_START <<<"${vals:-0 0}"
    find_cgroup_cpu_stat
    if [[ -n "$CGROUP_CPU_STAT" ]]; then
        CG_NR_THROTTLED_START="$(read_cgroup_value nr_throttled "$CGROUP_CPU_STAT")"
        CG_THROTTLED_USEC_START="$(read_cgroup_value throttled_usec "$CGROUP_CPU_STAT")"
    fi
}

run_warmup() {
    local mem_total=17592186044416
    info "Короткий warm-up CPU/crypto/MEM (не входит в измерения)"
    "${BENCH_PREFIX[@]}" openssl speed -elapsed -seconds "$WARMUP_SEC" -mr ecdhx25519 >/dev/null 2>&1 || true
    "${BENCH_PREFIX[@]}" openssl speed -elapsed -seconds "$WARMUP_SEC" -bytes 1400 -mr -evp aes-128-gcm -aead >/dev/null 2>&1 || true
    "${BENCH_PREFIX[@]}" openssl speed -elapsed -seconds "$WARMUP_SEC" -bytes 16384 -mr -evp aes-128-gcm -aead >/dev/null 2>&1 || true
    "${BENCH_PREFIX[@]}" openssl speed -elapsed -seconds "$WARMUP_SEC" -bytes 1400 -mr -evp chacha20-poly1305 -aead >/dev/null 2>&1 || true
    "${BENCH_PREFIX[@]}" openssl speed -elapsed -seconds "$WARMUP_SEC" -bytes 16384 -mr -evp chacha20-poly1305 -aead >/dev/null 2>&1 || true
    "${BENCH_PREFIX[@]}" sysbench cpu --threads=1 --time="$WARMUP_SEC" --events=0 --cpu-max-prime=20000 run >/dev/null 2>&1 || true
    "${BENCH_PREFIX[@]}" sysbench memory --threads=1 --time="$WARMUP_SEC" --events=0 \
        --memory-block-size="${MEM_BLOCK_MIB}M" --memory-total-size="$mem_total" \
        --memory-access-mode=seq --memory-oper=read run >/dev/null 2>&1 || true
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
# Five crypto tests: X25519, AES/ChaCha at 1400 B and 16 KiB.
PER_ITER_WORK=$(( CYCLIC_SEC * 2 + CRYPTO_SEC * 5 + CPU_SEC + RAM_SEC + DISK_SEC ))
TOTAL_WORK=$(( PER_ITER_WORK * ITERATIONS ))
WARMUP_WORK=$(( WARMUP_SEC * 7 + COOLDOWN_SEC ))
EST_RUNTIME=$(( TOTAL_WORK + COOLDOWN_SEC * (ITERATIONS - 1) + WARMUP_WORK + 2 ))
DONE_WORK=0
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
CYCLIC_NATURAL_PM=0
CYCLIC_PM_MODE="unsupported"
setup_cyclic_cmd() {
    local help_text
    cyclic_cmd=(cyclictest --policy=other -q -t1 -i1000 -h "$HIST_MAX_US")

    # Both --default-system and the legacy --laptop mode keep cyclictest from
    # forcing /dev/cpu_dma_latency to zero. Prefer the explicit modern option.
    help_text="$(cyclictest --help 2>&1 || true)"
    if grep -F -- '--default-system' <<<"$help_text" >/dev/null; then
        cyclic_cmd+=(--default-system)
        CYCLIC_NATURAL_PM=1
        CYCLIC_PM_MODE="default-system"
        info "cyclictest power mode: --default-system"
    elif grep -F -- '--laptop' <<<"$help_text" >/dev/null; then
        cyclic_cmd+=(--laptop)
        CYCLIC_NATURAL_PM=1
        CYCLIC_PM_MODE="laptop-fallback"
        warn "cyclictest: используется legacy fallback --laptop вместо --default-system"
    else
        CYCLIC_NATURAL_PM=0
        CYCLIC_PM_MODE="unsupported"
        warn "cyclictest не умеет сохранить естественный power-management: LATENCY/profile/STABILITY будут N/A"
    fi
}

run_cyclic() {
    local mode="$1" iter="$2" task="$3" hist="$4" log="$5"
    local name="latency idle"
    local stress_log="$TMP_BASE/stress-${iter}.log"
    STRESS_PID=""

    if [[ "$mode" == "load" ]]; then
        name="latency CPU 50% smooth"
        "${BENCH_PREFIX[@]}" stress-ng --cpu 1 --cpu-load 50 \
            --cpu-load-slice "$LOAD_SLICE_MS" --cpu-method "$LOAD_CPU_METHOD" \
            --timeout "$((CYCLIC_SEC + 4))s" --quiet 200>&- </dev/null >"$stress_log" 2>&1 &
        STRESS_PID=$!
        record_pid_state "$TMP_BASE/.stress-pid" "$STRESS_PID"
        sleep 1 200>&-
    fi

    if ! run_timed_capture "$CYCLIC_SEC" "$iter" "$task" "$name" "$log" \
        "${BENCH_PREFIX[@]}" "${cyclic_cmd[@]}" -D "${CYCLIC_SEC}s" --histfile="$hist"; then
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
        "${BENCH_PREFIX[@]}" openssl speed -elapsed -seconds "$CRYPTO_SEC" -mr ecdhx25519 \
        || die "OpenSSL X25519 benchmark завершился ошибкой: $out"
    value="$(awk -F: '$1=="+F5" {print $4}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать X25519 result: $out"
    LAST_VALUE="$value"
}

run_crypto_evp() {
    local algo="$1" bytes="$2" label="$3" iter="$4" task="$5" out="$6" value
    run_timed_capture "$CRYPTO_SEC" "$iter" "$task" "$label" "$out" \
        "${BENCH_PREFIX[@]}" openssl speed -elapsed -seconds "$CRYPTO_SEC" \
        -bytes "$bytes" -mr -evp "$algo" -aead \
        || die "OpenSSL $algo/$bytes benchmark завершился ошибкой: $out"
    value="$(awk -F: '$1=="+F" {print $NF}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать $algo/$bytes result: $out"
    LAST_VALUE="$value"
}

run_cpu() {
    local iter="$1" task="$2" out="$3" value
    run_timed_capture "$CPU_SEC" "$iter" "$task" "CPU sysbench 1T" "$out" \
        "${BENCH_PREFIX[@]}" sysbench cpu --threads=1 --time="$CPU_SEC" --events=0 --cpu-max-prime=20000 run \
        || die "sysbench CPU завершился ошибкой: $out"
    value="$(awk '/events per second:/ {print $4}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать sysbench CPU result: $out"
    LAST_VALUE="$value"
}

run_memory() {
    local iter="$1" task="$2" out="$3" value
    run_timed_capture "$RAM_SEC" "$iter" "$task" "MEM ${MEM_BLOCK_MIB}M seq read" "$out" \
        "${BENCH_PREFIX[@]}" sysbench memory --threads=1 --time="$RAM_SEC" --events=0 \
        --memory-block-size="${MEM_BLOCK_MIB}M" --memory-total-size=17592186044416 \
        --memory-access-mode=seq --memory-oper=read run || die "sysbench memory завершился ошибкой: $out"
    value="$(awk -F'[()]' '/MiB transferred/ {split($2,a," "); print a[1]}' "$out" | tail -n1)"
    is_num "$value" || die "Не удалось разобрать sysbench memory result: $out"
    LAST_VALUE="$value"
}

LAST_LAT_P999=""
LAST_LAT_MAX=""
LAST_LAT_GT1=""
LAST_LAT_GT5=""
LAST_LAT_GT10=""
LAST_LAT_AVG=""

measure_latency_mode() {
    local mode="$1" iter="$2" task="$3" hist log vals
    hist="$TMP_BASE/cyclic-${mode}-${iter}.hist"
    log="$TMP_BASE/cyclic-${mode}-${iter}.log"
    run_cyclic "$mode" "$iter" "$task" "$hist" "$log"
    vals="$(parse_cyclic_hist "$hist")"
    read -r LAST_LAT_P999 LAST_LAT_MAX LAST_LAT_GT1 LAST_LAT_GT5 LAST_LAT_GT10 LAST_LAT_AVG <<<"$vals"

    printf '%s\n' "$LAST_LAT_P999" >>"$TMP_BASE/${mode}_p999.dat"
    printf '%s\n' "$LAST_LAT_MAX" >>"$TMP_BASE/${mode}_max.dat"
    printf '%s\n' "$LAST_LAT_GT1" >>"$TMP_BASE/${mode}_gt1.dat"
    printf '%s\n' "$LAST_LAT_GT5" >>"$TMP_BASE/${mode}_gt5.dat"
    printf '%s\n' "$LAST_LAT_GT10" >>"$TMP_BASE/${mode}_gt10.dat"
}

run_perf_metric() {
    local metric="$1" iter="$2" task="$3"
    case "$metric" in
        x255)
            run_crypto_x25519 "$iter" "$task" "$TMP_BASE/x255-$iter.log"
            ;;
        aes1400)
            run_crypto_evp aes-128-gcm 1400 "AES-GCM 1.4K" "$iter" "$task" "$TMP_BASE/aes1400-$iter.log"
            ;;
        aes16k)
            run_crypto_evp aes-128-gcm 16384 "AES-GCM 16K" "$iter" "$task" "$TMP_BASE/aes16k-$iter.log"
            ;;
        cha1400)
            run_crypto_evp chacha20-poly1305 1400 "ChaCha20 1.4K" "$iter" "$task" "$TMP_BASE/cha1400-$iter.log"
            ;;
        cha16k)
            run_crypto_evp chacha20-poly1305 16384 "ChaCha20 16K" "$iter" "$task" "$TMP_BASE/cha16k-$iter.log"
            ;;
        cpu)
            run_cpu "$iter" "$task" "$TMP_BASE/cpu-$iter.log"
            ;;
        ram)
            run_memory "$iter" "$task" "$TMP_BASE/ram-$iter.log"
            ;;
        *) die "Внутренняя ошибка: неизвестная performance-метрика $metric" ;;
    esac
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
        "${BENCH_PREFIX[@]}" fio --name=vpsbench --filename="$FIO_FILE" --size="${FIO_SIZE_MB}M" \
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

fmt_duration_us() {
    awk -v u="$1" 'function trim(s){if(index(s,".")){sub(/0+$/, "", s);sub(/\.$/, "", s)}return s}
        BEGIN {
            if (u < 1000) printf "%.0fus", u;
            else if (u < 1000000) {s=sprintf("%.1f",u/1000); printf "%sms",trim(s)}
            else {s=sprintf("%.2f",u/1000000); printf "%ss",trim(s)}
        }'
}

fmt_cv() { awk -v v="$1" 'BEGIN {printf "%.0f",v}' ; }
fmt_percent() {
    awk -v v="$1" 'function trim(s){if(index(s,".")){sub(/0+$/, "", s);sub(/\.$/, "", s)}return s}
        BEGIN {s=(v<10?sprintf("%.1f",v):sprintf("%.0f",v)); printf "%s%%",trim(s)}'
}
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
    # P = anomaly in a scored performance metric; D = disk-only anomaly.
    # Disk is diagnostic and must never turn a score/stability metric red.
    awk \
        -v x="$1" -v a1="$2" -v a16="$3" -v c1="$4" -v c16="$5" -v cpu="$6" -v m="$7" -v d="$8" \
        -v xm="$9" -v a1m="${10}" -v a16m="${11}" -v c1m="${12}" -v c16m="${13}" \
        -v cpum="${14}" -v mm="${15}" -v dm="${16}" 'BEGIN {
        dt=(dm*2.5 > dm+0.5 ? dm*2.5 : dm+0.5);
        pbad=((xm>0 && x<xm*.8) || (a1m>0 && a1<a1m*.8) || (a16m>0 && a16<a16m*.8) ||
              (c1m>0 && c1<c1m*.8) || (c16m>0 && c16<c16m*.8) ||
              (cpum>0 && cpu<cpum*.8) || (mm>0 && m<mm*.8));
        dbad=(d>dt);
        if (pbad && dbad) printf "PD";
        else if (pbad) printf "P";
        else if (dbad) printf "D";
    }'
}

vpn_higher_score() {
    # Higher is better. Piecewise 2026 mainstream-VPS scale:
    # <=t1 poor/trash (0), t2 questionable (45), t3 normal (75),
    # t4 excellent (90), >=t5 practical near-term ceiling (100).
    awk -v x="$1" -v t1="$2" -v t2="$3" -v t3="$4" -v t4="$5" -v t5="$6" 'BEGIN {
        if (x<=t1) s=0;
        else if (x<=t2) s=(x-t1)*(45/(t2-t1));
        else if (x<=t3) s=45+(x-t2)*(30/(t3-t2));
        else if (x<=t4) s=75+(x-t3)*(15/(t4-t3));
        else if (x<t5) s=90+(x-t4)*(10/(t5-t4));
        else s=100;
        if(s<0)s=0;if(s>100)s=100; printf "%.2f",s
    }'
}

vpn_lower_score() {
    # Lower is better. Piecewise absolute VPN-oriented scale:
    # <=t1 ideal (100), t2 excellent (90), t3 normal (75),
    # t4 questionable (45), >=t5 poor (0).
    awk -v x="$1" -v t1="$2" -v t2="$3" -v t3="$4" -v t4="$5" -v t5="$6" 'BEGIN {
        if (x<=t1) s=100;
        else if (x<=t2) s=100-(x-t1)*(10/(t2-t1));
        else if (x<=t3) s=90-(x-t2)*(15/(t3-t2));
        else if (x<=t4) s=75-(x-t3)*(30/(t4-t3));
        else if (x<t5) s=45-(x-t4)*(45/(t5-t4));
        else s=0;
        if(s<0)s=0;if(s>100)s=100; printf "%.2f",s
    }'
}

drift_from_median() {
    # Maximum absolute deviation of per-iteration p99.9 from its median.
    awk -v med="$1" -v mn="$2" -v mx="$3" 'BEGIN {
        a=med-mn; b=mx-med; if(a<0)a=-a; if(b<0)b=-b;
        printf "%.3f", (a>b?a:b)
    }'
}

drop_from_median() {
    # Worst throughput drop relative to the median; higher throughput is better.
    awk -v med="$1" -v mn="$2" 'BEGIN {
        if (med<=0 || mn>=med) d=0; else d=(med-mn)*100/med;
        if(d<0)d=0; printf "%.3f",d
    }'
}

color_score() {
    local v="$1"
    if (( v >= 90 )); then printf '%s%d%s' "$GREEN$BOLD" "$v" "$RESET"
    elif (( v >= 75 )); then printf '%s%d%s' "$CYAN$BOLD" "$v" "$RESET"
    elif (( v >= 45 )); then printf '%s%d%s' "$YELLOW$BOLD" "$v" "$RESET"
    else printf '%s%d%s' "$RED$BOLD" "$v" "$RESET"
    fi
}


version_line() {
    local out
    out="$("$@" 2>&1 || true)"
    out="${out%%$'\n'*}"
    printf '%s' "${out:-unknown}"
}

create_debug_json() {
    local state="${1:-complete}" debug_dir stamp base tmp_json tmp_full
    local natural_pm_json affinity_json single_core_json mem_reduced_json latency_ready_json
    local it_file cyc_file
    (( DEBUG_MODE == 1 )) || return 0
    (( DEBUG_JSON_CREATED == 0 )) || return 0
    [[ -n "${TMP_BASE:-}" && -d "$TMP_BASE" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 1

    debug_dir="${VPSBENCH_DEBUG_DIR:-/var/tmp}"
    [[ -d "$debug_dir" && -w "$debug_dir" ]] || debug_dir="${TMPDIR:-/tmp}"
    [[ -d "$debug_dir" && -w "$debug_dir" ]] || return 1

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    base="vpsbench-debug-${SCRIPT_VERSION}-${state}-${stamp}-$$.json"
    DEBUG_JSON="$debug_dir/$base"
    tmp_json="$TMP_BASE/debug-base.json"
    tmp_full="$TMP_BASE/debug-full.json"
    it_file="$TMP_BASE/iterations.tsv"
    cyc_file="$TMP_BASE/cyclic-details.tsv"
    [[ -e "$it_file" ]] || : >"$it_file"
    [[ -e "$cyc_file" ]] || : >"$cyc_file"

    if (( CYCLIC_NATURAL_PM == 1 )); then natural_pm_json=true; else natural_pm_json=false; fi
    if (( AFFINITY_ACTIVE == 1 )); then affinity_json=true; else affinity_json=false; fi
    if (( SINGLE_CORE_COMPARABLE == 1 )); then single_core_json=true; else single_core_json=false; fi
    if (( MEM_BLOCK_REDUCED == 1 )); then mem_reduced_json=true; else mem_reduced_json=false; fi
    if (( CYCLIC_NATURAL_PM == 1 && SINGLE_CORE_COMPARABLE == 1 )); then latency_ready_json=true; else latency_ready_json=false; fi

    jq -n \
        --arg schema "3" \
        --arg version "$SCRIPT_VERSION" \
        --arg state "$state" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg os "${os_name:-unknown}" \
        --arg kernel "$(uname -r 2>/dev/null || printf unknown)" \
        --arg arch "$(uname -m 2>/dev/null || printf unknown)" \
        --arg virt "${virt:-unknown}" \
        --arg cpu_model "${model:-unknown}" \
        --arg isa "$(isa_short)" \
        --arg bench_cpu "${BENCH_CPU:-unknown}" \
        --arg allowed_cpus "$(awk '/^Cpus_allowed_list:/ {print $2; exit}' /proc/self/status 2>/dev/null || printf unknown)" \
        --arg cyclic_pm_mode "$CYCLIC_PM_MODE" \
        --arg load_method "$LOAD_CPU_METHOD" \
        --arg fio_engine "$fio_engine" \
        --arg cgroup_cpu_stat "${CGROUP_CPU_STAT:-}" \
        --arg cyclic_version "$(version_line cyclictest --version)" \
        --arg stress_version "$(version_line stress-ng --version)" \
        --arg sysbench_version "$(version_line sysbench --version)" \
        --arg fio_version "$(version_line fio --version)" \
        --arg openssl_version "$(version_line openssl version)" \
        --argjson uid "$EUID" \
        --argjson vcpu "$(nproc)" \
        --argjson mem_mib "${mem_mb:-0}" \
        --argjson iterations_cfg "$ITERATIONS" \
        --argjson cyclic_sec "$CYCLIC_SEC" \
        --argjson crypto_sec "$CRYPTO_SEC" \
        --argjson cpu_sec "$CPU_SEC" \
        --argjson mem_sec "$RAM_SEC" \
        --argjson disk_sec "$DISK_SEC" \
        --argjson cooldown_sec "$COOLDOWN_SEC" \
        --argjson hist_max_us "$HIST_MAX_US" \
        --argjson fio_size_mib "$FIO_SIZE_MB" \
        --argjson mem_requested_mib "$MEM_BLOCK_REQUEST_MIB" \
        --argjson mem_actual_mib "${MEM_BLOCK_MIB:-0}" \
        --argjson load_slice_ms "$LOAD_SLICE_MS" \
        --argjson natural_pm "$natural_pm_json" \
        --argjson affinity "$affinity_json" \
        --argjson single_core "$single_core_json" \
        --argjson mem_reduced "$mem_reduced_json" \
        --argjson latency_ready "$latency_ready_json" \
        --rawfile it "$it_file" \
        --rawfile cyc "$cyc_file" '
        def rows($s): $s | split("\n") | map(select(length > 0) | split("\t"));
        (rows($it)) as $i |
        (rows($cyc)) as $c |
        ([($i|length),($c|length)] | min) as $n |
        {
          schema_version: ($schema|tonumber),
          vpsbench_version: $version,
          state: $state,
          timestamp_utc: $timestamp,
          system: {
            os: $os, kernel: $kernel, arch: $arch, virtualization: $virt,
            cpu_model: $cpu_model, vcpu: $vcpu, mem_mib: $mem_mib, isa: $isa,
            benchmark_cpu: $bench_cpu, allowed_cpus: $allowed_cpus
          },
          versions: {
            cyclictest: $cyclic_version, stress_ng: $stress_version,
            sysbench: $sysbench_version, fio: $fio_version, openssl: $openssl_version
          },
          config: {
            iterations: $iterations_cfg, cyclic_sec: $cyclic_sec,
            crypto_sec: $crypto_sec, cpu_sec: $cpu_sec, mem_sec: $mem_sec,
            disk_sec: $disk_sec, cooldown_sec: $cooldown_sec,
            hist_max_us: $hist_max_us, fio_size_mib: $fio_size_mib,
            fio_engine: $fio_engine,
            mem_working_set_requested_mib: $mem_requested_mib,
            mem_working_set_actual_mib: $mem_actual_mib,
            mem_working_set_reduced: $mem_reduced,
            load: {cpu_percent:50, workers:1, method:$load_method, slice_ms:$load_slice_ms},
            crypto_buffer_bytes: [1400,16384]
          },
          compatibility: {
            cyclic_power_mode: $cyclic_pm_mode,
            natural_power_management: $natural_pm,
            affinity_active: $affinity,
            single_vcpu_comparable: $single_core,
            latency_comparable: $latency_ready,
            latency_requirement: "natural power management plus a single-vCPU test domain"
          },
          diagnostics_source: {cgroup_cpu_stat: (if $cgroup_cpu_stat=="" then null else $cgroup_cpu_stat end)},
          completed_iterations: $n,
          iterations: [range(0;$n) as $k |
            ($i[$k]) as $r | ($c[$k]) as $d |
            {
              iteration: ($r[0]|tonumber),
              latency: {
                idle: {p99_9_us:($d[1]|tonumber), avg_us:($d[2]|tonumber), max_us:($d[3]|tonumber), ge_1ms:($d[4]|tonumber), ge_5ms:($d[5]|tonumber), ge_10ms:($d[6]|tonumber)},
                load: {p99_9_us:($d[7]|tonumber), avg_us:($d[8]|tonumber), max_us:($d[9]|tonumber), ge_1ms:($d[10]|tonumber), ge_5ms:($d[11]|tonumber), ge_10ms:($d[12]|tonumber)}
              },
              crypto: {
                x25519_ops_s:($r[5]|tonumber),
                aes_gcm_1400_B_s:($r[6]|tonumber), aes_gcm_16k_B_s:($r[7]|tonumber),
                chacha20_poly1305_1400_B_s:($r[8]|tonumber), chacha20_poly1305_16k_B_s:($r[9]|tonumber)
              },
              system: {cpu_events_s:($r[10]|tonumber), mem_MiB_s:($r[11]|tonumber)},
              disk_diagnostic: {p99_9_ms:($r[12]|tonumber)}
            }
          ]
        }' >"$tmp_json" || return 1

    if (( RUN_COMPLETED == 1 )); then
        jq \
            --argjson latency_comparable "$latency_comparable" \
            --arg latency_reason "$latency_compat_reason" \
            --argjson idle_med "$idle_med" --argjson idle_cv "$idle_cv" --argjson idle_min "$idle_min" --argjson idle_max_p999 "$idle_worst" --argjson idle_mean "$idle_mean" --argjson idle_drift "$idle_drift_us" \
            --argjson load_med "$load_med" --argjson load_cv "$load_cv" --argjson load_min "$load_min" --argjson load_max_p999 "$load_worst" --argjson load_mean "$load_mean" --argjson load_drift "$load_drift_us" \
            --argjson idle_p9999 "$idle_p9999" --argjson idle_max "$idle_max_all" --argjson idle_ge1 "$idle_gt1_count" --argjson idle_ge5 "$idle_gt5_count" --argjson idle_ge10 "$idle_gt10_count" --argjson idle_samples "$idle_samples" \
            --argjson load_p9999 "$load_p9999" --argjson load_max "$load_max_all" --argjson load_ge1 "$load_gt1_count" --argjson load_ge5 "$load_gt5_count" --argjson load_ge10 "$load_gt10_count" --argjson load_samples "$load_samples" \
            --argjson idle_ge5_rate "$idle_gt5_rate" --argjson load_ge5_rate "$load_gt5_rate" --argjson idle_ge10_rate "$idle_gt10_rate" --argjson load_ge10_rate "$load_gt10_rate" \
            --argjson x_med "$x_med" --argjson x_cv "$x_cv" --argjson x_min "$x_min" --argjson x_max "$x_max" --argjson x_mean "$x_mean" --argjson x_drop "$x_drop" \
            --argjson a1_med "$aes1400_med" --argjson a1_cv "$aes1400_cv" --argjson a1_min "$aes1400_min" --argjson a1_max "$aes1400_max" --argjson a1_mean "$aes1400_mean" --argjson a1_drop "$aes1400_drop" \
            --argjson a16_med "$aes16k_med" --argjson a16_cv "$aes16k_cv" --argjson a16_min "$aes16k_min" --argjson a16_max "$aes16k_max" --argjson a16_mean "$aes16k_mean" --argjson a16_drop "$aes16k_drop" \
            --argjson c1_med "$cha1400_med" --argjson c1_cv "$cha1400_cv" --argjson c1_min "$cha1400_min" --argjson c1_max "$cha1400_max" --argjson c1_mean "$cha1400_mean" --argjson c1_drop "$cha1400_drop" \
            --argjson c16_med "$cha16k_med" --argjson c16_cv "$cha16k_cv" --argjson c16_min "$cha16k_min" --argjson c16_max "$cha16k_max" --argjson c16_mean "$cha16k_mean" --argjson c16_drop "$cha16k_drop" \
            --argjson cpu_med "$cpu_med" --argjson cpu_cv "$cpu_cv" --argjson cpu_min "$cpu_min" --argjson cpu_max "$cpu_max" --argjson cpu_mean "$cpu_mean" --argjson cpu_drop "$cpu_drop" \
            --argjson mem_med "$ram_med" --argjson mem_cv "$ram_cv" --argjson mem_min "$ram_min" --argjson mem_max "$ram_max" --argjson mem_mean "$ram_mean" --argjson mem_drop "$mem_drop" \
            --argjson disk_med "$disk_med" --argjson disk_cv "$disk_cv" --argjson disk_min "$disk_min" --argjson disk_max "$disk_max" --argjson disk_mean "$disk_mean" \
            --argjson latency_score "$latency_score" --argjson crypto_score "$crypto_score" --argjson handshake_score "$handshake_score" --argjson packet_score "$packet_score" --argjson stream_score "$stream_score" \
            --argjson system_score "$system_score" --argjson xtls_score "$xtls_score" --argjson generic_score "$generic_score" --argjson stability "$stab" \
            --argjson tail_score "$tail_score" --argjson consistency_score "$consistency_score" \
            --argjson s_idle "$s_idle" --argjson s_load "$s_load" --argjson s_idle9999 "$s_idle9999" --argjson s_load9999 "$s_load9999" --argjson s_worst "$s_worst" \
            --argjson sx "$sx" --argjson sa1400 "$sa1400" --argjson sa16k "$sa16k" --argjson sc1400 "$sc1400" --argjson sc16k "$sc16k" --argjson scpu "$scpu" --argjson smem "$smem" \
            --argjson tail_idle_s "$tail_idle_s" --argjson tail_load_s "$tail_load_s" --argjson idle_spike5_s "$idle_spike5_s" --argjson load_spike5_s "$load_spike5_s" \
            --argjson idle_spike10_s "$idle_spike10_s" --argjson load_spike10_s "$load_spike10_s" --argjson tail_worst_s "$tail_worst_s" \
            --argjson idle_drift_s "$idle_drift_s" --argjson load_drift_s "$load_drift_s" --argjson perf_repeat_s "$perf_repeat_s" \
            --argjson worst_perf_drop "$worst_perf_drop" --arg worst_perf_name "$worst_perf_name" \
            --argjson steal_pct "$steal_pct" --argjson diag_duration_s "$diag_duration_s" \
            --argjson cg_nr_throttled "$cg_nr_throttled_delta" --argjson cg_throttled_usec "$cg_throttled_usec_delta" '
            .compatibility.latency_comparable = ($latency_comparable == 1) |
            .compatibility.incompatibility_reason = (if $latency_comparable == 1 then null else $latency_reason end) |
            . + {
              aggregate: {
                latency: {
                  idle: {p99_9_median_us:$idle_med, p99_99_us:$idle_p9999, worst_us:$idle_max, samples:$idle_samples, ge_1ms:$idle_ge1, ge_5ms:$idle_ge5, ge_10ms:$idle_ge10, ge_5ms_per_million:$idle_ge5_rate, ge_10ms_per_million:$idle_ge10_rate, p99_9_drift_us:$idle_drift, p99_9_cv_percent:$idle_cv, p99_9_min_us:$idle_min, p99_9_max_us:$idle_max_p999, p99_9_mean_us:$idle_mean},
                  load: {p99_9_median_us:$load_med, p99_99_us:$load_p9999, worst_us:$load_max, samples:$load_samples, ge_1ms:$load_ge1, ge_5ms:$load_ge5, ge_10ms:$load_ge10, ge_5ms_per_million:$load_ge5_rate, ge_10ms_per_million:$load_ge10_rate, p99_9_drift_us:$load_drift, p99_9_cv_percent:$load_cv, p99_9_min_us:$load_min, p99_9_max_us:$load_max_p999, p99_9_mean_us:$load_mean}
                },
                crypto: {
                  x25519:{median:$x_med,cv_percent:$x_cv,min:$x_min,max:$x_max,mean:$x_mean,worst_drop_from_median_percent:$x_drop},
                  aes_gcm_1400:{median:$a1_med,cv_percent:$a1_cv,min:$a1_min,max:$a1_max,mean:$a1_mean,worst_drop_from_median_percent:$a1_drop},
                  aes_gcm_16k:{median:$a16_med,cv_percent:$a16_cv,min:$a16_min,max:$a16_max,mean:$a16_mean,worst_drop_from_median_percent:$a16_drop},
                  chacha20_poly1305_1400:{median:$c1_med,cv_percent:$c1_cv,min:$c1_min,max:$c1_max,mean:$c1_mean,worst_drop_from_median_percent:$c1_drop},
                  chacha20_poly1305_16k:{median:$c16_med,cv_percent:$c16_cv,min:$c16_min,max:$c16_max,mean:$c16_mean,worst_drop_from_median_percent:$c16_drop}
                },
                system: {
                  cpu:{median:$cpu_med,cv_percent:$cpu_cv,min:$cpu_min,max:$cpu_max,mean:$cpu_mean,worst_drop_from_median_percent:$cpu_drop},
                  mem:{median:$mem_med,cv_percent:$mem_cv,min:$mem_min,max:$mem_max,mean:$mem_mean,worst_drop_from_median_percent:$mem_drop}
                },
                disk_diagnostic:{median_ms:$disk_med,cv_percent:$disk_cv,min_ms:$disk_min,max_ms:$disk_max,mean_ms:$disk_mean}
              },
              scores: {
                latency:$latency_score,
                crypto_diagnostic:$crypto_score,
                handshake:$handshake_score,
                packet_crypto:$packet_score,
                stream_crypto:$stream_score,
                system:$system_score,
                profiles:{xtls_vision:$xtls_score,generic_vpn:$generic_score},
                stability:$stability,
                tail_quality:$tail_score,
                consistency:$consistency_score,
                current_subscores: {
                  latency:{idle_p99_9:$s_idle,load_p99_9:$s_load,idle_p99_99:$s_idle9999,load_p99_99:$s_load9999,worst:$s_worst},
                  crypto:{x25519:$sx,aes_gcm_1400:$sa1400,aes_gcm_16k:$sa16k,chacha20_poly1305_1400:$sc1400,chacha20_poly1305_16k:$sc16k},
                  system:{cpu:$scpu,mem:$smem},
                  tail_quality:{idle_p99_99:$tail_idle_s,load_p99_99:$tail_load_s,idle_ge_5ms:$idle_spike5_s,load_ge_5ms:$load_spike5_s,idle_ge_10ms:$idle_spike10_s,load_ge_10ms:$load_spike10_s,worst:$tail_worst_s},
                  consistency:{idle_drift:$idle_drift_s,load_drift:$load_drift_s,performance_repeatability:$perf_repeat_s},
                  performance_drop:{worst:$worst_perf_drop,worst_metric:$worst_perf_name}
                }
              },
              host_diagnostics: {
                observation_seconds:$diag_duration_s,
                cpu_steal_percent:$steal_pct,
                cgroup:{nr_throttled_delta:$cg_nr_throttled,throttled_usec_delta:$cg_throttled_usec}
              },
              scoring_model: {
                model_version:"2026-mainstream-v2",
                score_anchors:[0,45,75,90,100],
                semantics:{zero:"poor/trash relative to the target VPS class",hundred:"realistic near-term rental ceiling, not a physical maximum"},
                profiles:{
                  xtls_vision:{latency:0.50,cpu:0.25,x25519_proxy:0.10,stream_crypto_16k:0.10,mem:0.05},
                  generic_vpn:{latency:0.40,cpu:0.20,x25519_proxy:0.10,packet_crypto_1400:0.20,stream_crypto_16k:0.05,mem:0.05}
                },
                latency:{
                  weights:{idle_p99_9:0.15,load_p99_9:0.40,idle_p99_99:0.10,load_p99_99:0.30,worst:0.05},
                  lower_is_better_anchors:{
                    idle_p99_9_us:[500,1000,1500,2500,5000],load_p99_9_us:[1500,2500,4000,6000,12000],
                    idle_p99_99_us:[1500,3000,5000,10000,20000],load_p99_99_us:[3000,5000,8000,15000,30000],
                    worst_us:[5000,10000,20000,50000,100000]
                  }
                },
                performance_higher_is_better_anchors:{
                  cpu_events_s:[300,500,900,1600,2500],x25519_ops_s:[12000,18000,26000,36000,45000],
                  aes_gcm_1400_B_s:[600000000,1200000000,2200000000,3800000000,5500000000],
                  aes_gcm_16k_B_s:[1500000000,2500000000,4500000000,8500000000,12000000000],
                  chacha20_poly1305_1400_B_s:[450000000,800000000,1300000000,1900000000,2600000000],
                  chacha20_poly1305_16k_B_s:[900000000,1400000000,2000000000,3200000000,4500000000],
                  mem_MiB_s:[4096,8192,16384,28672,45056]
                },
                crypto_diagnostic:{weights:{x25519:0.20,packet_crypto:0.50,stream_crypto:0.30},packet:{aes:0.50,chacha:0.50},stream:{aes:0.50,chacha:0.50}},
                system:{weights:{cpu:0.80,mem:0.20,disk:0.00}},
                tail_quality:{
                  weights:{idle_p99_99:0.15,load_p99_99:0.35,idle_ge_5ms:0.05,load_ge_5ms:0.15,idle_ge_10ms:0.05,load_ge_10ms:0.20,worst:0.05},
                  lower_is_better_anchors:{
                    idle_ge_5ms_per_million:[2,10,50,200,500],load_ge_5ms_per_million:[10,50,150,500,1000],
                    idle_ge_10ms_per_million:[0.5,2,10,30,100],load_ge_10ms_per_million:[2,10,30,100,200]
                  }
                },
                consistency:{
                  weights:{idle_drift:0.35,load_drift:0.45,performance_repeatability:0.20},
                  performance_metric_weights:{x25519:0.15,aes_1400:0.10,aes_16k:0.10,chacha_1400:0.10,chacha_16k:0.10,cpu:0.35,mem:0.10},
                  worst_metric_share:0.20
                },
                stability:{formula:"TAIL * (0.65 + 0.35 * CONSISTENCY / 100)",scope:"short benchmark window only"},
                disk:{diagnostic_only:true,score_weight:0.00}
              }
            }' "$tmp_json" >"$tmp_full" || return 1
        mv -f -- "$tmp_full" "$tmp_json" || return 1
    fi

    cp -- "$tmp_json" "$DEBUG_JSON" || return 1
    chmod 0644 "$DEBUG_JSON" 2>/dev/null || true
    DEBUG_JSON_CREATED=1
    return 0
}

print_debug_result() {
    (( DEBUG_MODE == 1 )) || return 0
    if create_debug_json "complete"; then
        say ""
        info "Debug data: $DEBUG_JSON"
        info "Upload this single JSON file for score/weight analysis."
    else
        warn "Could not create debug JSON"
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
    setup_affinity
    setup_cyclic_cmd
    choose_fio_engine
    choose_memory_block

    local os_name virt model mem_mb load1
    # shellcheck disable=SC1091
    . /etc/os-release
    os_name="${PRETTY_NAME:-${ID:-unknown}}"
    virt="$(systemd-detect-virt 2>/dev/null || true)"; [[ -n "$virt" && "$virt" != "none" ]] || virt="unknown"
    model="$(cpu_model)"; [[ -n "$model" ]] || model="unknown"
    mem_mb="$(awk '/MemTotal/ {printf "%.0f",$2/1024}' /proc/meminfo)"
    load1="$(awk '{print $1}' /proc/loadavg)"

    say ""
    say "${BOLD}VPSBench VPN host ${SCRIPT_VERSION}${RESET}"
    say "OS:      $os_name"
    say "Kernel:  $(uname -r) / $(uname -m)"
    say "Virt:    $virt"
    say "CPU:     $model"
    say "vCPU:    $(nproc)    Bench CPU: $BENCH_CPU    Mem: ${mem_mb} MiB    ISA: $(isa_short)"
    say "Load1:   $load1"
    [[ "$virt" == "wsl" ]] && say "Scope:   WSL2 is a local single-vCPU reference, not a provider/VPS result"
    say "Plan:    ${ITERATIONS} итераций, ~${PER_ITER_WORK}s измерений/итерация (~$((EST_RUNTIME/60))m$((EST_RUNTIME%60))s + preparation)"
    say "Latency: cyclictest on one vCPU; load = stress-ng ${LOAD_CPU_METHOD}, 50%, ${LOAD_SLICE_MS}ms slice, same vCPU"
    say "Crypto:  X25519 + AES/ChaCha at 1400 B and 16 KiB (CPU proxies)"
    say "MEM:     ${MEM_BLOCK_MIB} MiB sequential read working set"
    say "Order:   idle/load alternates; performance uses paired mirrored rotation; disk last"
    say "Network: внешних соединений во время benchmark-фазы нет"
    say "Safety:  single-run lock, signal cleanup, orphan recovery + legacy cleanup"
    say ""

    prepare_fio_file
    run_warmup
    if (( COOLDOWN_SEC > 0 )); then
        info "Cooldown after warm-up: ${COOLDOWN_SEC}s"
        sleep "$COOLDOWN_SEC" 200>&-
    fi
    start_host_diagnostics

    local f
    for f in idle_p999 idle_max idle_gt1 idle_gt5 idle_gt10 \
             load_p999 load_max load_gt1 load_gt5 load_gt10 \
             x255 aes1400 aes16k cha1400 cha16k cpu ram disk; do
        : >"$TMP_BASE/$f.dat"
    done
    : >"$TMP_BASE/iterations.tsv"
    : >"$TMP_BASE/cyclic-details.tsv"

    local perf_metrics=(x255 aes1400 aes16k cha1400 cha16k cpu ram)
    local i task first_mode second_mode offset j idx metric nmetrics
    nmetrics=${#perf_metrics[@]}
    local idle_p999 idle_max idle_gt1 idle_gt5 idle_gt10 idle_avg
    local load_p999 load_max load_gt1 load_gt5 load_gt10 load_avg
    local x255 aes1400 aes16k cha1400 cha16k cpu ram disk

    for ((i=1; i<=ITERATIONS; i++)); do
        task=1
        x255=""; aes1400=""; aes16k=""; cha1400=""; cha16k=""; cpu=""; ram=""; disk=""

        if (( i % 2 == 1 )); then
            first_mode="idle"; second_mode="load"
        else
            first_mode="load"; second_mode="idle"
        fi

        measure_latency_mode "$first_mode" "$i" "$task"
        if [[ "$first_mode" == "idle" ]]; then
            idle_p999="$LAST_LAT_P999"; idle_max="$LAST_LAT_MAX"; idle_gt1="$LAST_LAT_GT1"
            idle_gt5="$LAST_LAT_GT5"; idle_gt10="$LAST_LAT_GT10"; idle_avg="$LAST_LAT_AVG"
        else
            load_p999="$LAST_LAT_P999"; load_max="$LAST_LAT_MAX"; load_gt1="$LAST_LAT_GT1"
            load_gt5="$LAST_LAT_GT5"; load_gt10="$LAST_LAT_GT10"; load_avg="$LAST_LAT_AVG"
        fi

        # Each odd/even pair uses a rotated order and its exact mirror. Every
        # metric therefore has mean position 4.0 within a complete pair, avoiding
        # systematic hot/cold or boost bias while keeping runs reproducible.
        offset=$(( ((i - 1) / 2) % nmetrics ))
        for ((j=0; j<nmetrics; j++)); do
            if (( i % 2 == 1 )); then
                idx=$(( (j + offset) % nmetrics ))
            else
                idx=$(( (nmetrics - 1 - j + offset) % nmetrics ))
            fi
            metric="${perf_metrics[$idx]}"
            ((task++))
            run_perf_metric "$metric" "$i" "$task"
            case "$metric" in
                x255) x255="$LAST_VALUE"; printf '%s\n' "$x255" >>"$TMP_BASE/x255.dat" ;;
                aes1400) aes1400="$LAST_VALUE"; printf '%s\n' "$aes1400" >>"$TMP_BASE/aes1400.dat" ;;
                aes16k) aes16k="$LAST_VALUE"; printf '%s\n' "$aes16k" >>"$TMP_BASE/aes16k.dat" ;;
                cha1400) cha1400="$LAST_VALUE"; printf '%s\n' "$cha1400" >>"$TMP_BASE/cha1400.dat" ;;
                cha16k) cha16k="$LAST_VALUE"; printf '%s\n' "$cha16k" >>"$TMP_BASE/cha16k.dat" ;;
                cpu) cpu="$LAST_VALUE"; printf '%s\n' "$cpu" >>"$TMP_BASE/cpu.dat" ;;
                ram) ram="$LAST_VALUE"; printf '%s\n' "$ram" >>"$TMP_BASE/ram.dat" ;;
            esac
        done

        ((task++))
        measure_latency_mode "$second_mode" "$i" "$task"
        if [[ "$second_mode" == "idle" ]]; then
            idle_p999="$LAST_LAT_P999"; idle_max="$LAST_LAT_MAX"; idle_gt1="$LAST_LAT_GT1"
            idle_gt5="$LAST_LAT_GT5"; idle_gt10="$LAST_LAT_GT10"; idle_avg="$LAST_LAT_AVG"
        else
            load_p999="$LAST_LAT_P999"; load_max="$LAST_LAT_MAX"; load_gt1="$LAST_LAT_GT1"
            load_gt5="$LAST_LAT_GT5"; load_gt10="$LAST_LAT_GT10"; load_avg="$LAST_LAT_AVG"
        fi

        ((task++))
        run_disk "$i" "$task" "$TMP_BASE/fio-$i.json" "$TMP_BASE/fio-$i.log"
        disk="$LAST_VALUE"
        printf '%s\n' "$disk" >>"$TMP_BASE/disk.dat"

        printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$i" "$idle_p999" "$idle_avg" "$idle_max" "$idle_gt1" "$idle_gt5" "$idle_gt10" \
            "$load_p999" "$load_avg" "$load_max" "$load_gt1" "$load_gt5" "$load_gt10" >>"$TMP_BASE/cyclic-details.tsv"

        printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$i" "$idle_p999" "$load_p999" "$idle_max" "$load_max" \
            "$x255" "$aes1400" "$aes16k" "$cha1400" "$cha16k" "$cpu" "$ram" "$disk" \
            >>"$TMP_BASE/iterations.tsv"

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
    local x_med x_cv x_min x_max x_mean
    local aes1400_med aes1400_cv aes1400_min aes1400_max aes1400_mean
    local aes16k_med aes16k_cv aes16k_min aes16k_max aes16k_mean
    local cha1400_med cha1400_cv cha1400_min cha1400_max cha1400_mean
    local cha16k_med cha16k_cv cha16k_min cha16k_max cha16k_mean
    local cpu_med cpu_cv cpu_min cpu_max cpu_mean ram_med ram_cv ram_min ram_max ram_mean
    local disk_med disk_cv disk_min disk_max disk_mean
    read -r idle_med idle_cv idle_min idle_worst idle_mean < <(calc_stats "$TMP_BASE/idle_p999.dat")
    read -r load_med load_cv load_min load_worst load_mean < <(calc_stats "$TMP_BASE/load_p999.dat")
    read -r x_med x_cv x_min x_max x_mean < <(calc_stats "$TMP_BASE/x255.dat")
    read -r aes1400_med aes1400_cv aes1400_min aes1400_max aes1400_mean < <(calc_stats "$TMP_BASE/aes1400.dat")
    read -r aes16k_med aes16k_cv aes16k_min aes16k_max aes16k_mean < <(calc_stats "$TMP_BASE/aes16k.dat")
    read -r cha1400_med cha1400_cv cha1400_min cha1400_max cha1400_mean < <(calc_stats "$TMP_BASE/cha1400.dat")
    read -r cha16k_med cha16k_cv cha16k_min cha16k_max cha16k_mean < <(calc_stats "$TMP_BASE/cha16k.dat")
    read -r cpu_med cpu_cv cpu_min cpu_max cpu_mean < <(calc_stats "$TMP_BASE/cpu.dat")
    read -r ram_med ram_cv ram_min ram_max ram_mean < <(calc_stats "$TMP_BASE/ram.dat")
    read -r disk_med disk_cv disk_min disk_max disk_mean < <(calc_stats "$TMP_BASE/disk.dat")

    # Aggregate all cyclictest histograms. p99.99 is computed from the combined
    # distribution, not as a median of per-iteration percentiles.
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

    local latency_comparable latency_compat_reason
    latency_comparable=0
    latency_compat_reason=""
    if (( CYCLIC_NATURAL_PM == 1 && SINGLE_CORE_COMPARABLE == 1 )); then
        latency_comparable=1
    elif (( CYCLIC_NATURAL_PM == 0 )); then
        latency_compat_reason="natural power-management mode unavailable"
    else
        latency_compat_reason="single-vCPU affinity unavailable"
    fi

    # Loaded latency dominates. A single absolute maximum remains visible but
    # contributes only 5%, preventing one isolated sample from double-penalizing.
    local s_idle s_load s_idle9999 s_load9999 s_worst latency_f latency_score
    s_idle="$(vpn_lower_score "$idle_med" 500 1000 1500 2500 5000)"
    s_load="$(vpn_lower_score "$load_med" 1500 2500 4000 6000 12000)"
    s_idle9999="$(vpn_lower_score "$idle_p9999" 1500 3000 5000 10000 20000)"
    s_load9999="$(vpn_lower_score "$load_p9999" 3000 5000 8000 15000 30000)"
    s_worst="$(vpn_lower_score "$worst_all" 5000 10000 20000 50000 100000)"
    latency_f="$(awk -v a="$s_idle" -v b="$s_load" -v c="$s_idle9999" -v d="$s_load9999" -v e="$s_worst" \
        'BEGIN{printf "%.2f",a*.15+b*.40+c*.10+d*.30+e*.05}')"
    if (( latency_comparable == 1 )); then
        latency_score="$(awk -v v="$latency_f" 'BEGIN{printf "%d",v+0.5}')"
    else
        latency_score="null"
    fi

    # Keep idle/load spike denominators separate. Combining them previously made
    # load-only problems look roughly twice as rare when idle was clean.
    local idle_gt5_rate load_gt5_rate idle_gt10_rate load_gt10_rate
    idle_gt5_rate="$(awk -v c="$idle_gt5_count" -v n="$idle_samples" 'BEGIN{printf "%.3f",n?c*1000000/n:0}')"
    load_gt5_rate="$(awk -v c="$load_gt5_count" -v n="$load_samples" 'BEGIN{printf "%.3f",n?c*1000000/n:0}')"
    idle_gt10_rate="$(awk -v c="$idle_gt10_count" -v n="$idle_samples" 'BEGIN{printf "%.3f",n?c*1000000/n:0}')"
    load_gt10_rate="$(awk -v c="$load_gt10_count" -v n="$load_samples" 'BEGIN{printf "%.3f",n?c*1000000/n:0}')"

    local tail_idle_s tail_load_s idle_spike5_s load_spike5_s idle_spike10_s load_spike10_s
    local tail_worst_s tail_f tail_score
    tail_idle_s="$(vpn_lower_score "$idle_p9999" 1500 3000 5000 10000 20000)"
    tail_load_s="$(vpn_lower_score "$load_p9999" 3000 5000 8000 15000 30000)"
    idle_spike5_s="$(vpn_lower_score "$idle_gt5_rate" 2 10 50 200 500)"
    load_spike5_s="$(vpn_lower_score "$load_gt5_rate" 10 50 150 500 1000)"
    idle_spike10_s="$(vpn_lower_score "$idle_gt10_rate" 0.5 2 10 30 100)"
    load_spike10_s="$(vpn_lower_score "$load_gt10_rate" 2 10 30 100 200)"
    tail_worst_s="$(vpn_lower_score "$worst_all" 5000 10000 20000 50000 100000)"
    tail_f="$(awk -v i="$tail_idle_s" -v l="$tail_load_s" -v i5="$idle_spike5_s" -v l5="$load_spike5_s" \
        -v i10="$idle_spike10_s" -v l10="$load_spike10_s" -v w="$tail_worst_s" \
        'BEGIN{printf "%.2f",i*.15+l*.35+i5*.05+l5*.15+i10*.05+l10*.20+w*.05}')"
    if (( latency_comparable == 1 )); then
        tail_score="$(awk -v v="$tail_f" 'BEGIN{printf "%d",v+0.5}')"
    else
        tail_score="null"
    fi

    local idle_drift_us load_drift_us idle_drift_s load_drift_s
    local x_drop aes1400_drop aes16k_drop cha1400_drop cha16k_drop cpu_drop mem_drop
    local x_drop_s aes1400_drop_s aes16k_drop_s cha1400_drop_s cha16k_drop_s cpu_drop_s mem_drop_s
    local perf_base_s perf_worst_s perf_repeat_s worst_perf_drop worst_perf_name
    local consistency_f consistency_score stab_f stab
    idle_drift_us="$(drift_from_median "$idle_med" "$idle_min" "$idle_worst")"
    load_drift_us="$(drift_from_median "$load_med" "$load_min" "$load_worst")"
    idle_drift_s="$(vpn_lower_score "$idle_drift_us" 150 300 600 1200 2400)"
    load_drift_s="$(vpn_lower_score "$load_drift_us" 250 500 1000 2000 4000)"

    x_drop="$(drop_from_median "$x_med" "$x_min")"
    aes1400_drop="$(drop_from_median "$aes1400_med" "$aes1400_min")"
    aes16k_drop="$(drop_from_median "$aes16k_med" "$aes16k_min")"
    cha1400_drop="$(drop_from_median "$cha1400_med" "$cha1400_min")"
    cha16k_drop="$(drop_from_median "$cha16k_med" "$cha16k_min")"
    cpu_drop="$(drop_from_median "$cpu_med" "$cpu_min")"
    mem_drop="$(drop_from_median "$ram_med" "$ram_min")"
    x_drop_s="$(vpn_lower_score "$x_drop" 3 7 12 20 35)"
    aes1400_drop_s="$(vpn_lower_score "$aes1400_drop" 3 7 12 20 35)"
    aes16k_drop_s="$(vpn_lower_score "$aes16k_drop" 3 7 12 20 35)"
    cha1400_drop_s="$(vpn_lower_score "$cha1400_drop" 3 7 12 20 35)"
    cha16k_drop_s="$(vpn_lower_score "$cha16k_drop" 3 7 12 20 35)"
    cpu_drop_s="$(vpn_lower_score "$cpu_drop" 3 7 12 20 35)"
    mem_drop_s="$(vpn_lower_score "$mem_drop" 3 7 12 20 35)"
    perf_base_s="$(awk -v x="$x_drop_s" -v a1="$aes1400_drop_s" -v a16="$aes16k_drop_s" \
        -v c1="$cha1400_drop_s" -v c16="$cha16k_drop_s" -v p="$cpu_drop_s" -v m="$mem_drop_s" \
        'BEGIN{printf "%.2f",x*.15+a1*.10+a16*.10+c1*.10+c16*.10+p*.35+m*.10}')"
    read -r worst_perf_drop worst_perf_name < <(awk \
        -v x="$x_drop" -v a1="$aes1400_drop" -v a16="$aes16k_drop" \
        -v c1="$cha1400_drop" -v c16="$cha16k_drop" -v p="$cpu_drop" -v m="$mem_drop" 'BEGIN {
        v=x; n="X25519";
        if(a1>v){v=a1;n="AES-1.4K"} if(a16>v){v=a16;n="AES-16K"}
        if(c1>v){v=c1;n="ChaCha-1.4K"} if(c16>v){v=c16;n="ChaCha-16K"}
        if(p>v){v=p;n="CPU"} if(m>v){v=m;n="MEM"}
        printf "%.3f %s\n",v,n
    }')
    perf_worst_s="$(vpn_lower_score "$worst_perf_drop" 3 7 12 20 35)"
    perf_repeat_s="$(awk -v b="$perf_base_s" -v w="$perf_worst_s" 'BEGIN{printf "%.2f",b*.80+w*.20}')"

    consistency_f="$(awk -v i="$idle_drift_s" -v l="$load_drift_s" -v p="$perf_repeat_s" \
        'BEGIN{printf "%.2f",i*.35+l*.45+p*.20}')"
    if (( latency_comparable == 1 )); then
        consistency_score="$(awk -v v="$consistency_f" 'BEGIN{printf "%d",v+0.5}')"
        stab_f="$(awk -v t="$tail_f" -v c="$consistency_f" 'BEGIN{printf "%.2f",t*(.65+.35*c/100)}')"
        stab="$(awk -v v="$stab_f" 'BEGIN{printf "%d",v+0.5}')"
    else
        consistency_score="null"
        stab_f="null"
        stab="null"
    fi

    # Absolute 2026 mainstream-VPS anchors. 100 is a realistic near-term rental
    # ceiling, not a claim about the fastest possible physical CPU.
    local sx sa1400 sa16k sc1400 sc16k scpu smem
    local handshake_score packet_f packet_score stream_f stream_score crypto_f crypto_score
    local system_f system_score xtls_f xtls_score generic_f generic_score
    sx="$(vpn_higher_score "$x_med" 12000 18000 26000 36000 45000)"
    sa1400="$(vpn_higher_score "$aes1400_med" 600000000 1200000000 2200000000 3800000000 5500000000)"
    sa16k="$(vpn_higher_score "$aes16k_med" 1500000000 2500000000 4500000000 8500000000 12000000000)"
    sc1400="$(vpn_higher_score "$cha1400_med" 450000000 800000000 1300000000 1900000000 2600000000)"
    sc16k="$(vpn_higher_score "$cha16k_med" 900000000 1400000000 2000000000 3200000000 4500000000)"
    scpu="$(vpn_higher_score "$cpu_med" 300 500 900 1600 2500)"
    smem="$(vpn_higher_score "$ram_med" 4096 8192 16384 28672 45056)"

    handshake_score="$(awk -v v="$sx" 'BEGIN{printf "%d",v+0.5}')"
    packet_f="$(awk -v a="$sa1400" -v c="$sc1400" 'BEGIN{printf "%.2f",a*.50+c*.50}')"
    packet_score="$(awk -v v="$packet_f" 'BEGIN{printf "%d",v+0.5}')"
    stream_f="$(awk -v a="$sa16k" -v c="$sc16k" 'BEGIN{printf "%.2f",a*.50+c*.50}')"
    stream_score="$(awk -v v="$stream_f" 'BEGIN{printf "%d",v+0.5}')"
    crypto_f="$(awk -v h="$sx" -v p="$packet_f" -v s="$stream_f" 'BEGIN{printf "%.2f",h*.20+p*.50+s*.30}')"
    crypto_score="$(awk -v v="$crypto_f" 'BEGIN{printf "%d",v+0.5}')"
    system_f="$(awk -v p="$scpu" -v m="$smem" 'BEGIN{printf "%.2f",p*.80+m*.20}')"
    system_score="$(awk -v v="$system_f" 'BEGIN{printf "%d",v+0.5}')"

    if (( latency_comparable == 1 )); then
        xtls_f="$(awk -v l="$latency_f" -v p="$scpu" -v h="$sx" -v s="$stream_f" -v m="$smem" \
            'BEGIN{printf "%.2f",l*.50+p*.25+h*.10+s*.10+m*.05}')"
        generic_f="$(awk -v l="$latency_f" -v p="$scpu" -v h="$sx" -v pk="$packet_f" -v s="$stream_f" -v m="$smem" \
            'BEGIN{printf "%.2f",l*.40+p*.20+h*.10+pk*.20+s*.05+m*.05}')"
        xtls_score="$(awk -v v="$xtls_f" 'BEGIN{printf "%d",v+0.5}')"
        generic_score="$(awk -v v="$generic_f" 'BEGIN{printf "%d",v+0.5}')"
    else
        xtls_f="null"; xtls_score="null"
        generic_f="null"; generic_score="null"
    fi

    # Cheap diagnostics for quota/oversell symptoms during the same short run.
    local diag_end_epoch diag_duration_s cpu_total_end cpu_steal_end cpu_total_delta cpu_steal_delta steal_pct
    local cg_nr_throttled_end cg_throttled_usec_end cg_nr_throttled_delta cg_throttled_usec_delta
    local end_vals
    diag_end_epoch="$(date +%s)"
    diag_duration_s=$(( diag_end_epoch - DIAG_START_EPOCH ))
    end_vals="$(read_cpu_totals "$BENCH_CPU")"
    read -r cpu_total_end cpu_steal_end <<<"${end_vals:-0 0}"
    cpu_total_delta=$(( cpu_total_end - CPU_TOTAL_START ))
    cpu_steal_delta=$(( cpu_steal_end - CPU_STEAL_START ))
    steal_pct="$(awk -v s="$cpu_steal_delta" -v t="$cpu_total_delta" 'BEGIN{printf "%.3f", (t>0 ? s*100/t : 0)}')"
    cg_nr_throttled_delta=0
    cg_throttled_usec_delta=0
    if [[ -n "$CGROUP_CPU_STAT" && -r "$CGROUP_CPU_STAT" ]]; then
        cg_nr_throttled_end="$(read_cgroup_value nr_throttled "$CGROUP_CPU_STAT")"
        cg_throttled_usec_end="$(read_cgroup_value throttled_usec "$CGROUP_CPU_STAT")"
        cg_nr_throttled_delta=$(( cg_nr_throttled_end - CG_NR_THROTTLED_START ))
        cg_throttled_usec_delta=$(( cg_throttled_usec_end - CG_THROTTLED_USEC_START ))
        (( cg_nr_throttled_delta < 0 )) && cg_nr_throttled_delta=0
        (( cg_throttled_usec_delta < 0 )) && cg_throttled_usec_delta=0
    fi

    say "${BOLD}LATENCY${RESET}  ${DIM}(cyclictest p99.9; WORST = worst sample in iteration)${RESET}"
    printf '%-5s %10s %10s %10s %3s\n' "ITER" "IDLE" "LOAD" "WORST" ""
    printf '%s\n' "---------------------------------------------"
    while IFS=$'\t' read -r ri r_idle r_load r_imax r_lmax r_x r_a1 r_a16 r_c1 r_c16 r_cpu r_r r_d; do
        local r_worst flag
        r_worst="$(awk -v a="$r_imax" -v b="$r_lmax" 'BEGIN{print (a>b?a:b)}')"
        flag="$(latency_anomaly_flag "$r_idle" "$r_load" "$r_worst" "$idle_med" "$load_med" "$worst_med")"
        printf '%-5s %10s %10s %10s %3s\n' "$ri" "$(fmt_latency_us "$r_idle")" "$(fmt_latency_us "$r_load")" "$(fmt_latency_us "$r_worst")" "$flag"
    done <"$TMP_BASE/iterations.tsv"

    say ""
    say "${BOLD}PERFORMANCE${RESET}"
    printf '%-5s %9s %9s %9s %9s %9s %9s %9s %9s %4s\n' \
        "ITER" "X25519" "AES-1.4K" "AES-16K" "CHA-1.4K" "CHA-16K" "CPU" "MEM" "DISK" "FLAG"
    printf '%s\n' "--------------------------------------------------------------------------------------------------------"
    while IFS=$'\t' read -r ri r_idle r_load r_imax r_lmax r_x r_a1 r_a16 r_c1 r_c16 r_cpu r_r r_d; do
        local flag
        flag="$(performance_anomaly_flag "$r_x" "$r_a1" "$r_a16" "$r_c1" "$r_c16" "$r_cpu" "$r_r" "$r_d" \
            "$x_med" "$aes1400_med" "$aes16k_med" "$cha1400_med" "$cha16k_med" "$cpu_med" "$ram_med" "$disk_med")"
        printf '%-5s %9s %9s %9s %9s %9s %9s %9s %9s %4s\n' \
            "$ri" "$(fmt_x25519 "$r_x")" "$(fmt_crypto "$r_a1")" "$(fmt_crypto "$r_a16")" \
            "$(fmt_crypto "$r_c1")" "$(fmt_crypto "$r_c16")" "$(fmt_cpu "$r_cpu")" \
            "$(fmt_ram "$r_r")" "$(fmt_latency_ms "$r_d")" "$flag"
    done <"$TMP_BASE/iterations.tsv"

    say ""
    if (( latency_comparable == 1 )); then
        printf '%sLATENCY%s ' "$BOLD" "$RESET"; color_score "$latency_score"; printf '/100\n'
    else
        printf '%sLATENCY%s N/A  %s(%s)%s\n' "$BOLD" "$RESET" "$RED" "$latency_compat_reason" "$RESET"
    fi
    printf '  idle     %-9s tail %-9s drift %s\n' "$(fmt_latency_us "$idle_med")" "$(fmt_latency_us "$idle_p9999")" "$(fmt_latency_us "$idle_drift_us")"
    printf '  load     %-9s tail %-9s drift %s\n' "$(fmt_latency_us "$load_med")" "$(fmt_latency_us "$load_p9999")" "$(fmt_latency_us "$load_drift_us")"
    printf '  worst    %s\n' "$(fmt_latency_us "$worst_all")"
    printf '  spikes   >=5ms  idle %s (%s/M)  load %s (%s/M)\n' \
        "$idle_gt5_count" "$(awk -v v="$idle_gt5_rate" 'BEGIN{printf "%.1f",v}')" \
        "$load_gt5_count" "$(awk -v v="$load_gt5_rate" 'BEGIN{printf "%.1f",v}')"
    printf '           >=10ms idle %s (%s/M)  load %s (%s/M)\n' \
        "$idle_gt10_count" "$(awk -v v="$idle_gt10_rate" 'BEGIN{printf "%.1f",v}')" \
        "$load_gt10_count" "$(awk -v v="$load_gt10_rate" 'BEGIN{printf "%.1f",v}')"

    say ""
    printf '%sCRYPTO%s ' "$BOLD" "$RESET"; color_score "$crypto_score"; printf '/100  %s(diagnostic blend)%s\n' "$DIM" "$RESET"
    printf '  handshake proxy '; color_score "$handshake_score"; printf '/100  X25519 %-9s drop %s\n' "$(fmt_x25519 "$x_med")" "$(fmt_percent "$x_drop")"
    printf '  packet proxy    '; color_score "$packet_score"; printf '/100  AES-1.4K %-9s  ChaCha-1.4K %-9s\n' "$(fmt_crypto "$aes1400_med")" "$(fmt_crypto "$cha1400_med")"
    printf '             drops        %-9s              %s\n' "$(fmt_percent "$aes1400_drop")" "$(fmt_percent "$cha1400_drop")"
    printf '  stream proxy    '; color_score "$stream_score"; printf '/100  AES-16K  %-9s  ChaCha-16K  %-9s\n' "$(fmt_crypto "$aes16k_med")" "$(fmt_crypto "$cha16k_med")"
    printf '             drops        %-9s              %s\n' "$(fmt_percent "$aes16k_drop")" "$(fmt_percent "$cha16k_drop")"

    say ""
    printf '%sSYSTEM%s ' "$BOLD" "$RESET"; color_score "$system_score"; printf '/100  %s(80%% CPU / 20%% MEM)%s\n' "$DIM" "$RESET"
    printf '  CPU      '; color_score "$(awk -v v="$scpu" 'BEGIN{printf "%d",v+0.5}')"; printf '/100  %-9s drop %s\n' "$(fmt_cpu "$cpu_med")" "$(fmt_percent "$cpu_drop")"
    printf '  MEM      '; color_score "$(awk -v v="$smem" 'BEGIN{printf "%d",v+0.5}')"; printf '/100  %-9s drop %s  workset %sMiB\n' "$(fmt_ram "$ram_med")" "$(fmt_percent "$mem_drop")" "$MEM_BLOCK_MIB"
    printf '  Disk              %-9s %s(diagnostic; excluded from every score)%s\n' "$(fmt_latency_ms "$disk_med")" "$DIM" "$RESET"

    say ""
    if (( latency_comparable == 1 )); then
        printf '%sSTABILITY%s ' "$BOLD" "$RESET"; color_score "$stab"; printf '/100  %s(short benchmark window)%s\n' "$DIM" "$RESET"
        printf '  tail quality  '; color_score "$tail_score"; printf '/100\n'
        printf '  consistency   '; color_score "$consistency_score"; printf '/100\n'
        printf '  latency drift idle %s   load %s\n' "$(fmt_latency_us "$idle_drift_us")" "$(fmt_latency_us "$load_drift_us")"
        printf '  perf worst    %s %s\n' "$(fmt_percent "$worst_perf_drop")" "$worst_perf_name"
    else
        printf '%sSTABILITY%s N/A  %s(latency mode is not comparable)%s\n' "$BOLD" "$RESET" "$RED" "$RESET"
        printf '  perf worst    %s %s\n' "$(fmt_percent "$worst_perf_drop")" "$worst_perf_name"
    fi

    say ""
    say "${BOLD}HOST DIAGNOSTICS${RESET}  ${DIM}(not scored)${RESET}"
    printf '  CPU steal       %s%% over %ss\n' "$(awk -v v="$steal_pct" 'BEGIN{printf "%.2f",v}')" "$diag_duration_s"
    if [[ -n "$CGROUP_CPU_STAT" ]]; then
        printf '  cgroup throttle %s in %s events\n' "$(fmt_duration_us "$cg_throttled_usec_delta")" "$cg_nr_throttled_delta"
    else
        printf '  cgroup throttle N/A\n'
    fi

    say ""
    say "${BOLD}RESULT${RESET}"
    if (( latency_comparable == 1 )); then
        printf '  XTLS VISION  '; color_score "$xtls_score"; printf '/100  %s(host proxy; not Mbps)%s\n' "$DIM" "$RESET"
        printf '  GENERIC VPN  '; color_score "$generic_score"; printf '/100  %s(host proxy; not Mbps)%s\n' "$DIM" "$RESET"
        printf '  STABILITY    '; color_score "$stab"; printf '/100  (tail %s / consistency %s)\n' "$tail_score" "$consistency_score"
    else
        printf '  XTLS VISION  N/A\n'
        printf '  GENERIC VPN  N/A\n'
        printf '  STABILITY    N/A\n'
        printf '  CRYPTO       '; color_score "$crypto_score"; printf '/100\n'
        printf '  SYSTEM       '; color_score "$system_score"; printf '/100\n'
    fi

    RUN_COMPLETED=1
    print_debug_result

    say ""
    say "${DIM}drift = max absolute p99.9 deviation from the median; drop = worst throughput loss vs median.${RESET}"
    say "${DIM}STABILITY describes only this ~15-minute run; it cannot estimate events occurring once per hours/days.${RESET}"
    say "${DIM}XTLS VISION = 50% latency + 25% CPU + 10% X25519 proxy + 10% 16K crypto + 5% MEM.${RESET}"
    say "${DIM}GENERIC VPN = 40% latency + 20% CPU + 10% X25519 proxy + 20% 1.4K crypto + 5% 16K crypto + 5% MEM.${RESET}"
    say "${DIM}Scores estimate local host potential, not Xray Mbps or network route quality. Disk enters no score.${RESET}"
    say "${DIM}! = latency anomaly; P = scored performance anomaly; D = disk-only anomaly.${RESET}"
}

main "$@"
