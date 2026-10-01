#!/usr/bin/env bash
set -euo pipefail

NAMESPACE_FILE="${1:-namespaces.txt}"
MARGIN_PERCENT="${MARGIN_PERCENT:-5}"
CLAIM_NAME="${CLAIM_NAME:-managed-quota}"
DRY_RUN="${DRY_RUN:-false}"
DRY_RUN_FILE="${DRY_RUN_FILE:-rightsizer-changes.tsv}"

WORK_DIR="$(mktemp -d)"
RESULTS_FILE="${WORK_DIR}/evaluated.tsv"
ERRORS_FILE="${WORK_DIR}/errors.log"
trap 'rm -rf "${WORK_DIR}"' EXIT
touch "${RESULTS_FILE}" "${ERRORS_FILE}"

append_line() {
    local target="$1"
    shift
    printf '%s\n' "$*" | tee -a "${target}" | sed -n '0p'
}

cpu_to_m() {
    local value="$1"
    case "${value}" in
        *m) printf '%s\n' "${value%m}" ;;
        *)
            printf '%s\n' "${value}" | grep -Eq '^[0-9]+([.][0-9]+)?$' || return 1
            awk -v v="${value}" 'BEGIN { printf "%.0f\n", v * 1000 }'
            ;;
    esac
}

memory_to_mi() {
    local value="$1"
    case "${value}" in
        0) printf '0\n' ;;
        *Ki) awk -v v="${value%Ki}" 'BEGIN { printf "%.0f\n", v / 1024 }' ;;
        *Mi) printf '%s\n' "${value%Mi}" ;;
        *Gi) awk -v v="${value%Gi}" 'BEGIN { printf "%.0f\n", v * 1024 }' ;;
        *Ti) awk -v v="${value%Ti}" 'BEGIN { printf "%.0f\n", v * 1024 * 1024 }' ;;
        *) return 1 ;;
    esac
}

add_margin_ceil() {
    awk -v v="$1" -v p="$2" 'BEGIN {
        x = v * (100 + p) / 100
        i = int(x)
        if (x > i) i++
        printf "%.0f\n", i
    }'
}

if ! test -f "${NAMESPACE_FILE}"; then
    printf 'ERROR: fichier introuvable: %s\n' "${NAMESPACE_FILE}"
    exit 1
fi

printf 'Règle: used + %s%%, appliqué seulement si inférieur au claim actuel.\n' "${MARGIN_PERCENT}"
printf '%s\n' '================ PHASE 1 : EVALUATION ================'

sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${NAMESPACE_FILE}" |
while IFS= read -r namespace; do
    printf '\n[%s]\n' "${namespace}"

    quota_file="${WORK_DIR}/${namespace}-resourcequota.json"
    claim_file="${WORK_DIR}/${namespace}-resourcequotaclaim.json"

    if ! kubectl get resourcequota -n "${namespace}" -o json |
        tee "${quota_file}" | sed -n '0p'
    then
        append_line "${ERRORS_FILE}" "${namespace}: get ResourceQuota impossible"
        continue
    fi

    if ! jq empty "${quota_file}"; then
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

    quota_name="$(jq -r '.items[0].metadata.name // empty' "${quota_file}")"
    used_cpu="$(jq -r '.items[0].status.used | .["requests.cpu"] // .cpu // empty' "${quota_file}")"
    used_memory="$(jq -r '.items[0].status.used | .["requests.memory"] // .memory // empty' "${quota_file}")"

    if test -z "${used_cpu}" || test -z "${used_memory}"; then
        used_keys="$(jq -r '(.items[0].status.used // {}) | keys | join(", ")' "${quota_file}")"
        append_line "${ERRORS_FILE}" "${namespace}: status.used CPU/memory incomplet (attendu: requests.cpu ou cpu, requests.memory ou memory; clés présentes: ${used_keys})"
        continue
    fi

    if ! kubectl get resourcequotaclaim "${CLAIM_NAME}" -n "${namespace}" -o json |
        tee "${claim_file}" | sed -n '0p'
    then
        append_line "${ERRORS_FILE}" "${namespace}: claim ${CLAIM_NAME} absent ou inaccessible"
        continue
    fi

    if ! jq empty "${claim_file}"; then
        append_line "${ERRORS_FILE}" "${namespace}: JSON ResourceQuotaClaim invalide"
        continue
    fi

    actual_claim_name="$(jq -r '.metadata.name // empty' "${claim_file}")"
    claim_cpu="$(jq -r '.spec.cpu // empty' "${claim_file}")"
    claim_memory="$(jq -r '.spec.memory // empty' "${claim_file}")"

    if test "${actual_claim_name}" != "${CLAIM_NAME}"; then
        append_line "${ERRORS_FILE}" "${namespace}: claim inattendu (${actual_claim_name})"
        continue
    fi

    if test -z "${claim_cpu}" || test -z "${claim_memory}"; then
        append_line "${ERRORS_FILE}" "${namespace}: claim CPU/memory incomplet"
        continue
    fi

    if ! used_cpu_m="$(cpu_to_m "${used_cpu}")"; then
        append_line "${ERRORS_FILE}" "${namespace}: CPU used non supporté (${used_cpu})"
        continue
    fi
    if ! claim_cpu_m="$(cpu_to_m "${claim_cpu}")"; then
        append_line "${ERRORS_FILE}" "${namespace}: CPU claim non supporté (${claim_cpu})"
        continue
    fi
    if ! used_memory_mi="$(memory_to_mi "${used_memory}")"; then
        append_line "${ERRORS_FILE}" "${namespace}: memory used non supportée (${used_memory})"
        continue
    fi
    if ! claim_memory_mi="$(memory_to_mi "${claim_memory}")"; then
        append_line "${ERRORS_FILE}" "${namespace}: memory claim non supportée (${claim_memory})"
        continue
    fi

    proposed_cpu_m="$(add_margin_ceil "${used_cpu_m}" "${MARGIN_PERCENT}")"
    proposed_memory_mi="$(add_margin_ceil "${used_memory_mi}" "${MARGIN_PERCENT}")"
    test "${proposed_cpu_m}" -lt 1 && proposed_cpu_m=1
    test "${proposed_memory_mi}" -lt 1 && proposed_memory_mi=1

    proposed_cpu="${proposed_cpu_m}m"
    proposed_memory="${proposed_memory_mi}Mi"

    target_cpu="${claim_cpu}"
    target_memory="${claim_memory}"
    reduce_cpu=false
    reduce_memory=false

    if test "${proposed_cpu_m}" -lt "${claim_cpu_m}"; then
        target_cpu="${proposed_cpu}"
        reduce_cpu=true
    fi

    if test "${proposed_memory_mi}" -lt "${claim_memory_mi}"; then
        target_memory="${proposed_memory}"
        reduce_memory=true
    fi

    action="SKIP"
    if test "${reduce_cpu}" = "true" || test "${reduce_memory}" = "true"; then
        action="APPLY"
    fi

    printf '  ResourceQuota: %s\n' "${quota_name}"
    printf '  CPU    used=%s | +%s%%=%s | claim=%s | cible=%s | reduce=%s\n' \
        "${used_cpu}" "${MARGIN_PERCENT}" "${proposed_cpu}" "${claim_cpu}" "${target_cpu}" "${reduce_cpu}"
    printf '  Memory used=%s | +%s%%=%s | claim=%s | cible=%s | reduce=%s\n' \
        "${used_memory}" "${MARGIN_PERCENT}" "${proposed_memory}" "${claim_memory}" "${target_memory}" "${reduce_memory}"
    printf '  Action: %s\n' "${action}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${namespace}" "${actual_claim_name}" "${used_cpu}" "${claim_cpu}" "${target_cpu}" \
        "${used_memory}" "${claim_memory}" "${target_memory}" \
        "${reduce_cpu}" "${reduce_memory}" "${action}" |
        tee -a "${RESULTS_FILE}" | sed -n '0p'
