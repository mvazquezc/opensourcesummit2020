#!/bin/bash

echo -ne "Enter your quay.io username: "
read QUAY_USER
echo -ne "Enter your quay.io password: "
read -s QUAY_PASSWORD
echo -ne "\nEnter your Git Token: "
read -s GIT_AUTH_TOKEN

echo "Deploying Kind cluster"

CLUSTER_NAME="demo-cluster"
cat <<EOF | kind create cluster --name $CLUSTER_NAME --wait 200s --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
echo "Deploy NGINGX Ingress Controller"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml
echo "Patch Ingress Controller to support passthrough connections"
kubectl -n ingress-nginx patch deployment ingress-nginx-controller -p '{"spec":{"template":{"spec":{"$setElementOrder/containers":[{"name":"controller"}],"containers":[{"args":["/nginx-ingress-controller","--election-id=ingress-controller-leader","--ingress-class=nginx","--configmap=ingress-nginx/ingress-nginx-controller","--validating-webhook=:8443","--validating-webhook-certificate=/usr/local/certificates/cert","--validating-webhook-key=/usr/local/certificates/key","--publish-status-address=localhost","--enable-ssl-passthrough"],"name":"controller"}]}}}}'
kubectl wait --for=condition=available --timeout=600s deployment/ingress-nginx-controller -n ingress-nginx
echo "Deploy Argo CD"
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v1.6.1/manifests/install.yaml
sleep 5
echo -ne "Waiting for NGINX Controller to be ready"
until [[ $(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null) == "true" ]]; do echo -ne "."; sleep 5;done
echo "done"
echo "Create Ingress for Argo CD"
cat <<EOF | kubectl -n argocd apply -f -
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: argocd-server-ingress
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
spec:
  rules:
  - host: argocd.oss20.kubelabs.org
    http:
      paths:
      - backend:
          serviceName: argocd-server
          servicePort: https
