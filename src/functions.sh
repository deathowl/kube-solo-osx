#!/bin/bash

# shared functions library

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )


function pause(){
    read -p "$*"
}

function check_vm_status() {
# check VM status
status=$(ps aux | grep "[k]ube-solo/bin/xhyve" | awk '{print $2}')
if [ "$status" = "" ]; then
    echo " "
    echo "CoreOS VM is not running, please start VM !!!"
    pause "Press any key to continue ..."
    exit 1
fi
}


function release_channel(){
# Set release channel
LOOP=1
while [ $LOOP -gt 0 ]
do
    VALID_MAIN=0
    echo " "
    echo "Set CoreOS Release Channel:"
    echo " 1)  Alpha "
    echo " 2)  Beta "
    echo " 3)  Stable "
    echo " "
    echo -n "Select an option: "

    read RESPONSE
    XX=${RESPONSE:=Y}

    if [ $RESPONSE = 1 ]
    then
        VALID_MAIN=1
        sed -i "" "s/CHANNEL=stable/CHANNEL=alpha/" ~/kube-solo/custom.conf
        sed -i "" "s/CHANNEL=beta/CHANNEL=alpha/" ~/kube-solo/custom.conf
        sed -i "" "s/CHANNEL=stable/CHANNEL=alpha/" ~/kube-solo/custom-format-root.conf
        sed -i "" "s/CHANNEL=beta/CHANNEL=alpha/" ~/kube-solo/custom-format-root.conf
        channel="Alpha"
        LOOP=0
    fi

    if [ $RESPONSE = 2 ]
    then
        VALID_MAIN=1
        sed -i "" "s/CHANNEL=alpha/CHANNEL=beta/" ~/kube-solo/custom.conf
        sed -i "" "s/CHANNEL=stable/CHANNEL=beta/" ~/kube-solo/custom.conf
        sed -i "" "s/CHANNEL=alpha/CHANNEL=beta/" ~/kube-solo/custom-format-root.conf
        sed -i "" "s/CHANNEL=stable/CHANNEL=beta/" ~/kube-solo/custom-format-root.conf
        channel="Beta"
        LOOP=0
    fi

    if [ $RESPONSE = 3 ]
    then
        VALID_MAIN=1
        sed -i "" "s/CHANNEL=alpha/CHANNEL=stable/" ~/kube-solo/custom.conf
        sed -i "" "s/CHANNEL=beta/CHANNEL=stable/" ~/kube-solo/custom.conf
        sed -i "" "s/CHANNEL=alpha/CHANNEL=stable/" ~/kube-solo/custom-format-root.conf
        sed -i "" "s/CHANNEL=beta/CHANNEL=stable/" ~/kube-solo/custom-format-root.conf
        channel="Stable"
        LOOP=0
    fi

    if [ $VALID_MAIN != 1 ]
    then
        continue
    fi
done
}


create_root_disk() {
# create persistent disk
cd ~/kube-solo/
echo "  "
echo "Please type ROOT disk size in GB followed by [ENTER]:"
echo -n [default is 5]:
read disk_size
if [ -z "$disk_size" ]
then
echo "Creating 5GB disk ..."
dd if=/dev/zero of=root.img bs=1024 count=0 seek=$[1024*5120]
else
echo "Creating "$disk_size"GB disk ..."
dd if=/dev/zero of=root.img bs=1024 count=0 seek=$[1024*$disk_size*1024]
fi
#

### format ROOT disk
# Start webserver
cd ~/kube-solo/cloud-init
"${res_folder}"/bin/webserver start

# Get password
my_password=$(cat ~/kube-solo/.env/password | base64 --decode )
echo -e "$my_password\n" | sudo -S ls > /dev/null 2>&1

# Start VM
echo "Waiting for VM to boot up for ROOT disk to be formated ... "
cd ~/kube-solo
export XHYVE=~/kube-solo/bin/xhyve
"${res_folder}"/bin/coreos-xhyve-run -f custom-format-root.conf kube-solo

echo "ROOT disk got created and formated... "
echo " "

# Stop webserver
"${res_folder}"/bin/webserver stop
###

}

