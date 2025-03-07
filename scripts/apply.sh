#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

BASEDIR=$(dirname $0)
export BASEDIR
ABSOLUTE_BASEDIR="$(cd ${BASEDIR} && pwd)"
export ABSOLUTE_BASEDIR
PLAYGROUND_DIR="$(cd ${BASEDIR} && cd .. && pwd)"
export PLAYGROUND_DIR

# When updating, update in ApplicationConfigurator.groovy as well 
PETCLINIC_COMMIT=32c8653
SPRING_BOOT_HELM_CHART_COMMIT=0.3.1
K8S_VERSION=1.25.4

source ${ABSOLUTE_BASEDIR}/utils.sh
source ${ABSOLUTE_BASEDIR}/jenkins/init-jenkins.sh
source ${ABSOLUTE_BASEDIR}/scm-manager/init-scmm.sh

INTERNAL_SCMM=true
INTERNAL_JENKINS=true
INTERNAL_REGISTRY=true
# When running in k3d, connection between SCMM <-> Jenkins must be via k8s services, because external "localhost"
# addresses will not work
JENKINS_URL_FOR_SCMM="http://jenkins"
SCMM_URL_FOR_JENKINS="http://scmm-scm-manager/scm"

# When updating please also adapt in Dockerfile, vars.tf, ApplicationConfigurator.groovy and init-cluster.sh
# Find and replace with this regex, e.g. ghcr.io/cloudogu/helm:([\d\.-]*)*
KUBECTL_DEFAULT_IMAGE="lachlanevenson/k8s-kubectl:v${K8S_VERSION}"
HELM_DEFAULT_IMAGE='ghcr.io/cloudogu/helm:3.10.3-1'
YAMLLINT_DEFAULT_IMAGE='cytopia/yamllint:1.25-0.7'
# cloudogu/helm also contains kubeval and helm kubeval plugin. Using the same image makes builds faster
KUBEVAL_DEFAULT_IMAGE=${HELM_DEFAULT_IMAGE}
HELMKUBEVAL_DEFAULT_IMAGE=${HELM_DEFAULT_IMAGE}

SPRING_BOOT_HELM_CHART_REPO=${SPRING_BOOT_HELM_CHART_REPO:-'https://github.com/cloudogu/spring-boot-helm-chart.git'}
SPRING_PETCLINIC_REPO=${SPRING_PETCLINIC_REPO:-'https://github.com/cloudogu/spring-petclinic.git'}
GITOPS_BUILD_LIB_REPO=${GITOPS_BUILD_LIB_REPO:-'https://github.com/cloudogu/gitops-build-lib.git'}
CES_BUILD_LIB_REPO=${CES_BUILD_LIB_REPO:-'https://github.com/cloudogu/ces-build-lib.git'}

JENKINS_PLUGIN_FOLDER=${JENKINS_PLUGIN_FOLDER:-''}

