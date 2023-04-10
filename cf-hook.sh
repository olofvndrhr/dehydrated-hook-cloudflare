#!/usr/bin/env bash
# shellcheck disable=

# cloudflare dns challenge bash script for dehydrated.io

# global vars
g_credentials_file="credentials"
g_curl_headers=()

# exit inside a $() does not work, so we will roll out our own
trap "exit 1" 10
PROC=$$
function abort() {
    kill -10 "${PROC}"
}

function out() {
    local l_msg="${*}"
    printf ' + Hook: %s\n' "${l_msg}"
}

function err() {
    local l_msg="${*}"
    printf ' + Hook: \033[0;31m%s\033[0m\n' "${l_msg}" 1>&2
}

function prepare() {
    local l_localdir

    l_localdir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

    # source the cloudflare token if the "credentials" file is present
    if [[ -f "${l_localdir}/${g_credentials_file}" ]]; then
        out "sourcing credentials"
        source "${l_localdir}/${g_credentials_file}"
    fi

    # set auth headers of api requests
    # if the cloudflare api token is set, use it, else use the email and api key
    if [[ -n "${CF_TOKEN}" ]]; then
        g_curl_headers=(
            -H "Authorization: Bearer ${CF_TOKEN}"
            -H "Content-Type: application/json"
        )
    # api token not found, check for api key
    elif [[ -n "${CF_EMAIL}" ]] && [[ -n "${CF_KEY}" ]]; then
        g_curl_headers=(
            -H "X-Auth-Email: ${CF_EMAIL}"
            -H "X-Auth-Key: ${CF_KEY}"
            -H "Content-Type: application/json"
        )
    # no api token/key found
    else
        err "missing api keys"
        abort
    fi
}

function cf_request() {
    local l_response l_success

    l_response="$(curl -sS "${g_curl_headers[@]}" "${@}")"

    # check exit status of request
    # shellcheck disable=SC2181
    if [[ ${?} -ne 0 ]]; then
        err "http request failed"
        abort
    fi

    # check request status in json response
    l_success="$(echo "${l_response}" | jq -r ".success")"
    if [[ "${l_success}" != "true" ]]; then
        err "cloudflare request cloud have failed. response: ${l_response}"
    fi

    # return json response
    printf '%s' "${l_response}"
}

function get_domain() {
    local l_suffix l_domain
    local l_fqdn="${1}"
    local l_suffix_url="https://publicsuffix.org/list/public_suffix_list.dat"

    # get domain name of supplied string. it removes any subdomains. works with every tld.
    # abc.def.com --> def.com
    # abc.def.co.uk --> def.co.uk

    out "getting tld of fqdn"
    curl -so- "${l_suffix_url}" \
        |
        # fetch from $l_suffix_url
        sed 's/[#\/].*$//' \
        |
        # strip comments
        sed 's/[*][.]//' \
        |
        # strip wildcard suffixes, like '*.nom.br'
        sed '/^[\t ]*$/d' \
        |
        # delete blank lines
        tr '[:upper:]' '[:lower:]' \
        |
        # everything lowercase
        awk '{print length, $0}' \
        |
        # prepend length of each line to each line
        sort -n -r \
        |
        # sort longest-line-first
        sed 's/^[0-9\t ]*//' \
        |
        # strip line length
        grep -E "${l_fqdn/*./}$" \
        |
        # optimization - only include matching TLDs
        while read -r l_suffix; do
            printf '%s' "${l_fqdn}" | grep -qE '[.]'"${l_suffix}"'$' || continue                             # if $l_domain does not end in .$l_suffix, get next suffix
            l_domain="$(printf '%s' "${l_fqdn}" | sed 's/[.]'"${l_suffix}"'$//' | awk -F '.' '{print $NF}')" # show only the domain without subdomains/tlds
            printf '%s' "${l_fqdn}" | grep -o ''"${l_domain}[.]${l_suffix}"'$'                               # remove subdomains
            break
        done
}

function get_zone_id() {
    local l_cf_reply l_domain l_id
    local l_fqdn="${1}"

    l_domain="$(get_domain "$l_fqdn")"

    out "requesting zone id for ${l_fqdn} (domain: ${l_domain})"

    # get cloudflare zone id of domain
    l_cf_reply="$(cf_request "https://api.cloudflare.com/client/v4/zones?name=${l_domain}")"

    l_id="$(echo "${l_cf_reply}" | jq -r ".result[0].id")"

    # check json response of api call
    if [[ "${l_id}" == "null" ]] || [[ -z "${l_id}" ]]; then
        err "unable to get zone id for ${l_fqdn}"
        abort
    fi

    out "zone id: ${l_id}"

    # return zone id of domain
    printf '%s' "${l_id}"
}

