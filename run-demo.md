# Demo Workflows

## Build Workflow

![Build Workflow](./assets/BuildWorkflow.png)

## Image Promotion Workflow

![Promotion Workflow](./assets/PromoteWorkflow.png)

# Argo CD

## Configuring the Argo CD Apps

1. Add the Git repository for our application to Argo CD

    ~~~sh
    argocd repo add https://github.com/mvazquezc/reverse-words-cicd.git --name reversewords-cicd
    ~~~
2. Edit the ingresses for our applications before creating them in Argo CD

    ~~~sh
    cd ~/reverse-words-cicd
    # Stash previous changes
    git stash
    # Update staging ingress  
    git checkout stage
    sed -i "s/host: .*/host: reversewords-dev.oss20.kubelabs.org/" ingress.yaml
    # Push stage changes
    git commit -am "Added ingress hostname"
    git push origin stage
    # Update production ingress
    git checkout prod
    sed -i "s/host: .*/host: reversewords-prod.oss20.kubelabs.org/" ingress.yaml
    # Push prod changes
    git commit -am "Added ingress hostname"
    git push origin prod
    ~~~
3. Define Development application

    ~~~sh
    argocd app create --project default --name reverse-words-stage \
    --repo https://github.com/mvazquezc/reverse-words-cicd.git \
    --path . \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace reverse-words-stage --revision stage \
    --self-heal --sync-policy automated
    ~~~
4. Define Production application

    ~~~sh
    argocd app create --project default --name reverse-words-production \
    --repo https://github.com/mvazquezc/reverse-words-cicd.git \
    --path . \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace reverse-words-production --revision prod \
    --self-heal --sync-policy automated
    ~~~
5. At this point the applications will be deployed automatically and Argo CD will poll the Git repository in order to detect configuration drifts every 3 minutes, when that happens, Argo CD will automatically apply the config stored in Git

## Triggering the Build Pipeline using the WebHook

We are going to use WebHooks in order to run Pipelines automatically when new commits hit the branches of our app and cicd repositories.

* Our first webhook will receive events from the application repository, when new code hits the master branch we will trigger the build pipeline.
* Our second webhook will receive events from the cicd repository, when new code hits `stage` or `prod` branches we will trigger a new deployment using Argo CD.

1. We will configure the first webhook on the app repo

    > **NOTE**: Every Git server has its own properties, but basically you want to provide the ingress url for our webhook and when the Git server should send the hook. E.g: push events, PR events, etc.

    1. Go to your application repository on GitHub, eg: https://github.com/mvazquezc/reverse-words
    2. Click on `Settings` -> `Webhooks`
    3. Create the following `Hook`
       1. `Payload URL`: https://tekton-events.oss20.kubelabs.org
       2. `Content type`: application/json
       2. `Secret`: v3r1s3cur3
       3. `Events`: Check **Push Events**, leave others blank
       4. `Active`: Check it
       5. `SSL verification`: Check  **Disable**
       6. Click on `Add webhook`
2. Now, we will configure the second webhook to react to changes on the cicd repository

    > **NOTE**: Argo CD comes with Webhooks enabled by default, that means that we just need to use the following url as Webhook endpoint, `https://<argocd-ingress-url>/api/webhook`

    1. Go to your cicd repository on GitHub, eg: https://github.com/mvazquezc/reverse-words-cicd
    2. Click on `Settings` -> `Webhooks`
    3. Create the following `Hook`
       1. `Payload URL`: https://argocd.oss20.kubelabs.org/api/webhook
       2. `Content type`: application/json
       2. `Secret`: v3r1s3cur3
       3. `Events`: Check **Push Events**, leave others blank
       4. `Active`: Check it
       5. `SSL verification`: Check  **Disable**
       6. Click on `Add webhook`
    4. We need to configure our `Secret Token` on Argo CD
        ~~~sh
        WEBHOOK_SECRET="v3r1s3cur3"
        kubectl -n argocd patch secret argocd-secret -p "{\"data\":{\"webhook.github.secret\":\"$(echo -n $WEBHOOK_SECRET | base64)\"}}" --type=merge
        ~~~