function main() {
  
  readParameters "$@"

  if [[ $ASSUME_YES == false ]]; then
    confirm "Applying gitops playground to kubernetes cluster: '$(kubectl config current-context)'." 'Continue? y/n [n]' ||
      # Return error here to avoid get correct state when used with kubectl
      exit 1
  fi

  if [[ $TRACE == true ]]; then
    set -x
    # Trace without debug does not make to much sense, as the spinner spams the output
    DEBUG=true
  fi

  # The - avoids "unbound variable", because it expands to empty string if unset
  if [[ -n "${KUBERNETES_SERVICE_HOST-}" ]]; then
    RUNNING_INSIDE_K8S=true
  else
    RUNNING_INSIDE_K8S=false
  fi

  CLUSTER_BIND_ADDRESS=$(findClusterBindAddress)

  if [[ $INSECURE == true ]]; then
    CURL_HOME="${PLAYGROUND_DIR}"
    export CURL_HOME
    export GIT_SSL_NO_VERIFY=1
  fi

  if [[ -n "${SCMM_URL}" ]]; then
    INTERNAL_SCMM=false
    # We can't use internal kubernetes services in this scenario
    SCMM_URL_FOR_JENKINS=${SCMM_URL}
  elif [[ $RUNNING_INSIDE_K8S == true ]]; then
    SCMM_URL="$(createUrl "scmm-scm-manager.default.svc.cluster.local" "80")/scm"
  else
    local scmmPortFromValuesYaml="$(grep 'nodePort:' "${PLAYGROUND_DIR}"/scm-manager/values.yaml | tail -n1 | cut -f2 -d':' | tr -d '[:space:]')"
    SCMM_URL="$(createUrl "${CLUSTER_BIND_ADDRESS}" "${scmmPortFromValuesYaml}")/scm"
  fi

  if [[ -n "${JENKINS_URL}" ]]; then
    INTERNAL_JENKINS=false
    # We can't use internal kubernetes services in this scenario
    JENKINS_URL_FOR_SCMM=${JENKINS_URL}
  elif [[ $RUNNING_INSIDE_K8S == true ]]; then
    JENKINS_URL=$(createUrl "jenkins.default.svc.cluster.local" "80")
  else
    local jenkinsPortFromValuesYaml="$(grep 'nodePort:' "${PLAYGROUND_DIR}"/jenkins/values.yaml | grep nodePort | tail -n1 | cut -f2 -d':' | tr -d '[:space:]')"
    JENKINS_URL=$(createUrl "${CLUSTER_BIND_ADDRESS}" "${jenkinsPortFromValuesYaml}")
  fi

  if [[ -z "${REGISTRY_URL}" ]]; then
    local registryPort
    registryPort='30000'
    if [[ -n "${INTERNAL_REGISTRY_PORT}" ]]; then
      registryPort="${INTERNAL_REGISTRY_PORT}"
    fi
    # Internal Docker registry must be on localhost. Otherwise docker will use HTTPS, leading to errors on docker push
    # in the example application's Jenkins Jobs.
    # Both setting up HTTPS or allowing insecure registry via daemon.json makes the playground difficult to use.
    # So, always use localhost.
    # Allow overriding the port, in case multiple playground instance run on a single host in different k3d clusters.
    REGISTRY_URL="localhost:${registryPort}"
    REGISTRY_PATH=""
  else
    INTERNAL_REGISTRY=false
  fi

  checkPrerequisites

  if [[ $DEBUG != true ]]; then
    backgroundLogFile=$(mktemp /tmp/playground-log-XXXXXXXXX)
    echo "Full log output is appended to ${backgroundLogFile}"
  fi


  evalWithSpinner "Basic setup & configuring registry..." applyBasicK8sResources

  initSCMMVars
  evalWithSpinner "Starting SCM-Manager..." initSCMM

  if [[ $INSTALL_FLUXV2 == true ]]; then
    evalWithSpinner "Starting Flux V2..." initFluxV2
  fi

  initJenkins

  if [[ $TRACE == true ]]; then
    set +x
  fi

  # call our groovy cli and pass in all params
  evalWithSpinner "Running apply-ng..." "$PLAYGROUND_DIR/scripts/apply-ng.sh" "$@"

  printWelcomeScreen
}

function findClusterBindAddress() {
  local potentialClusterBindAddress
  local localAddress
  
  # Use an internal IP to contact Jenkins and SCMM
  # For k3d this is either the host's IP or the IP address of the k3d API server's container IP (when --bind-localhost=false)
  # Note that this might return multiple InternalIP (IPV4 and IPV6) - we assume the first one is IPV4 (break after first)
  potentialClusterBindAddress="$(kubectl get "$(waitForNode)" \
          --template='{{range .status.addresses}}{{ if eq .type "InternalIP" }}{{.address}}{{break}}{{end}}{{end}}')"

  localAddress="$(ip route get 1 | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p')"

  # Check if we can use localhost instead of the external address
  # This address is later printed on the welcome screen, where localhost is much more constant and intuitive as the 
  # the external address. Also Jenkins notifications only work on localhost, not external addresses.
  # Note that this will only work when executed as a script locally, or in a container with --net=host.
  # When executing via kubectl run, this will still output the potentialClusterBindAddress.
  if [[ "${localAddress}" == "${potentialClusterBindAddress}" ]]; then 
    echo "localhost" 
  else 
    echo "${potentialClusterBindAddress}"
  fi
}

function waitForNode() {
  # With TLDR command from readme "kubectl get node" might be executed right after cluster start, where no nodes are 
  # returned, resulting in 'error: the server doesn't have a resource type ""'
  local nodes=""
  while [ -z "${nodes}" ]; do
    nodes=$(kubectl get node -oname)
    [ -z "${nodes}" ] && sleep 1
  done
  # Return first node
  kubectl get node -oname | head -n1
}

function evalWithSpinner() {

  spinnerOutput="${1}"
  shift
  function_args=("$@")

  commandToEval="$(printf "'%s' " "${function_args[@]}")"

  if [[ $DEBUG == true ]]; then
    eval "$commandToEval"
  else
    eval "$commandToEval" >>"${backgroundLogFile}" 2>&1 &
    spinner "${spinnerOutput}"
  fi
}

function checkPrerequisites() {
  if [[ ${INTERNAL_SCMM} == false || ${INTERNAL_JENKINS} == false ]]; then
    if [[ ${INTERNAL_SCMM} == true || ${INTERNAL_JENKINS} == true ]]; then
      error "When setting JENKINS_URL, SCMM_URL must also be set and the other way round."
      exit 1
    fi
  fi
}