function download_osx_clients() {
# download fleetctl file
LATEST_RELEASE=$(ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no core@$vm_ip 'fleetctl version' | cut -d " " -f 3- | tr -d '\r')
cd ~/kube-solo/bin
echo "Downloading fleetctl v$LATEST_RELEASE for OS X"
curl -L -o fleet.zip "https://github.com/coreos/fleet/releases/download/v$LATEST_RELEASE/fleet-v$LATEST_RELEASE-darwin-amd64.zip"
unzip -j -o "fleet.zip" "fleet-v$LATEST_RELEASE-darwin-amd64/fleetctl"
rm -f fleet.zip
echo "fleetctl was copied to ~/kube-solo/bin "
#

}


function download_k8s_files() {
#
cd ~/kube-solo/tmp

# get latest k8s version
function get_latest_version_number {
    local -r latest_url="https://storage.googleapis.com/kubernetes-release/release/latest.txt"
    curl -Ss ${latest_url}
}

K8S_VERSION=$(get_latest_version_number)

# download latest version of kubectl for OS X
cd ~/kube-solo/tmp
echo "Downloading kubectl $K8S_VERSION for OS X"
curl -k -L https://storage.googleapis.com/kubernetes-release/release/$K8S_VERSION/bin/darwin/amd64/kubectl >  ~/kube-solo/bin/kubectl
chmod 755 ~/kube-solo/bin/kubectl
echo "kubectl was copied to ~/kube-solo/bin"
echo " "

# clean up tmp folder
rm -rf ~/kube-solo/tmp/*

# download latest version of k8s for CoreOS
echo "Downloading latest version of Kubernetes"
bins=( kubectl kubelet kube-proxy kube-apiserver kube-scheduler kube-controller-manager )
for b in "${bins[@]}"; do
    curl -k -L https://storage.googleapis.com/kubernetes-release/release/$K8S_VERSION/bin/linux/amd64/$b > ~/kube-solo/tmp/$b
done
#
tar czvf kube.tgz *
cp -f kube.tgz ~/kube-solo/kube/
# clean up tmp folder
rm -rf ~/kube-solo/tmp/*
echo " "

# get VM IP
vm_ip=$(cat ~/kube-solo/.env/ip_address)

# install k8s files
echo "Installing latest version of Kubernetes ..."
cd ~/kube-solo/kube
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no kube.tgz core@$vm_ip:/home/core
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no core@$vm_ip 'sudo /usr/bin/mkdir -p /opt/bin && sudo tar xzf /home/core/kube.tgz -C /opt/bin && sudo chmod 755 /opt/bin/*'
echo "Done with k8solo-01 "
echo " "

}


function check_for_images() {
# Check if set channel's images are present
CHANNEL=$(cat ~/kube-solo/custom.conf | grep CHANNEL= | head -1 | cut -f2 -d"=")
LATEST=$(ls -r ~/kube-solo/imgs/${CHANNEL}.*.vmlinuz | head -n 1 | sed -e "s,.*${CHANNEL}.,," -e "s,.coreos_.*,," )
if [[ -z ${LATEST} ]]; then
    echo "Couldn't find anything to load locally (${CHANNEL} channel)."
    echo "Fetching lastest $CHANNEL channel ISO ..."
    echo " "
    cd ~/kube-solo/
    "${res_folder}"/bin/coreos-xhyve-fetch -f custom.conf
fi
}


function deploy_fleet_units() {
# deploy fleet units from ~/kube-solo/fleet
if [ "$(ls ~/kube-solo/fleet | grep -o -m 1 service)" = "service" ]
then
    cd ~/kube-solo/fleet
    echo " "
    echo "Starting all fleet units in ~/kube-solo/fleet:"
    fleetctl start *.service
    echo " "
    echo "fleetctl list-units:"
    fleetctl list-units
    echo " "
fi
}