3. Now we should have a working Webhook, let's test it

    1. Deploy tkn cli
        
        ~~~sh
        sudo curl -L https://github.com/tektoncd/cli/releases/download/v0.10.0/tkn_0.10.0_Linux_x86_64.tar.gz | tar xz tkn 
        chown root: tkn && mv tkn /usr/bin/
        ~~~
    2. We need to commit to the master branch, let's update the release number
     
        ~~~sh
        cd ~/reverse-words/
        CURRENT_RELEASE=$(grep "var version" main.go  | awk -F '"' '{print $2}' | awk -F "." 'BEGIN{FS=OFS="."}{NF--; print}')
        NEW_MINOR=$(grep "var version" main.go  | awk -F '"' '{print $2}' | awk -F "." '{print $NF+1}')
        NEW_RELEASE="${CURRENT_RELEASE}.${NEW_MINOR}"
        sed -i "s|var version = .*|var version = \"${NEW_RELEASE}\"|" main.go
        git diff main.go
        git add main.go
        git commit -m "Release updated to $NEW_RELEASE"
        git push origin master
        ~~~
    3. A new PipelineRun will be fired
        
        ~~~sh
        tkn -n tekton-reversewords pipeline list
        
        NAME                           AGE          LAST RUN                                STARTED          DURATION   STATUS
        reverse-words-build-pipeline   1 hour ago   reversewords-build-pipeline-run-wmzrn   22 seconds ago   ---        Running
        ~~~
    4. We can check the running images for our application pod and see that when the pipeline finishes a new deployment is triggered on ArgoCD
    5. When the Build pipeline finishes we can promote the new build to production

        ~~~sh
        tkn -n tekton-reversewords pipeline start reverse-words-promote-pipeline -r app-git=reverse-words-cicd-git -p pathToDeploymentFile=./deployment.yaml -p stageBranch=stage -p stageAppUrl=http://reversewords-dev.oss20.kubelabs.org
        ~~~

## Sealed Secrets

Most of the time, our applications require Secrets to work properly, pushing Kubernetes secrets to a Git repository is not the way to go, as you probably know, Kubernetes secrets are encoded and not encrypted.

In order to solve this problem we are going to use Sealed Secrets, there are other alternatives out there like Vault secrets, the idea is uploading encrypted secrets to Git so they cannot be read by non-allowed users.

1. Download the Sealed Secrets Cli tool

    ~~~sh
    # Get the KubeSeal Cli and place it in /usr/bin/
    sudo curl -L https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.12.4/kubeseal-linux-amd64 -o /usr/bin/kubeseal
    sudo chmod +x /usr/bin/kubeseal
    ~~~
2. Deploy the KubeSeal Controller into the cluster

    ~~~sh
    kubectl -n kube-system apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.12.4/controller.yaml
    ~~~
3. Create a test secret

    ~~~sh
    cd ~/reverse-words-cicd
    # Stash previous changes
    git stash
    # Update staging ingress
    git checkout stage
    # Get updates
    git pull origin stage
    # Create the secret on a yaml file
    kubectl -n reverse-words-stage create secret generic my-test-secret --from-literal=username=admin --from-literal=password=v3r1s3cur3 --dry-run=client -o yaml > /tmp/test-secret.yaml
    ~~~
4. Seal the test secret

    ~~~sh
    kubeseal -o yaml < /tmp/test-secret.yaml > test-secret-sealed.yaml
    ~~~
5. Update the Kustomization and push the sealed secret to the git repository

    ~~~sh
    sed -i "s|patchesStrategicMerge:|- test-secret-sealed.yaml\npatchesStrategicMerge:|" kustomization.yaml
    git add kustomization.yaml test-secret-sealed.yaml
    git commit -m "Add Sealed Secret"
    git push origin stage
    ~~~