done

if test -s "${ERRORS_FILE}"; then
    printf '\n%s\n' '================ ECHEC EVALUATION ====================='
    printf '%s\n' 'Aucun claim ne sera modifié.'
    cat "${ERRORS_FILE}"
    exit 1
fi

printf '\n%s\n' '================ RECAPITULATIF ========================'
if test "${DRY_RUN}" = "true"; then
    awk -F '\t' 'BEGIN {
        OFS = "\t"
        print "NAMESPACE", "CLAIM", "USED_CPU", "CURRENT_CPU", "TARGET_CPU", "USED_MEMORY", "CURRENT_MEMORY", "TARGET_MEMORY", "REDUCE_CPU", "REDUCE_MEMORY"
    }
    $11 == "APPLY" {
        print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
    }' "${RESULTS_FILE}" | tee "${DRY_RUN_FILE}" | sed -n '0p'
    printf 'Rapport des changements applicables : %s\n' "${DRY_RUN_FILE}"
fi

if ! test -s "${RESULTS_FILE}"; then
    printf '%s\n' 'Aucun ResourceQuota éligible.'
    exit 0
fi

printf '%-28s %-12s %-12s %-12s %-14s %-14s %-14s %-8s\n' \
    NAMESPACE USED_CPU CLAIM_CPU TARGET_CPU USED_MEM CLAIM_MEM TARGET_MEM ACTION
awk -F '\t' '{printf "%-28s %-12s %-12s %-12s %-14s %-14s %-14s %-8s\n",$1,$3,$4,$5,$6,$7,$8,$11}' "${RESULTS_FILE}"

if test "${DRY_RUN}" = "true"; then
    printf '\nDRY_RUN=true : aucune modification.\n'
    exit 0
fi

printf '\n%s\n' '================ PHASE 2 : APPLICATION ================'
cat "${RESULTS_FILE}" |
while IFS="$(printf '\t')" read -r namespace claim_name used_cpu claim_cpu target_cpu used_memory claim_memory target_memory reduce_cpu reduce_memory action; do
    if test "${action}" != "APPLY"; then
        printf '[%s] SKIP\n' "${namespace}"
        continue
    fi

    printf '[%s] APPLY %s cpu=%s memory=%s\n' "${namespace}" "${claim_name}" "${target_cpu}" "${target_memory}"

    jq -n \
        --arg name "${claim_name}" \
        --arg namespace "${namespace}" \
        --arg cpu "${target_cpu}" \
        --arg memory "${target_memory}" \
        '{
          apiVersion:"cagip.github.com/v1",
          kind:"ResourceQuotaClaim",
          metadata:{name:$name,namespace:$namespace},
          spec:{cpu:$cpu,memory:$memory}
        }' |
        kubectl apply -f -
done

printf '\nTerminé.\n'
