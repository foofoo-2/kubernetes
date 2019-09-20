#!/bin/bash

# Initialize Kubernetes
echo "[TASK 1] Initialize Kubernetes Cluster"
kubeadm init --apiserver-advertise-address=172.42.42.100 --pod-network-cidr=10.244.0.0/16 >> /root/kubeinit.log 2>/dev/null

# Copy Kube admin config
echo "[TASK 2] Copy kube admin config to Vagrant user .kube directory"
mkdir /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# Deploy flannel network
echo "[TASK 3] Deploy flannel network"
su - vagrant -c "kubectl create -f /vagrant/kube-flannel.yml"

# Generate Cluster join command
echo "[TASK 4] Generate and save cluster join command to /joincluster.sh"
kubeadm token create --print-join-command > /joincluster.sh

# Deploy Helm
echo "[TASK 5] Deploy Helm"
su - vagrant -c \
  "curl -s https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash"
su - vagrant -c \
  "kubectl create serviceaccount -n kube-system tiller"
su - vagrant -c \
  "kubectl create clusterrolebinding tiller-binding --clusterrole=cluster-admin --serviceaccount kube-system:tiller"
# https://github.com/helm/helm/issues/6374
su - vagrant -c \
  "helm init --service-account tiller --client-only"
su - vagrant -c \
  "helm init --service-account tiller --output yaml |
     sed 's@apiVersion: extensions/v1beta1@apiVersion: apps/v1@' |
     sed 's@  replicas: 1@  replicas: 1\n  selector: {"matchLabels": {"app": "helm", "name": "tiller"}}@' |
     kubectl apply -f -"

# Setup NFS server
echo "[TASK 6] Setup NFS server"
yum -y install nfs-utils >/dev/null
mkdir -p /nfs
chown nfsnobody:nfsnobody /nfs
chmod 755 /nfs
echo '/nfs    *(rw,sync,no_root_squash,no_subtree_check)' >/etc/exports.d/kubernetes.exports
exportfs -a
systemctl start nfs-server.service && systemctl enable nfs-server.service 2>/dev/null

# Setup NFS client provisioner and MetalLB
echo "[TASK 7] Setup NFS client provisioner and MetalLB"
cat >/tmp/setup-nfs-client-provisioner-and-metallb.sh <<'EOF'
#!/bin/bash

sleep 10

mkdir -p /root/.kube
cp -a /home/vagrant/.kube/config /root/.kube/config

# Wait for tiller to be ready
while [[ $(kubectl get pods -n kube-system -l name=tiller -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
  sleep 10
done

# Install nfs-client-provisioner
su - vagrant -c "helm install stable/nfs-client-provisioner \
  --set nfs.server=172.42.42.100 \
  --set nfs.path=/nfs \
  --name nfs-client"

# Install MetalLB
su - vagrant -c "helm install --name metallb stable/metallb"
su - vagrant -c "kubectl create -f /vagrant/metallb-configmap.yml"

rm -rf /root/.kube /tmp/setup-nfs-client-provisioner-and-metallb.sh
EOF

chmod +x /tmp/setup-nfs-client-provisioner-and-metallb.sh
nohup /tmp/setup-nfs-client-provisioner-and-metallb.sh &
