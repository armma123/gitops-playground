#!/usr/bin/env bash

function confirm() {
  # shellcheck disable=SC2145
  # - the line break between args is intended here!
  printf "%s\n" "${@:-Are you sure? [y/N]} "
  
  read -r response
  case "$response" in
  [yY][eE][sS] | [yY])
    true
    ;;
  *)
    false
    ;;
  esac
}

function getExternalIP() {
  servicename=$1
  namespace=$2
  
  external_ip=""
  while [ -z $external_ip ]; do
    external_ip=$(kubectl -n ${namespace} get svc ${servicename} --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}")
    [ -z "$external_ip" ] && sleep 10
  done
  echo $external_ip
}

function spinner() {
    local info="$1"
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 $pid 2> /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  $info" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        local reset="\b\b\b\b\b"
        for ((i=1; i<=$(echo $info | wc -c); i++)); do
            reset+="\b"
        done
        printf $reset
    done
    echo " [ok] $info"
}

function error() {
     echo "$@" 1>&2; 
}