function applyBasicK8sResources() {
  kubectl apply -f k8s-namespaces || true

  createSecrets

  helm repo add fluxcd https://charts.fluxcd.io
  helm repo add stable https://charts.helm.sh/stable
  helm repo add scm-manager https://packages.scm-manager.org/repository/helm-v2-releases/
  helm repo add jenkins https://charts.jenkins.io
  
  if [[ $SKIP_HELM_UPDATE == false ]]; then
    helm repo update
  fi

  # crd for servicemonitor. a prometheus operator specific resource
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/v0.9.0/manifests/setup/prometheus-operator-0servicemonitorCustomResourceDefinition.yaml

  initRegistry
}

function initRegistry() {
  if [[ "${INTERNAL_REGISTRY}" == true ]]; then
    helm upgrade -i docker-registry --values docker-registry/values.yaml --version 1.9.4 stable/docker-registry -n default
  fi
}

function initJenkins() {
  if [[ ${INTERNAL_JENKINS} == true ]]; then
    deployJenkinsCommand=(deployLocalJenkins "${SET_USERNAME}" "${SET_PASSWORD}" "${REMOTE_CLUSTER}" "${JENKINS_URL}")
    evalWithSpinner "Deploying Jenkins..." "${deployJenkinsCommand[@]}"

    setExternalHostnameIfNecessary "JENKINS" "jenkins" "default"

    JENKINS_USERNAME="${SET_USERNAME}"
    JENKINS_PASSWORD="${SET_PASSWORD}"
  fi

  configureJenkinsCommand=(configureJenkins "${JENKINS_URL}" "${JENKINS_USERNAME}" "${JENKINS_PASSWORD}"
    "${SCMM_URL_FOR_JENKINS}" "${SCMM_PASSWORD}" "${REGISTRY_URL}"
    "${REGISTRY_PATH}" "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}"
    "${INSTALL_FLUXV2}" "${INSTALL_ARGOCD}")

  evalWithSpinner "Configuring Jenkins..." "${configureJenkinsCommand[@]}"
}

function initSCMMVars() {
  if [[ ${INTERNAL_SCMM} == true ]]; then
    SCMM_USERNAME=${SET_USERNAME}
    SCMM_PASSWORD=${SET_PASSWORD}
  fi

  # Those are set here, because the "initSCMM" methods might be running in a background process (to display the spinner only)
  SCMM_HOST=$(getHost "${SCMM_URL}")
  SCMM_PROTOCOL=$(getProtocol "${SCMM_URL}")
}

function initSCMM() {
  if [[ ${INTERNAL_SCMM} == true ]]; then
    deployLocalScmmManager "${REMOTE_CLUSTER}" "${SET_USERNAME}" "${SET_PASSWORD}"
  fi

  setExternalHostnameIfNecessary 'SCMM' 'scmm-scm-manager' 'default'
  [[ "${SCMM_URL}" != *scm ]] && SCMM_URL=${SCMM_URL}/scm

  # When running in k3d, BASE_URL must be the internal URL. Otherwise webhooks from SCMM->Jenkins will fail, as
  # They contain Repository URLs create with BASE_URL. Jenkins uses the internal URL for repos. So match is only
  # successful, when SCM also sends the Repo URLs using the internal URL
  configureScmmManager "${SCMM_USERNAME}" "${SCMM_PASSWORD}" "${SCMM_URL}" "${JENKINS_URL_FOR_SCMM}" \
    "${SCMM_URL_FOR_JENKINS}" "${INTERNAL_SCMM}" "${INSTALL_FLUXV2}" "${INSTALL_ARGOCD}"

  pushHelmChartRepo 'common/spring-boot-helm-chart'
  pushHelmChartRepoWithDependency 'common/spring-boot-helm-chart-with-dependency'
  pushRepoMirror "${GITOPS_BUILD_LIB_REPO}" 'common/gitops-build-lib'
  pushRepoMirror "${CES_BUILD_LIB_REPO}" 'common/ces-build-lib' 'develop'
}

function setExternalHostnameIfNecessary() {
  local variablePrefix="$1"
  local serviceName="$2"
  local namespace="$3"

  # :-} expands to empty string, e.g. vor INTERNAL_ARGO which does not exist.
  # This only works when checking for != false 😬
  if [[ $REMOTE_CLUSTER == true && "$(eval echo "\${INTERNAL_${variablePrefix}:-}")" != 'false' ]]; then
    # Update SCMM_URL or JENKINS_URL or ARGOCD_URL
    # Only if apps are not external
    # Our apps are configured to use port 80 on remote clusters
    # Argo forwards to HTTPS so simply use HTTP here
    declare -g "${variablePrefix}_URL"="http://$(getExternalIP "${serviceName}" "${namespace}")"
  fi
}

