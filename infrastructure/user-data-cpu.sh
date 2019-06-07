#!/bin/bash

apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository \
   "deb https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
   $(lsb_release -cs) \
   stable"
apt-get update && apt-get install -y --allow-downgrades docker-ce=$(apt-cache madison docker-ce | grep 18.09 | head -1 | awk '{print $3}')


# Note:  If we use this, we need to modify `docker.service`
#        or create `/etc/systemd/docker.service.d/docker.root.conf`
#        See https://github.com/IronicBadger/til/blob/master/docker/change-docker-root.md for more details
cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

mkdir -p /mnt/pipelineai
# mount -o discard,defaults /dev/sdb /mnt/pipelineai
# echo UUID=`sudo blkid -s UUID -o value /dev/sdb` /mnt/pipelineai ext4 discard,defaults,nofail 0 2 | sudo tee -a /etc/fstab

mkdir -p /etc/systemd/system/docker.service.d/
cat > /etc/systemd/system/docker.service.d/docker.root.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -g /mnt/pipelineai -H fd://
EOF

# Verify that Docker Root Dir is /mnt/pipelineai
systemctl daemon-reload
systemctl restart docker
docker info

# Latest git
add-apt-repository ppa:git-core/ppa
apt-get update
apt-get install -y git

# Pin normal pip and pip3 to 10.0.1
pip install pip==10.0.1 --ignore-installed --no-cache --upgrade
pip3 install pip==10.0.1 --ignore-installed --no-cache --upgrade

# Pin Miniconda3 to 4.5.1 and pip to 10.0.1
wget -q https://repo.continuum.io/miniconda/Miniconda3-4.5.1-Linux-x86_64.sh -O /tmp/miniconda.sh && \
    bash /tmp/miniconda.sh -f -b -p /opt/conda && \
    /opt/conda/bin/conda install --yes python=3.6 pip=10.0.1 && \
    rm /tmp/miniconda.sh
export PATH=/opt/conda/bin:$PATH
echo "export PATH=/opt/conda/bin:$PATH" >> /root/.bashrc
echo "export PATH=/opt/conda/bin:$PATH" >> /etc/environment

export HOME=/root

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get remove -y --allow-change-held-packages kubelet kubeadm kubectl
apt-get install -y kubelet=1.14.2-00 kubeadm=1.14.2-00 kubectl=1.14.2-00
#apt-mark hold kubelet kubeadm kubectl
apt autoremove

mkdir -p /mnt/pipelineai/kubelet

#kubeadm reset --force
#iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X

# PipelineAI CLI
# NOTE:  WE NEED TO KEEP THIS UP HERE SINCE WE USE `pipeline` NEXT
export PIPELINE_CLI_VERSION=1.5.325
pip install cli-pipeline==$PIPELINE_CLI_VERSION --ignore-installed --no-cache --upgrade

# PipelineAI Runtime
export PIPELINE_VERSION=1.5.0
echo "export PIPELINE_VERSION=$PIPELINE_VERSION" >> /root/.bashrc
echo "export PIPELINE_VERSION=$PIPELINE_VERSION" >> /etc/environment

# Note:  we need to do a dry-run to generate the /root/.pipelineai/cluster/yaml/ and /root/.pipelineai/kube/
pipeline cluster-kube-install --tag $PIPELINE_VERSION --chip=cpu --namespace=default --image-registry-url=gcr.io/pipelineai2 --users-storage-gb=50Gi --ingress-type=nodeport --users-root-path=/mnt/pipelineai/users --dry-run

#cp /root/.pipelineai/kube/10-kubeadm.conf /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
sed -i '0,/\[Service\]/a Environment="KUBELET_EXTRA_ARGS=--root-dir=/mnt/pipelineai/kubelet --feature-gates=DevicePlugins=true,BlockVolume=true"' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

systemctl daemon-reload
systemctl restart kubelet

kubeadm init --config=/root/.pipelineai/cluster/config/kubeadm-init.yaml

mkdir -p $HOME/.kube
cp --force /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

export KUBECONFIG=/root/.kube/config
echo "export KUBECONFIG=/root/.kube/config" >> /root/.bashrc
echo "export KUBECONFIG=/root/.kube/config" >> /etc/environment

