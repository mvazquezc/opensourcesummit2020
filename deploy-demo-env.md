# Create a cluster with Kind

1. Create the kind cluster definition

    ~~~sh
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
    ~~~
2. Deploy the NGINX Ingress Controller

    ~~~sh
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml
    ~~~
3. Deploy Argo CD

    ~~~sh
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v1.6.1/manifests/install.yaml
    ~~~
4. Get the Argo CD admin user password

    ~~~sh
    ARGOCD_PASSWORD=$(kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | awk -F "/" '{print $2}')
    echo $ARGOCD_PASSWORD > ~/argocd-password
    ~~~
5. Patch the NGINX Ingress controller to support ssl-passthrough

    ~~~sh
    kubectl -n ingress-nginx patch deployment ingress-nginx-controller -p '{"spec":{"template":{"spec":{"$setElementOrder/containers":[{"name":"controller"}],"containers":[{"args":["/nginx-ingress-controller","--election-id=ingress-controller-leader","--ingress-class=nginx","--configmap=ingress-nginx/ingress-nginx-controller","--validating-webhook=:8443","--validating-webhook-certificate=/usr/local/certificates/cert","--validating-webhook-key=/usr/local/certificates/key","--publish-status-address=localhost","--enable-ssl-passthrough"],"name":"controller"}]}}}}'
    ~~~
6.  Create an ingress object for accessing Argo CD WebUI

    ~~~sh
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
    ~~~
7.  Deploy Tekton Pipelines and Tekton Triggers

    ~~~sh
    kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.12.1/release.yaml
    kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/previous/v0.5.0/release.yaml
    ~~~

# Create the required Tekton manifests

1. Clone the Git repositories (ssh keys are already in place)

    ~~~sh
    git clone git@github.com:mvazquezc/reverse-words.git ~/reverse-words
    git clone git@github.com:mvazquezc/reverse-words-cicd.git ~/reverse-words-cicd
    ~~~
2. Go to the reverse-words-cicd repo and checkout the CI branch which contains our Tekton manifests

    ~~~sh
    cd ~/reverse-words-cicd
    git checkout ci
    ~~~
3. Create a namespace for storing the configuration for our reversewords app pipeline

    ~~~sh
    kubectl create namespace tekton-reversewords
    ~~~
4. Add the quay credentials to the credentials file

    ~~~sh
    QUAY_USER=<your_user>
    read -s QUAY_PASSWORD
    sed -i "s/<username>/$QUAY_USER/" quay-credentials.yaml
    sed -i "s/<password>/$QUAY_PASSWORD/" quay-credentials.yaml
    ~~~
5. Create a Secret containing the credentials to access our Git repository
    
    ~~~sh
    read -s GIT_AUTH_TOKEN
    kubectl -n tekton-reversewords create secret generic image-updater-secret --from-literal=token=${GIT_AUTH_TOKEN}
    ~~~
6. Import credentials into the cluster

    ~~~sh
    kubectl -n tekton-reversewords create -f quay-credentials.yaml
    ~~~
7. Create a ServiceAccount with access to the credentials created in the previous step

    ~~~sh
    kubectl -n tekton-reversewords create -f pipeline-sa.yaml
    ~~~
8. Create the Linter Task which will lint our code

    ~~~sh
    kubectl -n tekton-reversewords create -f lint-task.yaml
    ~~~
9. Create the Tester Task which will run the tests in our app

    ~~~sh
    kubectl -n tekton-reversewords create -f test-task.yaml
    ~~~
10. Create the Builder Task which will build a container image for our app

    ~~~sh
    kubectl -n tekton-reversewords create -f build-task.yaml
    ~~~
11. Create the Image Update Task which will update the Deployment on a given branch after a successful image build

    ~~~sh
    kubectl -n tekton-reversewords create -f image-updater-task.yaml
    ~~~
12. Edit some parameters from our Build Pipeline definition

    ~~~sh
    sed -i "s|<reversewords_git_repo>|https://github.com/mvazquezc/reverse-words|" build-pipeline.yaml
    sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" build-pipeline.yaml
    sed -i "s|<golang_package>|github.com/mvazquezc/reverse-words|" build-pipeline.yaml
    sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" build-pipeline.yaml
    ~~~