function initFluxV2() {
  pushPetClinicRepo 'applications/fluxv2/petclinic/plain-k8s' 'fluxv2/petclinic-plain'

  initRepoWithSource 'fluxv2' 'fluxv2/gitops'

  REPOSITORY_YAML_PATH="fluxv2/clusters/gitops-playground/flux-system/gotk-sync.yaml"
  if [[ ${INTERNAL_SCMM} == false ]]; then
    REPOSITORY_YAML_PATH="$(mkTmpWithReplacedScmmUrls "fluxv2/clusters/gitops-playground/flux-system/gotk-sync.yaml")"
  fi

  kubectl apply -f fluxv2/clusters/gitops-playground/flux-system/gotk-components.yaml || true
  kubectl apply -f "${REPOSITORY_YAML_PATH}" || true
  kubectl apply -f fluxv2/clusters/gitops-playground/flux-system/gotk-kustomization.yaml || true
}

function replaceAllScmmUrlsInFolder() {
  CURRENT_DIR="${1}"

  while IFS= read -r -d '' file; do
    # shellcheck disable=SC2091
    # We want to execute this here
    $(buildScmmUrlReplaceCmd "$file" "-i")
  done < <(find "${CURRENT_DIR}" -name '*.yaml' -print0)
}

function buildScmmUrlReplaceCmd() {
  TARGET_FILE="${1}"
  SED_PARAMS="${2:-""}"
  echo 'sed '"${SED_PARAMS}"' -e '"s:http\\://scmm-scm-manager.default.svc.cluster.local/scm:${SCMM_PROTOCOL}\\://${SCMM_HOST}:g ${TARGET_FILE}"
}

function mkTmpWithReplacedScmmUrls() {
  REPLACE_FILE="${1}"
  TMP_FILENAME=$(mktemp /tmp/scmm-replace.XXXXXX)

  # shellcheck disable=SC2091
  # We want to execute this here
  $(buildScmmUrlReplaceCmd "${REPLACE_FILE}") >"${TMP_FILENAME}"

  echo "${TMP_FILENAME}"
}

function replaceAllImagesInJenkinsfile() {
  JENKINSFILE_PATH="${1}"

  replaceImageIfSet "$JENKINSFILE_PATH" 'kubectl' "$KUBECTL_DEFAULT_IMAGE" "$KUBECTL_IMAGE"
  replaceImageIfSet "$JENKINSFILE_PATH" 'helm' "$HELM_DEFAULT_IMAGE" "$HELM_IMAGE"
  replaceImageIfSet "$JENKINSFILE_PATH" 'kubeval' "$KUBEVAL_DEFAULT_IMAGE" "$KUBEVAL_IMAGE"
  replaceImageIfSet "$JENKINSFILE_PATH" 'helmKubeval' "$HELMKUBEVAL_DEFAULT_IMAGE" "$HELMKUBEVAL_IMAGE"
  replaceImageIfSet "$JENKINSFILE_PATH" 'yamllint' "$YAMLLINT_DEFAULT_IMAGE" "$YAMLLINT_IMAGE"
}

function replaceImageIfSet() {
  JENKINSFILE_PATH="${1}"
  IMAGE_KEY="${2}"
  DEFAULT_IMAGE="${3}"
  SET_IMAGE="${4:-""}"

  if [[ -n "${SET_IMAGE}" ]]; then
    FROM_IMAGE_STRING="$IMAGE_KEY: '$DEFAULT_IMAGE'"
    TO_IMAGE_STRING="$IMAGE_KEY: '$SET_IMAGE'"
    sed -i -e "s%${FROM_IMAGE_STRING}%${TO_IMAGE_STRING}%g" "${JENKINSFILE_PATH}"
  fi
}

function createSecrets() {
  createSecret gitops-scmm --from-literal=USERNAME=gitops --from-literal=PASSWORD=$SET_PASSWORD -n default
  # flux needs lowercase fieldnames
  createSecret flux-system --from-literal=username=gitops --from-literal=password=$SET_PASSWORD -n flux-system
}

function createSecret() {
  kubectl create secret generic "$@" --dry-run=client -oyaml | kubectl apply -f-
}

