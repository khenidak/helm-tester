#! /bin/bash

set -o errexit
set -o nounset
set -o pipefail


# for simplicity we use current dir to install binaries
# that are not packaged, e.g., KIND
declare -r SCRIPT_PATH=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

## rename this to match your need. this is the kind cluster we will create
declare -r TEST_CLUSTER_NAME="helm-cluster"

# script args.. ; separated list of charts
# each is a directory.
declare -r CHART_LIST="$1"
declare -r CHART_LIST_DELIMTER=";"


#wait time before retrying.
declare -r WAIT_SLEEP=10s
# number of times we iterate and wait
declare -r WAIT_COUNT=6

# copied with gratitude from:
# https://stackoverflow.com/questions/5947742/how-to-change-the-output-color-of-echo-in-linux
Color_Off='\033[0m'       # Text Reset

# Regular Colors
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Blue='\033[0;34m'         # Blue
Purple='\033[0;35m'       # Purple
Cyan='\033[0;36m'         # Cyan
White='\033[0;37m'        # White

# Bold
BBlack='\033[1;30m'       # Black
BRed='\033[1;31m'         # Red
BGreen='\033[1;32m'       # Green
BYellow='\033[1;33m'      # Yellow
BBlue='\033[1;34m'        # Blue
BPurple='\033[1;35m'      # Purple
BCyan='\033[1;36m'        # Cyan
BWhite='\033[1;37m'       # White

# Underline
UBlack='\033[4;30m'       # Black
URed='\033[4;31m'         # Red
UGreen='\033[4;32m'       # Green
UYellow='\033[4;33m'      # Yellow
UBlue='\033[4;34m'        # Blue
UPurple='\033[4;35m'      # Purple
UCyan='\033[4;36m'        # Cyan
UWhite='\033[4;37m'       # White


# common log function
function common::__log(){
	local color=$1
	local message=$2
	printf "${color}${message}${Color_Off}\n"
}


function common::info(){
	local message=$1
	 common::__log "${Color_Off}" "[INFO]: ${message}"
}
function common::warn(){
	local message=$1
	common::__log "${Yellow}" "[WRN]:${message}"
}

function common::error(){
	local message=$1
	common::__log "${Red}" "[$(caller)] err:${message}"
	exit 1
}


# checks if a tool is in path and is executabe
function common::tool_exists(){
	local tool_name=$1
	if ! [ -x "$(command -v ${tool_name})" ]; then
			echo "0"
			return
	fi
	echo "1"
}

# ensures that whatever deps we need are installed
install_deps(){
	common::info "Install Deps"

	common::info "check helm"
	if  [ "0" == $(common::tool_exists "helm") ]; then
		common::warn "helm dos not exist, installing helm"

		# copied from: https://helm.sh/docs/intro/install/
		# should only add keys for entities you trust, in this case we do
		curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
		sudo apt-get install apt-transport-https --yes
		echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
		sudo apt-get update
		sudo apt-get -y install helm
	else
		common::info "helm already installed" 
	fi

	common::info "check KIND"
	if  [ "0" == $(common::tool_exists "${SCRIPT_PATH}/kind") ]; then 
		common::warn "kind is not found at ${SCRIPT_PATH}/kind .. installing"
		## copied from: https://kind.sigs.k8s.io/docs/user/quick-start/
		## would be nice if we can find a way to have this packaged.
		## because our CI will depend on the avail of https://kind.sigs.k8s.io
		# For Intel Macs
		[ $(uname -m) = x86_64 ] && curl -Lo ${SCRIPT_PATH}/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-darwin-amd64
		# For M1 / ARM Macs
		[ $(uname -m) = arm64 ] && curl -Lo ${SCRIPT_PATH}/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-darwin-arm64
		chmod +x ./kind
	else
		common::info "kind already intalled at $SCRIPT_PATH"
	fi

	common::info "check kubectl"
	if  [ "0" == $(common::tool_exists "kubectl") ]; then 
		common::warn "kubctl not intsalled .. installing"
		# copied from: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
		# again, make sure you configure keys from places you trust
		sudo apt-get update
		sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

		curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
		sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg # allow unprivileged APT programs to read this keyring
	
		echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
		sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list   # helps tools such as command-not-found to work correctly


		sudo apt-get update
		sudo apt-get install -y kubectl
	else
		common::info "kubectl was already installed"
	fi

}

# creates a kind cluster
create_clutser(){
	common::info "creating ${TEST_CLUSTER_NAME} kind clutser, will wait 2m for control plane"
	kind delete cluster --name ${TEST_CLUSTER_NAME} || true
	kind create cluster --name ${TEST_CLUSTER_NAME} --wait 2m

	# run kubectl so we are sure that the cluster came up
	kubectl cluster-info --context kind-helm-cluster	
}


# deploy all charts
deploy_charts(){
	common::info "deploying charts"
	declare -r separated_charts="${CHART_LIST//;/$'\n'}"
	for chart in $separated_charts; do
		declare -r chart_name="$(basename ${chart})"
  	common::info "deploying $chart named as ${chart_name}"
		helm install "${chart_name}" "${chart}"
		helm test  "${chart}"
	done
}


## validates that all pods are running
validate_charts(){
	common::info "validating that things are running"
	common::warn "will try for ${WAIT_COUNT} sleeping for ${WAIT_SLEEP} in between each"

	declare -r expected_result="No resources found"	
	declare RESULTS=""
	for i in $(seq 1 ${WAIT_COUNT});
	do
    common::info "iteration number $i"
		RESULTS="$(kubectl get pods --field-selector='status.phase!=Running,status.phase!=Succeeded' --all-namespaces  2>&1 )"
		if [ "${expected_result}" == "${RESULTS}" ]; then
			common::info "Success!"
			break
		fi
		common::warn "didn't get expected result: ${expected_result}"
		common::warn "will sleep for ${WAIT_SLEEP}"
		sleep ${WAIT_SLEEP}
	done
}

# validates that charts are running
# start main


# check if we have chart list
if [ "" == ${CHART_LIST} ]; then
	common::error "must be called <script> \"<chart list>\" (; separated chart paths)"
fi

#install_deps
create_clutser
deploy_charts 
validate_charts