13. Create the Build Pipeline definition which will be used to execute the previous tasks in an specific order with specific parameters

    ~~~sh
    kubectl -n tekton-reversewords create -f build-pipeline.yaml
    ~~~
14. Create the curl task which will be used to query our apps on the promoter pipeline

    ~~~sh
    kubectl -n tekton-reversewords create -f curl-task.yaml
    ~~~
15. Create the task that gets the stage release from the git cicd repository

    ~~~sh
    kubectl -n tekton-reversewords create -f get-stage-release-task.yaml
    ~~~
16. Edit some parameters from our Promoter Pipeline definition

    ~~~sh
    sed -i "s|<reversewords_cicd_git_repo>|https://github.com/mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
    sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" promote-to-prod-pipeline.yaml
    sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
    sed -i "s|<stage_deployment_file_path>|./deployment.yaml|" promote-to-prod-pipeline.yaml
    ~~~
17. Create the Promoter Pipeline definition which will be used to execute the previous tasks in an specific order with specific parameters

    ~~~sh
    kubectl -n tekton-reversewords create -f promote-to-prod-pipeline.yaml
    ~~~
18. Create the required Roles and RoleBindings for working with Webhooks

    ~~~sh
    kubectl -n tekton-reversewords create -f webhook-roles.yaml
    ~~~
19. Create the TriggerBinding for reading data received by a webhook and pass it to the Pipeline

    ~~~sh
    kubectl -n tekton-reversewords create -f github-triggerbinding.yaml
    ~~~
20. Create the TriggerTemplate and Event Listener to run the Pipeline when new commits hit the master branch of our app repository

    ~~~sh
    WEBHOOK_SECRET="v3r1s3cur3"
    kubectl -n tekton-reversewords create secret generic webhook-secret --from-literal=secret=${WEBHOOK_SECRET}
    sed -i "s/<git-triggerbinding>/github-triggerbinding/" webhook.yaml
    kubectl -n tekton-reversewords create -f webhook.yaml
    ~~~
21. We need to provide an ingress point for our EventListener, we want it to be TLS, so we need to generate some certs

    ~~~sh
    mkdir -p ~/tls-certs/
    cd $_
    openssl genrsa -out ~/tls-certs/tekton-events.key 2048
    openssl req -new -key ~/tls-certs/tekton-events.key -out ~/tls-certs/tekton-events.csr -subj "/C=US/ST=TX/L=Austin/O=RedHat/CN=tekton-events.oss20.kubelabs.org"
    ~~~
22. Send the CSR to the Kubernetes server to get it signed with the Kubernetes CA

    ~~~sh
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
    ~~~
23. Approve the CSR and save the cert into a file

    ~~~sh
    kubectl certificate approve tekton-events-tls
    kubectl get csr tekton-events-tls -o jsonpath='{.status.certificate}' | base64 -d > ~/tls-certs/tekton-events.crt
    ~~~
24. Create a secret with the TLS certificates

    ~~~sh
    cd ~/tls-certs/
    kubectl -n tekton-reversewords create secret generic tekton-events-tls --from-file=tls.crt=tekton-events.crt --from-file=tls.key=tekton-events.key
    ~~~
25. Configure a TLS ingress which uses the certs created

    ~~~sh
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
    ~~~

# Configure Argo CD

1. Install the Argo CD Cli to make things easier

    ~~~sh
    # Get the Argo CD Cli and place it in /usr/bin/
    sudo curl -L https://github.com/argoproj/argo-cd/releases/download/v1.6.1/argocd-linux-amd64 -o /usr/bin/argocd
    sudo chmod +x /usr/bin/argocd
    ~~~
2. Login into Argo CD from the Cli

    ~~~sh
    argocd login argocd.oss20.kubelabs.org --insecure --username admin --password $(cat ~/argocd-password)
    ~~~
3. Update Argo CD password

    ~~~sh
    argocd account update-password --account admin --current-password $(cat ~/argocd-password) --new-password 'r3dh4t1!'
    ~~~
