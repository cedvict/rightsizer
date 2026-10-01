#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
trap 'printf "ERROR: arrêt inattendu à la ligne %s (code %s).\n" "$LINENO" "$?" >&2' ERR

NAMESPACE_FILE="${1:-namespaces.txt}"
MARGIN_PERCENT="${MARGIN_PERCENT:-5}"
CLAIM_NAME="${CLAIM_NAME:-managed-quota}"
DRY_RUN="${DRY_RUN:-false}"
DRY_RUN_FILE="${DRY_RUN_FILE:-rightsizer-changes.tsv}"
MANIFEST_FILE="${MANIFEST_FILE:-rightsizer-claims.json}"
ERROR_REPORT_FILE="${ERROR_REPORT_FILE:-rightsizer-errors.log}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30s}"

WORK_DIR="$(mktemp -d)"
RESULTS_FILE="${WORK_DIR}/evaluated.tsv"
ERRORS_FILE="${WORK_DIR}/errors.log"
trap 'rm -rf "${WORK_DIR}"' EXIT
touch "${RESULTS_FILE}" "${ERRORS_FILE}"

append_line() {
    local target="$1"
    shift
    printf '%s\n' "$*" | tee -a "${target}" | sed -n ''
}

cpu_to_m() {
    local value="$1" factor=1000
    if [[ "${value}" == *m ]]; then
        value="${value%m}"
        factor=1
    fi
    [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v v="${value}" -v f="${factor}" 'BEGIN { printf "%.12g\n", v * f }'
}

memory_to_bytes() {
    local value="$1" factor=1
    case "${value}" in
        *Ki) value="${value%Ki}"; factor=1024 ;;
        *Mi) value="${value%Mi}"; factor=1048576 ;;
        *Gi) value="${value%Gi}"; factor=1073741824 ;;
        *Ti) value="${value%Ti}"; factor=1099511627776 ;;
    esac
    [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v v="${value}" -v f="${factor}" 'BEGIN { printf "%.15g\n", v * f }'
}

is_less() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

add_margin_ceil() {
    awk -v v="$1" -v p="$2" -v unit="${3:-1}" 'BEGIN {
        x = v * (100 + p) / 100 / unit
        i = int(x)
        if (x > i) i++
        printf "%.0f\n", i
    }'
}

if ! test -f "${NAMESPACE_FILE}"; then
    printf 'ERROR: fichier introuvable: %s\n' "${NAMESPACE_FILE}"
    exit 1
fi

for dependency in kubectl jq awk sed tee; do
    if ! command -v "${dependency}" >/dev/null; then
        printf 'ERROR: dépendance manquante : %s\n' "${dependency}" >&2
        exit 1
    fi