function wait_for_publication() {
    local l_fqdn="${1}"
    local l_type="${2}"
    local l_content="${3}"

    local l_retries=10
    local l_delay=2

    # check if dns record is already published
    while true; do
        if (
            dig +noall +answer @ns.cloudflare.com "${l_fqdn}" "${l_type}" \
                | awk '{ print $5 }' \
                | grep -qF "${l_content}"
        ); then
            # return exit code 0 if record is found
            return 0
        fi

        # if counter is on 0, abort
        if [[ ${l_retries} -eq 0 ]]; then
            err "record ${l_fqdn} did not get published in time"
            abort
        fi
        # wait for record publication
        out "waiting ${l_delay} seconds..."
        sleep ${l_delay}

        l_retries=$((l_retries - 1))
        l_delay=$((l_delay + 1))
    done
}

function create_record() {
    local l_cf_reply l_record_id
    local l_zone="${1}"
    local l_fqdn="${2}"
    local l_type="${3}"
    local l_content="${4}"

    out "creating record '${l_fqdn}' - '${l_type}' - '${l_content}'"

    # create dns record
    l_cf_reply="$(
        cf_request -X POST "https://api.cloudflare.com/client/v4/zones/${l_zone}/dns_records" \
            --data "{\"type\":\"${l_type}\",\"name\":\"${l_fqdn}\",\"content\":\"${l_content}\"}"
    )"
    l_record_id="$(echo "${l_cf_reply}" | jq -r ".result.id")"

    # record may already exist checking it
    if [[ "$(echo "${l_cf_reply}" | jq -r ".errors[0].message")" == "Record already exists." ]]; then
        out "record already exists. using this one"
        l_cf_reply="$(cf_request "https://api.cloudflare.com/client/v4/zones/${l_zone}/dns_records?name=${l_fqdn}&content=${l_content}")"
        l_record_id="$(echo "${l_cf_reply}" | jq -r ".result[0].id")"
    fi

    # check json api response from record creation
    if [[ "${l_record_id}" == "null" ]] || [[ -z "${l_record_id}" ]]; then
        err "error creating dns record"
        abort
    fi

    # return record id
    printf '%s' "${l_record_id}"
}

function get_acme_records() {
    local l_cf_reply l_record_id_list
    local l_zone="${1}"
    local l_fqdn="${2}"

    # return ids of _acme dns records
    l_cf_reply="$(cf_request "https://api.cloudflare.com/client/v4/zones/${l_zone}/dns_records?name=${l_fqdn}")"

    l_record_id_list="$(echo "${l_cf_reply}" | jq -r ".result[] | .id")"

    # check json api response from record creation
    if [[ "${l_record_id_list}" == "null" ]]; then
        err "error getting dns records"
        return 1
    fi

    # return record id list
    echo "${l_record_id_list}"
}

function delete_records() {
    local l_records_to_delete
    local l_zone="${1}"
    local l_fqdn="${2}"

    out "deleting record(s) for: ${l_fqdn}"

    # get records to delete
    # shellcheck disable=SC2207
    l_records_to_delete=($(get_acme_records "${l_zone}" "${l_fqdn}"))

    # delete all _acme txt records
    for record_id in "${l_records_to_delete[@]}"; do
        out "deleting record id: ${record_id}"
        cf_request -X DELETE "https://api.cloudflare.com/client/v4/zones/${l_zone}/dns_records/${record_id}" > /dev/null
    done
}

function deploy_challenge() {
    local l_record_id l_zone_id
    local l_fqdn="${1}"
    local l_token="${3}"

    l_zone_id="$(get_zone_id "${l_fqdn}")"

    # call function to create the new _acme records
    l_record_id="$(create_record "${l_zone_id}" "_acme-challenge.${l_fqdn}" TXT "${l_token}")"

    # call function to wait for availability of the new records
    wait_for_publication "_acme-challenge.${l_fqdn}" TXT "\"${l_token}\""

    out "challenge created - cf id: ${l_record_id}"
}

function clean_challenge() {
    local l_zone_id
    local l_fqdn="${1}"

    l_zone_id="$(get_zone_id "${l_fqdn}")"

    # call function to delete _acme records
    delete_records "${l_zone_id}" "_acme-challenge.${l_fqdn}"

}

# prepare
prepare
case "${1}" in
    "deploy_challenge")
        shift 1
        deploy_challenge "${@}"
        ;;
    "clean_challenge")
        shift 1
        clean_challenge "${@}"
        ;;
esac
