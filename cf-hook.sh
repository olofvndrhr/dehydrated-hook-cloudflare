#!/bin/bash
# shellcheck disable=SC2155
# shellcheck disable=SC2162
# shellcheck disable=SC2181
# shellcheck disable=SC2173


log () {
  printf '   %s\n' "${*}" 1>&2
}

success () {
  printf ' + %s\n' "${*}" 1>&2
}

error () {
  printf 'ERROR: %s\n' "${*}" 1>&2
}

# exit inside a $() does not work, so we will roll out our own
scriptexitval=1
trap "exit \$scriptexitval" SIGKILL
function abort () {
  scriptexitval=$1
  kill 0
}

function cf_req () {
  local response
  
  # source the cloudflare token if the "cftoken" file is present
  localdir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
  if [[ -f "${localdir}/cftoken" ]]; then
    source "${localdir}/cftoken"
  fi

  # set auth headers of api requests
  # if the cloudflare api token is set, use it, else use the email and api key
  if [[ -n "${CF_TOKEN}" ]]; then
    response=$( curl -s \
                -H "Authorization: Bearer ${CF_TOKEN}" \
                -H "Content-Type: application/json" \
                    "${@}"
              )
  # api token not found, check for api key
  elif [[ -n "${CF_EMAIL}" ]] && [[ -n "${CF_KEY}" ]]; then
    response=$( curl -s \
                -H "X-Auth-Email: ${CF_EMAIL}" \
                -H "X-Auth-Key: ${CF_KEY}" \
                -H "Content-Type: application/json" \
                    "${@}"
              )
  # no api token/key found
  else
    error 'Missing CF keys'
    abort 1
  fi

  # check exit status of request
  if [[ $? -ne 0 ]]; then
    error 'HTTP request failed'
    abort 1
  fi

  # check request status in json response
  local success=$( printf '%s' "${response}" | jq -r ".success" )
  if [[ "${success}" != true ]]; then
    error 'CloudFlare request failed'
    error "Response: ${response}"
    abort 1
  fi

  # return json response
  printf '%s' "${response}"
}

function get_domain () {
  local fqdn="${1}"
  local suffix_url='https://publicsuffix.org/list/public_suffix_list.dat'

  # get domain name of supplied string. it removes any subdomains. works with every tld.
  # abc.def.com --> def.com
  # abc.def.co.uk --> def.co.uk

  curl -so- "${suffix_url}"   |     # fetch from $suffix_url
  sed 's/[#\/].*$//'          |     # strip comments
  sed 's/[*][.]//'            |     # strip wildcard suffixes, like '*.nom.br'
  sed '/^[\t ]*$/d'           |     # delete blank lines
  tr '[:upper:]' '[:lower:]'  |     # everything lowercase
  awk '{print length, $0}'    |     # prepend length of each line to each line
  sort -n -r                  |     # sort longest-line-first
  sed 's/^[0-9\t ]*//'        |     # strip line length
  grep -E "${fqdn/*./}$"      |     # optimisation - only include matching TLDs
  while read suffix; do
    printf '%s' "${fqdn}" | grep -qE '[.]'"${suffix}"'$' || continue    # if $domain does not end in .$suffix, get next suffix
    domain=$( printf '%s' "${fqdn}" | sed 's/[.]'"${suffix}"'$//' | awk -F '.' '{print $NF}' )   # show only the domain without subdomains/tlds
    printf '%s' "${fqdn}" | grep -o ''"${domain}[.]${suffix}"'$'    # remove subdomains
    break
  done
}

function get_zone_id () {
  local fqdn="${1}"
  local domain=$( get_domain "$fqdn" )

  log "Requesting zone ID for ${fqdn} (domain: ${domain})"

  # get cloudflare zone id of domain
  local id=$( cf_req "https://api.cloudflare.com/client/v4/zones?name=${domain}" \
              | jq -r ".result[0].id"
            )

  # check json response of api call
  if [[ "${id}" == null ]]; then
    error "Unable to get zone ID for ${fqdn}"
    abort 1
  fi

  success "Zone ID: ${id}"

  # return zone id of domain
  printf '%s' "${id}"
}

function wait_for_publication () {
  local fqdn="${1}"
  local type="${2}"
  local content="${3}"

  local retries=12
  local delay=1000
  local delaySec

  # check if dns record is already published
  while true; do
    if ( dig +noall +answer @ns.cloudflare.com "${fqdn}" "${type}" \
        | awk '{ print $5 }' \
        | grep -qF "${content}" ); then
      # return exit code 0 if record is found
      return 0
    fi

    # if counter is on 0, abort
    if [[ ${retries} -eq 0 ]]; then
      error "Record ${fqdn} did not get published in time"
      abort 1
    # wait for record publication
    else
      delaySec=${delay:0:(-3)}.${delay:(-3)}
      log "Waiting ${delaySec} seconds..."
      sleep ${delaySec}

      retries=$(( retries - 1 ))
      delay=$(( delay * 15 / 10 ))
    fi
  done
}

function create_record () {
  local zone="${1}"
  local fqdn="${2}"
  local type="${3}"
  local content="${4}"
  local recordid

  log "Creating record ${fqdn} ${type} ${content}"

  # create dns record
  recordid=$( cf_req -X POST "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records" \
              --data "{\"type\":\"${type}\",\"name\":\"${fqdn}\",\"content\":\"${content}\"}" \
              | jq -r ".result.id"
            )

  # check json api response from record creation
  if [[ "${recordid}" == null ]]; then
    error 'Error creating DNS record'
    abort 1
  fi

  # return record id
  printf '%s' "${recordid}"
}

function list_record_id () {
  local zone="${1}"
  local fqdn="${2}"

  # return ids of _acme created dns records
  cf_req "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records?name=${fqdn}" \
  |	jq -r ".result[] | .id"
}

function delete_records () {
  local zone="${1}"
  local fqdn="${2}"

  log "Deleting record(s) for ${fqdn}"

  # delete all created _acme txt records
  list_record_id "${zone}" "${fqdn}" \
  |	while read recordid; do
      log " - Deleting ${recordid}"
      cf_req -X DELETE "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${recordid}" >/dev/null
  done
}

function deploy_challenge () {
  local fqdn="${2}"
  local token="${4}"
  local zoneid=$( get_zone_id "${fqdn}" )

  # call function to create the new _acme records
  recordid=$( create_record "${zoneid}" "_acme-challenge.${fqdn}" TXT "${token}" )

  # call function to wait for availability of the new records
  wait_for_publication "_acme-challenge.${fqdn}" TXT "\"${token}\""

  success "challenge created - CF ID: ${recordid}"
}

function clean_challenge () {
  local fqdn="${2}"
  local zoneid=$( get_zone_id "${fqdn}" )

  # call function to delete _acme records
  delete_records "${zoneid}" "_acme-challenge.${fqdn}"
}

case ${1} in
  deploy_challenge)
    deploy_challenge "${@}"
  ;;
  clean_challenge)
    clean_challenge "${@}"
  ;;
esac