done
if [[ ! "${MARGIN_PERCENT}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'ERROR: MARGIN_PERCENT doit être un nombre positif ou nul.\n' >&2
    exit 1
fi
if [[ "${DRY_RUN}" != true && "${DRY_RUN}" != false ]]; then
    printf 'ERROR: DRY_RUN doit être true ou false.\n' >&2
    exit 1
fi
# Resolve paths before contacting the cluster; reject collisions with inputs.
resolve_output() {
    local path="$1"
    test -d "$(dirname "${path}")" || mkdir -p "$(dirname "${path}")"
    printf '%s/%s\n' "$(cd "$(dirname "${path}")" && pwd -P)" "$(basename "${path}")"
}
DRY_RUN_FILE="$(resolve_output "${DRY_RUN_FILE}")"
MANIFEST_FILE="$(resolve_output "${MANIFEST_FILE}")"
ERROR_REPORT_FILE="$(resolve_output "${ERROR_REPORT_FILE}")"
for output in "${DRY_RUN_FILE}" "${MANIFEST_FILE}" "${ERROR_REPORT_FILE}"; do
    if test -L "${output}" || test -d "${output}" || test "${output}" -ef "${NAMESPACE_FILE}" || test "${output}" -ef "$0"; then
        printf 'ERROR: chemin de sortie dangereux : %s\n' "${output}" >&2
        exit 1
    fi
done
if [[ "${DRY_RUN_FILE}" == "${MANIFEST_FILE}" || "${DRY_RUN_FILE}" == "${ERROR_REPORT_FILE}" || "${MANIFEST_FILE}" == "${ERROR_REPORT_FILE}" ]] ||
    test "${DRY_RUN_FILE}" -ef "${MANIFEST_FILE}" || test "${DRY_RUN_FILE}" -ef "${ERROR_REPORT_FILE}" || test "${MANIFEST_FILE}" -ef "${ERROR_REPORT_FILE}"; then
    printf 'ERROR: les trois fichiers de sortie doivent être distincts.\n' >&2
    exit 1
fi
printf 'Mode DRY_RUN=%s ; rapport : %s\n' "${DRY_RUN}" "${DRY_RUN_FILE}"

printf 'Règle: used + %s%%, appliqué seulement si inférieur au plafond ResourceQuota actuel.\n' "${MARGIN_PERCENT}"
printf '%s\n' '================ PHASE 1 : EVALUATION ================'

sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${NAMESPACE_FILE}" | awk '!seen[$0]++' |
while IFS= read -r namespace || test -n "${namespace}"; do
    printf '\n[%s]\n' "${namespace}"

    if [[ ! "${namespace}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || test "${#namespace}" -gt 63; then
        append_line "${ERRORS_FILE}" "${namespace}: nom de namespace invalide"
        continue
    fi
    quota_file="${WORK_DIR}/${namespace}-resourcequota.json"
    kubectl_error="${WORK_DIR}/${namespace}-kubectl.log"

    if ! kubectl get resourcequota -n "${namespace}" -o json --request-timeout="${REQUEST_TIMEOUT}" </dev/null 2>"${kubectl_error}" |
        tee "${quota_file}" | sed -n ''
    then
        append_line "${ERRORS_FILE}" "${namespace}: get ResourceQuota impossible : $(cat "${kubectl_error}")"
        continue
    fi

    if ! jq -e 'type == "object" and (.items | type == "array")' "${quota_file}" | sed -n ''; then
        append_line "${ERRORS_FILE}" "${namespace}: JSON ResourceQuota invalide"
        continue
    fi

    quota_count="$(jq -r '.items | length' "${quota_file}")"

    if test "${quota_count}" -eq 0; then
        printf '  SKIP: aucun ResourceQuota\n'
        continue
    fi

    if test "${quota_count}" -ne 1; then
        append_line "${ERRORS_FILE}" "${namespace}: ${quota_count} ResourceQuota trouvés"
        continue
    fi

    if ! jq -e '.items[0] | type == "object" and
        (.spec.hard | type == "object") and
        (.status.used | type == "object")' "${quota_file}" | sed -n ''; then
        append_line "${ERRORS_FILE}" "${namespace}: structure spec.hard/status.used invalide ou absente"
        continue
    fi

    quota_name="$(jq -r '.items[0].metadata.name // empty' "${quota_file}")"
    cpu_key="$(jq -r '(.items[0].spec.hard // {}) | if has("requests.cpu") then "requests.cpu" else "cpu" end' "${quota_file}")"
    memory_key="$(jq -r '(.items[0].spec.hard // {}) | if has("requests.memory") then "requests.memory" else "memory" end' "${quota_file}")"
    used_cpu="$(jq -r --arg key "${cpu_key}" '.items[0].status.used[$key] // empty' "${quota_file}")"
    used_memory="$(jq -r --arg key "${memory_key}" '.items[0].status.used[$key] // empty' "${quota_file}")"
    current_cpu="$(jq -r --arg key "${cpu_key}" '.items[0].spec.hard[$key] // empty' "${quota_file}")"
    current_memory="$(jq -r --arg key "${memory_key}" '.items[0].spec.hard[$key] // empty' "${quota_file}")"
    if test -z "${current_cpu}" || test -z "${current_memory}" || test -z "${used_cpu}" || test -z "${used_memory}"; then
        append_line "${ERRORS_FILE}" "${namespace}: spec.hard ou status.used incomplet pour ${cpu_key}/${memory_key}"
        continue
    fi

    if ! used_cpu_m="$(cpu_to_m "${used_cpu}")"; then
        append_line "${ERRORS_FILE}" "${namespace}: CPU used non supporté (${used_cpu})"
        continue
    fi
    if ! current_cpu_m="$(cpu_to_m "${current_cpu}")"; then
        append_line "${ERRORS_FILE}" "${namespace}: CPU spec.hard non supporté (${current_cpu})"
        continue
    fi
    if ! used_memory_bytes="$(memory_to_bytes "${used_memory}")"; then
        append_line "${ERRORS_FILE}" "${namespace}: memory used non supportée (${used_memory})"
        continue
    fi
    if ! current_memory_bytes="$(memory_to_bytes "${current_memory}")"; then
        append_line "${ERRORS_FILE}" "${namespace}: memory spec.hard non supportée (${current_memory})"
        continue
    fi

    proposed_cpu_m="$(add_margin_ceil "${used_cpu_m}" "${MARGIN_PERCENT}")"
    proposed_memory_mi="$(add_margin_ceil "${used_memory_bytes}" "${MARGIN_PERCENT}" 1048576)"
    test "${proposed_cpu_m}" -lt 1 && proposed_cpu_m=1
    test "${proposed_memory_mi}" -lt 1 && proposed_memory_mi=1

    proposed_cpu="${proposed_cpu_m}m"
    proposed_memory="${proposed_memory_mi}Mi"

    target_cpu="${current_cpu}"
    target_memory="${current_memory}"
    reduce_cpu=false
    reduce_memory=false

    if is_less "${proposed_cpu_m}" "${current_cpu_m}"; then
        target_cpu="${proposed_cpu}"
        reduce_cpu=true
    fi

    proposed_memory_bytes="$(awk -v v="${proposed_memory_mi}" 'BEGIN { printf "%.15g\n", v * 1048576 }')"
    if is_less "${proposed_memory_bytes}" "${current_memory_bytes}"; then
        target_memory="${proposed_memory}"
        reduce_memory=true
    fi

    action="SKIP"
    if test "${reduce_cpu}" = "true" || test "${reduce_memory}" = "true"; then
        action="APPLY"
    fi

    printf '  ResourceQuota: %s\n' "${quota_name}"
    printf '  CPU    used=%s | +%s%%=%s | hard=%s | cible=%s | reduce=%s\n' \
        "${used_cpu}" "${MARGIN_PERCENT}" "${proposed_cpu}" "${current_cpu}" "${target_cpu}" "${reduce_cpu}"
    printf '  Memory used=%s | +%s%%=%s | hard=%s | cible=%s | reduce=%s\n' \
        "${used_memory}" "${MARGIN_PERCENT}" "${proposed_memory}" "${current_memory}" "${target_memory}" "${reduce_memory}"
    printf '  Action: %s\n' "${action}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${namespace}" "${CLAIM_NAME}" "${used_cpu}" "${current_cpu}" "${target_cpu}" \
        "${used_memory}" "${current_memory}" "${target_memory}" \
        "${reduce_cpu}" "${reduce_memory}" "${action}" |
        tee -a "${RESULTS_FILE}" | sed -n ''
done

# Generate the complete plan before any application.
jq -Rn '
    [inputs | split("\t") | select(.[10] == "APPLY") |
      {apiVersion:"cagip.github.com/v1", kind:"ResourceQuotaClaim",
       metadata:{name:.[1], namespace:.[0]},
       spec:{cpu:.[4], memory:.[7]}}] |
    {apiVersion:"v1", kind:"List", items:.}
' "${RESULTS_FILE}" | tee "${WORK_DIR}/claims.json" | sed -n ''

printf '\n%s\n' '================ RECAPITULATIF ========================'
awk -F '\t' 'BEGIN {
    OFS = "\t"
    print "NAMESPACE", "CLAIM", "USED_CPU", "CURRENT_CPU", "TARGET_CPU", "USED_MEMORY", "CURRENT_MEMORY", "TARGET_MEMORY", "REDUCE_CPU", "REDUCE_MEMORY"
}
$11 == "APPLY" {
    print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
}' "${RESULTS_FILE}" | tee "${DRY_RUN_FILE}" | sed -n ''
cat "${WORK_DIR}/claims.json" | tee "${MANIFEST_FILE}" | sed -n ''
cat "${ERRORS_FILE}" | tee "${ERROR_REPORT_FILE}" | sed -n ''
printf 'Manifests générés : %s\n' "${MANIFEST_FILE}"
printf 'Rapport des changements applicables : %s\n' "${DRY_RUN_FILE}"
printf 'Rapport des erreurs : %s\n' "${ERROR_REPORT_FILE}"

if test -s "${ERRORS_FILE}"; then
    printf '\nATTENTION : évaluation partielle. Les manifests couvrent uniquement les namespaces évalués.\n'
    cat "${ERRORS_FILE}"
    printf 'Aucun claim appliqué. Code retour 2 : évaluation incomplète.\n'
    exit 2
fi

if ! test -s "${RESULTS_FILE}"; then
    printf '%s\n' 'Aucun ResourceQuota éligible.'
    exit 0
fi

printf '%-28s %-12s %-12s %-12s %-14s %-14s %-14s %-8s\n' \
    NAMESPACE USED_CPU HARD_CPU TARGET_CPU USED_MEM HARD_MEM TARGET_MEM ACTION
awk -F '\t' '{printf "%-28s %-12s %-12s %-12s %-14s %-14s %-14s %-8s\n",$1,$3,$4,$5,$6,$7,$8,$11}' "${RESULTS_FILE}"

if test "${DRY_RUN}" = "true"; then
    printf '\nDRY_RUN=true : aucune modification.\n'
    exit 0
fi

printf '\n%s\n' '================ PHASE 2 : APPLICATION ================'
if test "$(jq '.items | length' "${WORK_DIR}/claims.json")" -eq 0; then
    printf 'Aucun changement applicable.\n'
else
    kubectl apply -f "${WORK_DIR}/claims.json"
fi

printf '\nTerminé.\n'