# Setup Networking
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"

# Allow the master to host pods
kubectl taint nodes --all node-role.kubernetes.io/master-

sleep 5

# OpenEBS CRD/Operator and StorageClass
kubectl create -f https://openebs.github.io/charts/openebs-operator-0.9.0.yaml

sleep 5

kubectl delete -f /root/.pipelineai/cluster/yaml/.generated-openebs-storageclass.yaml
kubectl create -f /root/.pipelineai/cluster/yaml/.generated-openebs-storageclass.yaml

# Tab Completion
echo "source <(kubectl completion bash)" >> ~/.bashrc
source ~/.bashrc

# Set Default Namespace
kubectl config set-context \
    $(kubectl config current-context) \
    --namespace default

# Install AWS CLI
pip install awscli
aws ecr get-login --region=us-west-2 --no-include-email | bash

# Install GCP gcloud
CLOUD_SDK_REPO="cloud-sdk-$(grep VERSION_CODENAME /etc/os-release | cut -d '=' -f 2)"
echo "deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
apt-get update && apt-get install -y google-cloud-sdk

# Install APIs for TPUs (Optional)
pip install --upgrade google-api-python-client
pip install --upgrade oauth2client

kubectl create secret generic docker-registry-secret --from-file=.dockerconfigjson=/root/.docker/config.json --type=kubernetes.io/dockerconfigjson

kubectl get pods --all-namespaces
kubectl get secrets --all-namespaces

export KSONNET_VERSION=0.13.1
echo "export KSONNET_VERSION=$KSONNET_VERSION" >> /root/.bashrc
echo "export KSONNET_VERSION=$KSONNET_VERSION" >> /etc/environment
wget https://github.com/ksonnet/ksonnet/releases/download/v${KSONNET_VERSION}/ks_${KSONNET_VERSION}_linux_amd64.tar.gz
tar -xzvf ks_${KSONNET_VERSION}_linux_amd64.tar.gz
mv ks_${KSONNET_VERSION}_linux_amd64/ks /usr/bin/

export KFCTL_VERSION=0.5.1
echo "export KSONNET_VERSION=$KFCTL_VERSION" >> /root/.bashrc
echo "export KSONNET_VERSION=$KFCTL_VERSION" >> /etc/environment
wget https://github.com/kubeflow/kubeflow/releases/download/v${KFCTL_VERSION}/kfctl_v${KFCTL_VERSION}_linux.tar.gz
tar -xzvf kfctl_v${KFCTL_VERSION}_linux.tar.gz
mv kfctl /usr/bin/

apt install -y jq
export KF_PIPELINES_VERSION=$(curl --silent https://api.github.com/repos/kubeflow/pipelines/releases/latest | jq -r .tag_name)
echo "export KF_PIPELINES_VERSION=$KF_PIPELINES_VERSION" >> /root/.bashrc
echo "export KF_PIPELINES_VERSION=$KF_PIPELINES_VERSION" >> /etc/environment
pip install https://storage.googleapis.com/ml-pipeline/release/${KF_PIPELINES_VERSION}/kfp.tar.gz --upgrade --no-cache --ignore-installed

pipeline cluster-kube-install --tag $PIPELINE_VERSION --chip=cpu --namespace=default --image-registry-url=gcr.io/pipelineai2 --users-storage-gb=50Gi --ingress-type=nodeport --users-root-path=/mnt/pipelineai/users

# Create
cd /root/kubeflow-tfx-workshop/install-kubeflow/
kfctl apply all -V

# Create.orig
#export KFAPP=install-kubeflow
#echo "export KFAPP=$KFAPP" >> /root/.bashrc
#echo "export KFAPP=$KFAPP" >> /etc/environment
# Default uses IAP.
#kfctl init --namespace=default --use_istio=true ${KFAPP}
#cd ${KFAPP}
#kfctl generate all -V
#kfctl apply all -V

# Delete
#cd /root/kubeflow-tfx-workshop/install-kubeflow/ks_app
#ks delete default

# Delete.orig
#cd ${KFAPP}
#kfctl delete all
#kfctl delete all --delete_storage