function pushPetClinicRepo() {
  LOCAL_PETCLINIC_SOURCE="$1"
  TARGET_REPO_SCMM="$2"

  TMP_REPO=$(mktemp -d)

  git clone -n "${SPRING_PETCLINIC_REPO}" "${TMP_REPO}" --quiet >/dev/null 2>&1
  (
    cd "${TMP_REPO}"
    # Checkout a defined commit in order to get a deterministic result
    git checkout ${PETCLINIC_COMMIT} --quiet

    cp -r "${PLAYGROUND_DIR}/${LOCAL_PETCLINIC_SOURCE}"/* .

    replaceAllImagesInJenkinsfile "${TMP_REPO}/Jenkinsfile"

    if [[ $REMOTE_CLUSTER != true ]]; then
      # Set NodePort service, to avoid "Pending" services and "Processing" state in argo
      find . \( -name service.yaml -o -name values-shared.yaml \) -exec sed -i "s/LoadBalancer/NodePort/" {} \;
    fi

    git checkout -b main --quiet
    git add .
    git commit -m 'Add GitOps Pipeline and K8s resources' --quiet

    waitForScmManager
    git push -u "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/repo/${TARGET_REPO_SCMM}" HEAD:main --force --quiet
  )

  rm -rf "${TMP_REPO}"

  setDefaultBranch "${TARGET_REPO_SCMM}"
}

function pushHelmChartRepo() {
  TARGET_REPO_SCMM="$1"

  TMP_REPO=$(mktemp -d)
  git clone -n "${SPRING_BOOT_HELM_CHART_REPO}" "${TMP_REPO}" --quiet
  (
    cd "${TMP_REPO}"
    # Checkout a defined commit in order to get a deterministic result
    git checkout ${SPRING_BOOT_HELM_CHART_COMMIT} --quiet

    # Create a defined version to use in demo applications
    git tag 1.0.0

    git branch --quiet -d main
    git checkout --quiet -b main

    waitForScmManager
    git push "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/repo/${TARGET_REPO_SCMM}" HEAD:main --force --quiet
    git push "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/repo/${TARGET_REPO_SCMM}" refs/tags/1.0.0 --quiet --force
  )

  rm -rf "${TMP_REPO}"

  setDefaultBranch "${TARGET_REPO_SCMM}"
}

function pushHelmChartRepoWithDependency() {
  TARGET_REPO_SCMM="$1"

  TMP_REPO=$(mktemp -d)
  git clone -n "${SPRING_BOOT_HELM_CHART_REPO}" "${TMP_REPO}" --quiet
  (
    cd "${TMP_REPO}"
    # Checkout a defined commit in order to get a deterministic result
    git checkout ${SPRING_BOOT_HELM_CHART_COMMIT} --quiet

    # Create a defined version to use in demo applications
    git tag 1.0.0

    git branch --quiet -d main
    git checkout --quiet -b main

    echo "dependencies:
- name: podinfo
  version: \"5.2.0\"
  repository: \"https://stefanprodan.github.io/podinfo\"" >>./Chart.yaml

    git commit -a -m "Added dependency" --quiet

    waitForScmManager
    git push "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/repo/${TARGET_REPO_SCMM}" HEAD:main --force --quiet
    git push "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/repo/${TARGET_REPO_SCMM}" refs/tags/1.0.0 --quiet --force
  )

  rm -rf "${TMP_REPO}"

  setDefaultBranch "${TARGET_REPO_SCMM}"
}

function pushRepoMirror() {
  SOURCE_REPO_URL="$1"
  TARGET_REPO_SCMM="$2"
  DEFAULT_BRANCH="${3:-main}"

  TMP_REPO=$(mktemp -d)
  git clone --bare "${SOURCE_REPO_URL}" "${TMP_REPO}" --quiet
  (
    cd "${TMP_REPO}"
    waitForScmManager
    git push --mirror "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/repo/${TARGET_REPO_SCMM}" --force --quiet
  )

  rm -rf "${TMP_REPO}"

  setDefaultBranch "${TARGET_REPO_SCMM}" "${DEFAULT_BRANCH}"
}

function initRepoWithSource() {
  echo "initiating repo $1 with source $2"
  SOURCE_REPO="$1"
  TARGET_REPO_SCMM="$2"
  EVAL_IN_REPO="${3-}"

  TMP_REPO=$(mktemp -d)

  git clone "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/repo/${TARGET_REPO_SCMM}" "${TMP_REPO}"
  (
    cd "${TMP_REPO}"
    cp -r "${PLAYGROUND_DIR}/${SOURCE_REPO}"/* .
    if [[ ${INTERNAL_SCMM} == false ]]; then
      replaceAllScmmUrlsInFolder "${TMP_REPO}"
    fi

    if [[ -n "${EVAL_IN_REPO}" ]]; then
      eval "${EVAL_IN_REPO}"
    fi

    git checkout main --quiet || git checkout -b main --quiet
    git add .
    git commit -m "Init ${TARGET_REPO_SCMM}" --quiet || true
    waitForScmManager
    git push -u "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/repo/${TARGET_REPO_SCMM}" HEAD:main --force
  )

  rm -rf "${TMP_REPO}"

  setDefaultBranch "${TARGET_REPO_SCMM}"
}

function setDefaultBranch() {
  TARGET_REPO_SCMM="$1"
  DEFAULT_BRANCH="${2:-main}"

  curl -s -L -X PUT -H 'Content-Type: application/vnd.scmm-gitConfig+json' \
    --data-raw "{\"defaultBranch\":\"${DEFAULT_BRANCH}\"}" \
    "${SCMM_PROTOCOL}://${SCMM_USERNAME}:${SCMM_PASSWORD}@${SCMM_HOST}/api/v2/config/git/${TARGET_REPO_SCMM}"
}

function createUrl() {
  local hostname="$1"
  local port="$2"

  if [[ -z "${port}" ]]; then
    error "No port found for hostname ${hostname}"
    exit 1
  fi

  # Argo forwards to HTTPS so simply use HTTP here
  echo -n "http://${hostname}"
  echo -n ":${port}"
  #  [[ "${port}" != 80 && "${port}" != 443 ]] && echo -n ":${port}"
}

function printWelcomeScreen() {

  if [[ $RUNNING_INSIDE_K8S == true ]]; then
    # Internal service IPs have been set above.
    # * Local k3d: Replace them by k3d container IP.
    # * Remote cluster: Overwrite with setExternalHostnameIfNecessary() if necessary

    local scmmPortFromValuesYaml="$(grep 'nodePort:' "${PLAYGROUND_DIR}"/scm-manager/values.yaml | tail -n1 | cut -f2 -d':' | tr -d '[:space:]')"
    SCMM_URL="$(createUrl "${CLUSTER_BIND_ADDRESS}" "${scmmPortFromValuesYaml}")/scm"
    setExternalHostnameIfNecessary 'SCMM' 'scmm-scm-manager' 'default'
    [[ "${SCMM_URL}" != *scm ]] && SCMM_URL=${SCMM_URL}/scm


    local jenkinsPortFromValuesYaml="$(grep 'nodePort:' "${PLAYGROUND_DIR}"/jenkins/values.yaml | grep nodePort | tail -n1 | cut -f2 -d':' | tr -d '[:space:]')"
    JENKINS_URL=$(createUrl "${CLUSTER_BIND_ADDRESS}" "${jenkinsPortFromValuesYaml}")
    setExternalHostnameIfNecessary 'JENKINS' 'jenkins' 'default'
  fi

  if [[ -z "${JENKINS_URL}" ]]; then
    setExternalHostnameIfNecessary 'JENKINS' 'jenkins' 'default'
  fi

  echo
  echo
  echo "|----------------------------------------------------------------------------------------------|"
  echo "|                     ☁️  Welcome to the GitOps playground by Cloudogu! ☁️                       |"
  echo "|----------------------------------------------------------------------------------------------|"
  echo "|"
  echo "| The playground features example applications for different GitOps operators in SCM-Manager."
  echo "| See here:"
  echo "|"

  if [[ $INSTALL_FLUXV2 == true ]]; then
    echo -e "| - \e[32m${SCMM_URL}/repos/fluxv2/\e[0m"
  fi
  if [[ $INSTALL_ARGOCD == true ]]; then
    echo -e "| - \e[32m${SCMM_URL}/repos/argocd/\e[0m"
  fi

  echo "|"
  echo -e "| Credentials for SCM-Manager and Jenkins are: \e[31m${SET_USERNAME}/${SET_PASSWORD}\e[0m"
  echo "|"
  echo "| Once Jenkins is up, the following jobs can be started after scanning the corresponding "
  echo "| namespace via the jenkins UI:"
  echo "|"

  if [[ $INSTALL_FLUXV2 == true ]]; then
    echo -e "| - \e[32m${JENKINS_URL}/job/fluxv2-applications/\e[0m"
  fi
  if [[ $INSTALL_ARGOCD == true ]]; then
    echo -e "| - \e[32m${JENKINS_URL}/job/argocd-applications/\e[0m"
  fi
  echo "|"
  echo "| During the job, jenkins pushes into the corresponding GitOps repo and creates a pull"
  echo "| request for production:"
  echo "|"

  printWelcomeScreenFluxV2

  printWelcomeScreenArgocd

  echo "| After a successful Jenkins build, the staging application will be deployed into the cluster."
  echo "|"
  echo "| The production applications can be deployed by accepting Pull Requests."
  echo "| Shortly after the PullRequest has been accepted, the GitOps operator "
  echo "| deploys to production."
  echo "|"
  echo "| Please see the README.md for how to find out the URLs of the individual applications."
  echo "|"
  echo "|----------------------------------------------------------------------------------------------|"
}

function printWelcomeScreenFluxV2() {
  if [[ $INSTALL_FLUXV2 == true ]]; then
    echo "| For Flux V2:"
    echo "|"
    echo -e "| - GitOps repo: \e[32m${SCMM_URL}/repo/fluxv2/gitops/code/sources/main/\e[0m"
    echo -e "| - Pull requests: \e[32m${SCMM_URL}/repo/fluxv2/gitops/pull-requests\e[0m"
    echo "|"
  fi
}

function printWelcomeScreenArgocd() {


  ARGOCD_URL="$(createUrl "${CLUSTER_BIND_ADDRESS}" "$(grep 'nodePortHttp:' "${PLAYGROUND_DIR}"/argocd/argocd/argocd/values.yaml | tail -n1 | cut -f2 -d':' | tr -d '[:space:]')")"
  setExternalHostnameIfNecessary 'ARGOCD' 'argocd-server' 'argocd'

  if [[ $INSTALL_ARGOCD == true ]]; then
    echo "| For ArgoCD:"
    echo "|"
    echo -e "| - GitOps repo: \e[32m${SCMM_URL}/repo/argocd/example-apps/code/sources/main/\e[0m"
    echo -e "| - Pull requests: \e[32m${SCMM_URL}/repo/argocd/example-apps/pull-requests\e[0m"
    echo "|"
    echo -e "| There is also the ArgoCD UI which can be found at \e[32m${ARGOCD_URL}/\e[0m"
    echo -e "| Credentials for the ArgoCD UI are: \e[31m${SET_USERNAME}/${SET_PASSWORD}\e[0m"
    echo "|"
  fi
}

function printUsage() {
  echo "This script will install all necessary resources for Flux V2 and ArgoCD into your k8s-cluster."
  echo ""
  printParameters
  echo ""
}

function printParameters() {
  echo "The following parameters are valid:"
  echo
  echo " -h | --help     >> Help screen"
  echo
  echo "Install only the desired GitOps operators. Multiple selections possible."
  echo "    | --fluxv2   >> Install the Flux V2"
  echo "    | --argocd   >> Install the ArgoCD"
  echo
  echo "    | --remote   >> Install on remote Cluster e.g. gcp"
  echo
  echo "    | --password=myPassword   >> Set initial admin passwords to 'myPassword'"
  echo
  echo "Configure external jenkins. Use this 3 parameters to configure an external jenkins"
  echo "    | --jenkins-url=http://jenkins   >> The url of your external jenkins"
  echo "    | --jenkins-username=myUsername  >> Mandatory when --jenkins-url is set"
  echo "    | --jenkins-password=myPassword  >> Mandatory when --jenkins-url is set"
  echo
  echo "Configure external scm-manager. Use this 3 parameters to configure an external scmm"
  echo "    | --scmm-url=http://scm-manager:8080   >> The host of your external scm-manager"
  echo "    | --scmm-username=myUsername  >> Mandatory when --scmm-url is set"
  echo "    | --scmm-password=myPassword  >> Mandatory when --scmm-url is set"
  echo
  echo "Configure external docker registry. Use this 4 parameters to configure an external docker registry"
  echo "    | --registry-url=registry         >> The url of your external registry"
  echo "    | --registry-path=public          >> Optional when --registry-url is set"
  echo "    | --registry-username=myUsername  >> Optional when --registry-url is set"
  echo "    | --registry-password=myPassword  >> Optional when --registry-url is set"
  echo "    | --internal-registry-port         >> Port of registry registry. Ignored when registry-url is set."
  echo
  echo "Configure ArgoCD."
  echo "    | --argocd-url=http://my-argo.com    >> The URL where argocd is accessible. It has to be the full URL with http:// or https://"
  echo
  echo "Configure images used by the gitops-build-lib in the application examples"
  echo "    | --kubectl-image      >> Sets image for kubectl"
  echo "    | --helm-image         >> Sets image for helm"
  echo "    | --kubeval-image      >> Sets image for kubeval"
  echo "    | --helmkubeval-image  >> Sets image for helmkubeval"
  echo "    | --yamllint-image     >> Sets image for yamllint"
  echo
  echo "Configure images for tools"
  echo "    | --grafana-image      >> Sets image for grafana"
  echo "    | --grafana-sidecar-image >> Sets image for grafana's sidecar"
  echo "    | --prometheus-image >> Sets image for prometheus"
  echo "    | --prometheus-operator-image >> Sets image for prometheus-operator"
  echo "    | --prometheus-config-reloader-image >> Sets image for prometheus-operator's config reloader"
  echo "    | --external-secrets-image  >> Sets image for external secrets operator"
  echo "    | --external-secrets-certcontroller-image >> Sets image for external secrets operator's cert controller"
  echo "    | --external-secrets-webhook-image >> Sets image for external secrets operator's webhook controller"
  echo "    | --vault-image >> Sets image for vault"
  echo "    | --nginx-image >> Sets image for nginx used in various applications"
  echo
  echo "General settings"
  echo "    | --insecure            >> Runs curl in insecure mode"
  echo "    | --skip-helm-update    >> Skips adding and updating helm repos"
  echo
  echo "Configure additional modules"
  echo "    | --monitoring, --metrics        >> Installs the Kube-Prometheus-Stack for ArgoCD. This includes Prometheus, the Prometheus operator, Grafana and some extra resources"
  echo
  echo " -d | --debug         >> Debug output"
  echo " -x | --trace         >> Debug + Show each command executed (set -x)"
  echo " -y | --yes           >> Skip kubecontext confirmation"
}

readParameters() {
  COMMANDS=$(getopt \
    -o hdxyc \
    --long help,fluxv2,argocd,argocd-url:,debug,remote,username:,password:,jenkins-url:,jenkins-username:,jenkins-password:,registry-url:,registry-path:,registry-username:,registry-password:,internal-registry-port:,scmm-url:,scmm-username:,scmm-password:,kubectl-image:,helm-image:,kubeval-image:,helmkubeval-image:,yamllint-image:,grafana-image:,grafana-sidecar-image:,prometheus-image:,prometheus-operator-image:,prometheus-config-reloader-image:,external-secrets-image:,external-secrets-certcontroller-image:,external-secrets-webhook-image:,vault-image:,nginx-image:,trace,insecure,yes,skip-helm-update,metrics,monitoring,vault: \
    -- "$@")
  
  if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
  fi
  
  eval set -- "$COMMANDS"
  
  DEBUG=false
  INSTALL_FLUXV2=false
  INSTALL_ARGOCD=false
  REMOTE_CLUSTER=false
  SET_USERNAME="admin"
  SET_PASSWORD="admin"
  JENKINS_URL=""
  JENKINS_USERNAME=""
  JENKINS_PASSWORD=""
  REGISTRY_URL=""
  REGISTRY_PATH=""
  REGISTRY_USERNAME=""
  REGISTRY_PASSWORD=""
  INTERNAL_REGISTRY_PORT=""
  SCMM_URL=""
  SCMM_USERNAME=""
  SCMM_PASSWORD=""
  KUBECTL_IMAGE=""
  HELM_IMAGE=""
  KUBEVAL_IMAGE=""
  HELMKUBEVAL_IMAGE=""
  YAMLLINT_IMAGE=""
  INSECURE=false
  TRACE=false
  ASSUME_YES=false
  SKIP_HELM_UPDATE=false
  DEPLOY_METRICS=false
  ARGOCD_URL=""
  
  while true; do
    case "$1" in
      -h | --help          ) printUsage; exit 0 ;;
      --fluxv2             ) INSTALL_FLUXV2=true; shift ;;
      --argocd             ) INSTALL_ARGOCD=true; shift ;;
      --argocd-url         ) ARGOCD_URL="$2"; shift 2 ;;
      --remote             ) REMOTE_CLUSTER=true; shift ;;
      --jenkins-url        ) JENKINS_URL="$2"; shift 2 ;;
      --jenkins-username   ) JENKINS_USERNAME="$2"; shift 2 ;;
      --jenkins-password   ) JENKINS_PASSWORD="$2"; shift 2 ;;
      --registry-url       ) REGISTRY_URL="$2"; shift 2 ;;
      --registry-path      ) REGISTRY_PATH="$2"; shift 2 ;;
      --registry-username  ) REGISTRY_USERNAME="$2"; shift 2 ;;
      --registry-password  ) REGISTRY_PASSWORD="$2"; shift 2 ;;
      --internal-registry-port ) INTERNAL_REGISTRY_PORT="$2"; shift 2 ;;
      --scmm-url           ) SCMM_URL="$2"; shift 2 ;;
      --scmm-username      ) SCMM_USERNAME="$2"; shift 2 ;;
      --scmm-password      ) SCMM_PASSWORD="$2"; shift 2 ;;
      --kubectl-image      ) KUBECTL_IMAGE="$2"; shift 2 ;;
      --helm-image         ) HELM_IMAGE="$2"; shift 2 ;;
      --kubeval-image      ) KUBEVAL_IMAGE="$2"; shift 2 ;;
      --helmkubeval-image  ) HELMKUBEVAL_IMAGE="$2"; shift 2 ;;
      --yamllint-image     ) YAMLLINT_IMAGE="$2"; shift 2 ;;
      --grafana-image      ) shift 2;; # Ignore, used in groovy only
      --grafana-sidecar-image ) shift 2;; # Ignore, used in groovy only
      --prometheus-image ) shift 2;; # Ignore, used in groovy only
      --prometheus-operator-image ) shift 2;; # Ignore, used in groovy only
      --prometheus-config-reloader-image ) shift 2;; # Ignore, used in groovy only
      --external-secrets-image ) shift 2;; # Ignore, used in groovy only
      --external-secrets-certcontroller-image ) shift 2;; # Ignore, used in groovy only
      --external-secrets-webhook-image ) shift 2;; # Ignore, used in groovy only
      --vault-image        ) shift 2;; # Ignore, used in groovy only
      --nginx-image        ) shift 2;; # Ignore, used in groovy only
      --insecure           ) INSECURE=true; shift ;;
      --username           ) SET_USERNAME="$2"; shift 2 ;;
      --password           ) SET_PASSWORD="$2"; shift 2 ;;
      -d | --debug         ) DEBUG=true; shift ;;
      -x | --trace         ) TRACE=true; shift ;;
      -y | --yes           ) ASSUME_YES=true; shift ;;
      --skip-helm-update   ) SKIP_HELM_UPDATE=true; shift ;;
      --metrics | --monitoring ) DEPLOY_METRICS=true; shift;;
      --vault              ) shift 2;; # Ignore, used in groovy only
      --                   ) shift; break ;;
    *) break ;;
    esac
  done
}

main "$@"