EOF
ARGOCD_PASSWORD=$(kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | awk -F "/" '{print $2}')
echo "Deploy Tekton Pipelines, Events and Dashboard"
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.12.1/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/previous/v0.5.0/release.yaml
kubectl apply -f https://github.com/tektoncd/dashboard/releases/download/v0.7.1/tekton-dashboard-release.yaml
sleep 5
echo -ne "Waiting for Tekton Webhook Controller to be ready"
until [[ $(kubectl -n tekton-pipelines get pods -l app.kubernetes.io/component=webhook-controller -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null) == "true" ]]; do echo -ne "."; sleep 5;done
echo "done"
echo -ne "Waiting for Tekton Webhook to be ready"
until [[ $(kubectl -n tekton-pipelines get pods -l app.kubernetes.io/component=webhook -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null) == "true" ]]; do echo -ne "."; sleep 5;done
echo "done"
git clone git@github.com:mvazquezc/reverse-words.git ~/reverse-words
git clone git@github.com:mvazquezc/reverse-words-cicd.git ~/reverse-words-cicd
cd ~/reverse-words-cicd
git checkout ci
echo "Create Tekton resources for the demo"
kubectl create namespace tekton-reversewords
sed -i "s/<username>/$QUAY_USER/" quay-credentials.yaml
sed -i "s/<password>/$QUAY_PASSWORD/" quay-credentials.yaml
kubectl -n tekton-reversewords create secret generic image-updater-secret --from-literal=token=${GIT_AUTH_TOKEN}
kubectl -n tekton-reversewords create -f quay-credentials.yaml
kubectl -n tekton-reversewords create -f pipeline-sa.yaml
kubectl -n tekton-reversewords create -f lint-task.yaml
kubectl -n tekton-reversewords create -f test-task.yaml
kubectl -n tekton-reversewords create -f build-task.yaml
kubectl -n tekton-reversewords create -f image-updater-task.yaml
sed -i "s|<reversewords_git_repo>|https://github.com/mvazquezc/reverse-words|" build-pipeline.yaml
sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" build-pipeline.yaml
sed -i "s|<golang_package>|github.com/mvazquezc/reverse-words|" build-pipeline.yaml
sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" build-pipeline.yaml
kubectl -n tekton-reversewords create -f build-pipeline.yaml
kubectl -n tekton-reversewords create -f webhook-roles.yaml
kubectl -n tekton-reversewords create -f github-triggerbinding.yaml
WEBHOOK_SECRET="v3r1s3cur3"
kubectl -n tekton-reversewords create secret generic webhook-secret --from-literal=secret=${WEBHOOK_SECRET}
sed -i "s/<git-triggerbinding>/github-triggerbinding/" webhook.yaml
kubectl -n tekton-reversewords create -f webhook.yaml
kubectl -n tekton-reversewords create -f curl-task.yaml
kubectl -n tekton-reversewords create -f get-stage-release-task.yaml
sed -i "s|<reversewords_cicd_git_repo>|https://github.com/mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" promote-to-prod-pipeline.yaml
sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
sed -i "s|<stage_deployment_file_path>|./deployment.yaml|" promote-to-prod-pipeline.yaml
kubectl -n tekton-reversewords create -f promote-to-prod-pipeline.yaml
mkdir -p ~/tls-certs/
cd ~/tls-certs/
openssl genrsa -out ~/tls-certs/tekton-events.key 2048
openssl req -new -key ~/tls-certs/tekton-events.key -out ~/tls-certs/tekton-events.csr -subj "/C=US/ST=TX/L=Austin/O=RedHat/CN=tekton-events.oss20.kubelabs.org"
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: tekton-events-tls
spec:
  request: $(cat ~/tls-certs/tekton-events.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF
kubectl certificate approve tekton-events-tls
kubectl get csr tekton-events-tls -o jsonpath='{.status.certificate}' | base64 -d > ~/tls-certs/tekton-events.crt
kubectl -n tekton-reversewords create secret generic tekton-events-tls --from-file=tls.crt=tekton-events.crt --from-file=tls.key=tekton-events.key
until [[ $(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.containerStatuses[0].ready}') == "true" ]]; do echo "Waiting for nginx controller to be ready"; sleep 2;done
cat <<EOF | kubectl -n tekton-reversewords create -f -
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: github-webhook-eventlistener
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  tls:
    - hosts:
      - tekton-events.oss20.kubelabs.org
      secretName: tekton-events-tls
  rules:
  - host: tekton-events.oss20.kubelabs.org
    http:
      paths:
      - backend:
          serviceName: el-reversewords-webhook
          servicePort: 8080
EOF
openssl genrsa -out ~/tls-certs/tekton-dashboard.key 2048
openssl req -new -key ~/tls-certs/tekton-dashboard.key -out ~/tls-certs/tekton-dashboard.csr -subj "/C=US/ST=TX/L=Austin/O=RedHat/CN=tekton-dashboard.octo.eng.rdu2.redhat.com"
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: tekton-dashboard-tls
spec:
  request: $(cat ~/tls-certs/tekton-dashboard.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF
ubectl certificate approve tekton-dashboard-tls
kubectl get csr tekton-dashboard-tls -o jsonpath='{.status.certificate}' | base64 -d > ~/tls-certs/tekton-dashboard.crt
kubectl -n tekton-pipelines create secret generic tekton-dashboard-tls --from-file=tls.crt=tekton-dashboard.crt --from-file=tls.key=tekton-dashboard.key
cat <<EOF | kubectl -n tekton-pipelines create -f -
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: tekton-dashboard
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  tls:
    - hosts:
      - tekton-dashboard.oss20.kubelabs.org
      secretName: tekton-dashboard-tls
  rules:
  - host: tekton-dashboard.oss20.kubelabs.org
    http:
      paths:
      - backend:
          serviceName: tekton-dashboard
          servicePort: 9097
EOF
argocd login argocd.oss20.kubelabs.org --insecure --username admin --password $ARGOCD_PASSWORD
argocd account update-password --account admin --current-password $ARGOCD_PASSWORD --new-password 'r3dh4t1!'
