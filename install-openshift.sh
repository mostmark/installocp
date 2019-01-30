#!/bin/bash

## Default variables to use
export INTERACTIVE=${INTERACTIVE:="true"}
export PVS=${INTERACTIVE:="true"}
export DOMAIN=${DOMAIN:="$(curl -s ipinfo.io/ip).nip.io"}
export OCP_USERNAME=${OCP_USERNAME:="$(whoami)"}
export OCP_PASSWORD=${OCP_PASSWORD:=password}
export VERSION=${VERSION:="3.11"}
export SCRIPT_REPO=${SCRIPT_REPO:="https://raw.githubusercontent.com/mostmark/installocp/master"}
export IP=${IP:="$(ip route get 8.8.8.8 | awk '{print $NF; exit}')"}
export HOSTNAME=${HOSTNAME:="$(hostname)"}
export API_PORT=${API_PORT:="8443"}
export RH_USERNAME=${RH_USERNAME:="$(whoami)"}
export RH_PASSWORD=${RH_PASSWORD:=password}
export RH_SUB_POOL_ID=${RH_SUB_POOL_ID:=my-pool-id}

## Make the script interactive to set the variables
if [ "$INTERACTIVE" = "true" ]; then
	read -rp "Domain to use: ($DOMAIN): " choice;
	if [ "$choice" != "" ] ; then
		export DOMAIN="$choice";
	fi

	read -rp "Openshift Username: ($OCP_USERNAME): " choice;
	if [ "$choice" != "" ] ; then
		export OCP_USERNAME="$choice";
	fi

	read -rp "Openshift Password: ($OCP_PASSWORD): " choice;
	if [ "$choice" != "" ] ; then
		export OCP_PASSWORD="$choice";
	fi

	read -rp "OpenShift Version: ($VERSION): " choice;
	if [ "$choice" != "" ] ; then
		export VERSION="$choice";
	fi

	read -rp "IP: ($IP): " choice;
	if [ "$choice" != "" ] ; then
		export IP="$choice";
	fi

	read -rp "HOSTNAME: ($HOSTNAME): " choice;
	if [ "$choice" != "" ] ; then
		export HOSTNAME="$choice";
	fi

	read -rp "API Port: ($API_PORT): " choice;
	if [ "$choice" != "" ] ; then
		export API_PORT="$choice";
	fi

	read -rp "Red Hat Username: ($RH_USERNAME): " choice;
	if [ "$choice" != "" ] ; then
		export RH_USERNAME="$choice";
	fi

	read -rp "Red Hat Password: ($RH_PASSWORD): " choice;
	if [ "$choice" != "" ] ; then
		export RH_PASSWORD="$choice";
	fi

	read -rp "Red Hat Subscription Pool ID: ($RH_SUB_POOL_ID): " choice;
	if [ "$choice" != "" ] ; then
		export RH_SUB_POOL_ID="$choice";
	fi

	echo

fi

echo "******"
echo "* Your domain is $DOMAIN "
echo "* Your IP is $IP "
echo "* Your HOSTNAME is $HOSTNAME "
echo "* Your openshift username is $OCP_USERNAME "
echo "* Your openshift password is $OCP_PASSWORD "
echo "* OpenShift version: $VERSION "
echo "* Your redhat username is $RH_USERNAME "
echo "* Your redhat password is $RH_PASSWORD "
echo "* Your redhat subscription pool ID is $RH_SUB_POOL_ID "
echo "******"

read -n 1 -s -r -p "Press any key to continue..."
echo ""

subscription-manager register --username=$RH_USERNAME --password=$RH_PASSWORD
subscription-manager attach --pool=$RH_SUB_POOL_ID
subscription-manager repos --disable="*"
subscription-manager repos \
--enable="rhel-7-server-rpms" \
--enable="rhel-7-server-extras-rpms" \
--enable="rhel-7-server-ose-3.11-rpms" \
--enable="rhel-7-server-ansible-2.6-rpms"

