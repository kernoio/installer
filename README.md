# Kerno installation tools
The code is provided as-is with no warranties.

## Pre-requisites
You will need access and adequate permissions to the target AWS account and EKS cluster to create and configure EFS storage and install Kerno's cluster-side agent and aggregators.


## Let's get to it!
### On Linux
You will need a few tools in your Linux box.
```console
$ sudo apt install jq sed grep git
```

You will also need your usual cloud management tools: [aws-cli v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), [kubectl](https://kubernetes.io/docs/tasks/tools/) and [helm](https://helm.sh/docs/intro/install/).

#### Ready to go?
Awesome
```console
$ git clone --depth 1 git@github.com:kernoio/installer kerno-installer
$ cd kerno-installer
$ ./bin/aws.sh install   \
  --profile $AWS_PROFILE \
  --region  $AWS_REGION  \
  --cluster $EKS_CLUSTER \
  --k4-key  $K4_KEY      \    
  --k8s-context $K8S_CONTEXT_NAME
```


### Wait, what are you doing?
Well you can check the scripts and helm logic itself, but this is what's going on:
- discover the target cluster configuration
- setup network storage for your traces
- configure the storage to ensure access from the cluster
- install kerno aggregators and DaemonSet in the `kerno` namespace