yum -y update
yum -y install wget git net-tools bind-utils yum-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct atomic openshift-ansible docker-1.13.1

systemctl | grep "NetworkManager.*running"
if [ $? -eq 1 ]; then
	systemctl start NetworkManager
	systemctl enable NetworkManager
fi

[ ! -d openshift-ansible ] && git clone https://github.com/openshift/openshift-ansible.git

cd openshift-ansible && git fetch && git checkout release-${VERSION} && cd ..

cat <<EOD > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
${IP}		$(hostname) console console.${DOMAIN}
EOD

if [ -z $DISK ]; then
	echo "Not setting the Docker storage."
else
	cp /etc/sysconfig/docker-storage-setup /etc/sysconfig/docker-storage-setup.bk

	echo DEVS=$DISK > /etc/sysconfig/docker-storage-setup
	echo VG=DOCKER >> /etc/sysconfig/docker-storage-setup
	echo SETUP_LVM_THIN_POOL=yes >> /etc/sysconfig/docker-storage-setup
	echo DATA_SIZE="100%FREE" >> /etc/sysconfig/docker-storage-setup

	systemctl stop docker

	rm -rf /var/lib/docker
	wipefs --all $DISK
	docker-storage-setup
fi

systemctl restart docker
systemctl enable docker

if [ ! -f ~/.ssh/id_rsa ]; then
	ssh-keygen -q -f ~/.ssh/id_rsa -N ""
	cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
	ssh -o StrictHostKeyChecking=no root@$HOSTNAME "pwd" < /dev/null
fi

export METRICS="True"
export LOGGING="True"

memory=$(cat /proc/meminfo | grep MemTotal | sed "s/MemTotal:[ ]*\([0-9]*\) kB/\1/")

if [ "$memory" -lt "4194304" ]; then
	export METRICS="False"
fi

if [ "$memory" -lt "16777216" ]; then
	export LOGGING="False"
fi

curl -o inventory.download $SCRIPT_REPO/inventory.ini
envsubst < inventory.download > inventory.ini

# add proxy in inventory.ini if proxy variables are set
if [ ! -z "${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy}}}}" ]; then
	echo >> inventory.ini
	echo "openshift_http_proxy=\"${HTTP_PROXY:-${http_proxy:-${HTTPS_PROXY:-${https_proxy}}}}\"" >> inventory.ini
	echo "openshift_https_proxy=\"${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy}}}}\"" >> inventory.ini
	if [ ! -z "${NO_PROXY:-${no_proxy}}" ]; then
		__no_proxy="${NO_PROXY:-${no_proxy}},${IP},.${DOMAIN}"
	else
		__no_proxy="${IP},.${DOMAIN}"
	fi
	echo "openshift_no_proxy=\"${__no_proxy}\"" >> inventory.ini
fi

mkdir -p /etc/origin/master/
touch /etc/origin/master/htpasswd

ansible-playbook -i inventory.ini openshift-ansible/playbooks/prerequisites.yml
ansible-playbook -i inventory.ini openshift-ansible/playbooks/deploy_cluster.yml

htpasswd -b /etc/origin/master/htpasswd ${OCP_USERNAME} ${OCP_PASSWORD}
oc login -u system:admin
oc adm policy add-cluster-role-to-user cluster-admin ${USERNAME}

echo "******"
echo "* Your console is https://console.$DOMAIN:$API_PORT"
echo "* Your username is $OCP_USERNAME "
echo "* Your password is $OCP_PASSWORD "
echo "*"
echo "* Login using:"
echo "*"
echo "$ oc login -u ${OCP_USERNAME} -p ${OCP_PASSWORD} https://console.$DOMAIN:$API_PORT/"
echo "******"

oc login -u ${USERNAME} -p ${PASSWORD} https://console.$DOMAIN:$API_PORT/

echo ""
echo "***  END OF INSTALLATION! ***"
