#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DEPS_OK=`which aws sed jq grep kubectl | wc -l`
if [[  $DEPS_OK != 5 ]]; then
  echo $0 requires aws-cli v2, sed, jq, grep, getopt and kubectl.
  echo Please install these dependencies first.
  exit
fi

COMMAND=$1
K4_KEY=""
K8S_CONTEXT=""
CLUSTER=""
AWS_ARGS=""

# evaluate command line options   -o n:p:r:c:
VALID_ARGS=$(getopt --long k8s-context:,k4-key:,profile:,region:,cluster: -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1;
fi

# echo $VALID_ARGS
eval set -- "$VALID_ARGS"
while [ : ]; do
  # echo Evaluating $1 $2
  case "$1" in
    --profile)
        AWS_ARGS="$AWS_ARGS --profile $2"
        shift 2
        continue
        ;;
    --region)
        AWS_ARGS="$AWS_ARGS --region $2"
        shift 2
        continue
        ;;
    --cluster)
        CLUSTER="$2"
        shift 2
        continue
        ;;
    --k8s-context)
        K8S_CONTEXT="$2"
        shift 2
        continue
        ;;
    --k4-key)
        K4_KEY="$2"
        shift 2
        continue
        ;;
    --) shift;
        break 
        ;;
  esac
done

 
prepare() {
  echo "🔑 Identifying AWS account thorugh STS ..."
  AWS_ACCOUNT=`aws $AWS_ARGS sts get-caller-identity --query "Account" --output text`

  echo "⚙️  Identifying cluster configuration ..."
  EKS_DESCRIBE=`aws $AWS_ARGS eks describe-cluster --name $CLUSTER`
  EKS_VERSION=`echo $EKS_DESCRIBE | jq -er '.cluster.version'`
  EKS_VPC_ID=`echo $EKS_DESCRIBE | jq -er '.cluster.resourcesVpcConfig.vpcId'`
  EKS_OIDC_ID=`echo $EKS_DESCRIBE | jq -er '.cluster.identity.oidc.issuer' | sed 's/https:\/\///'`
  EKS_VPC_CIDR_RANGE=`aws $AWS_ARGS ec2 describe-vpcs --vpc-ids $EKS_VPC_ID --query "Vpcs[].CidrBlock" --output text`
  EKS_VPC_SUBNETS=(`echo $EKS_DESCRIBE | jq -er '.cluster.resourcesVpcConfig.subnetIds[]'`)
}

install_oidc_stack() {
  OIDC_ARN="arn:aws:iam::$AWS_ACCOUNT:oidc-provider/$EKS_OIDC_ID"
  OIDC_EXISTING=`aws --profile kernosso-avatar --region eu-west-1 iam  list-open-id-connect-providers | jq -er ".OpenIDConnectProviderList[] | select (.Arn == \"$OIDC_ARN\") | .Arn"`

  if [[ -z "$OIDC_EXISTING" ]]; then
    echo "🔒 Preparing OIDC provider for your cluster ... this can take a few minutes ..."
    OUT=`aws $AWS_ARGS cloudformation delete-stack --stack-name ${CLUSTER}-oidc `
    OUT=`aws $AWS_ARGS cloudformation create-stack  \
      --capabilities CAPABILITY_NAMED_IAM \
      --stack-name ${CLUSTER}-oidc \
      --parameters ParameterKey=ClusterName,ParameterValue=${CLUSTER} \
      --template-body file://$SCRIPT_DIR/oidc-provider.yaml `

    OUT=`aws $AWS_ARGS cloudformation wait stack-create-complete --stack-name ${CLUSTER}-oidc`;
  fi
  echo "🔒 OIDC provider for your cluster located."
}

install_driver() {
  echo "👀 Looking for aws-efs-csi-driver addon for API $EKS_VERSION ..."
  EFS_ROLE_NAME=KernoEKS_EFS_CSI_DriverRole
  EKS_EFS_ADDON=`aws $AWS_ARGS eks describe-addon-versions --kubernetes-version $EKS_VERSION | jq -er '.addons[].addonName' | grep aws-efs-csi-driver`
  if [[ -z "$EKS_EFS_ADDON" ]]; then
    echo "💔 No compatible aws-efs-csi-driver addon was found for EKS $EKS_VERSION"
    exit;
  fi

  ALREADY_DRIVER=`aws $AWS_ARGS eks list-addons --cluster-name $CLUSTER --query "addons" --output text | grep aws-efs-csi-driver`
  if [[ $ALREADY_DRIVER == "aws-efs-csi-driver" ]]; then
    echo "🚀 aws-efs-csi-driver addon is already installed in your cluster."
    return
  fi

  while true; do
      read -p "❓ Do you wish to configure the aws-efs-csi driver? [y/n] " yn
      case $yn in
          [Nn]* ) exit;;
          [Yy]* ) break;;
          * ) echo "Please answer yes or no.";;
      esac
  done

  install_driver_policies ;
}

install_driver_policies() {

  cat > /tmp/kerno-efs-csi-driver-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$AWS_ACCOUNT:oidc-provider/$EKS_OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "$EKS_OIDC_ID:sub": "system:serviceaccount:kube-system:efs-csi-*",
          "$EKS_OIDC_ID:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}

EOF

  echo "⚙️  Creating role for EKS EFS CSI driver ..."
  aws $AWS_ARGS iam create-role \
    --role-name $EFS_ROLE_NAME \
    --assume-role-policy-document "file:///tmp/kerno-efs-csi-driver-trust-policy.json"
    

  echo "⚙️  Attaching AmazonEFSCSIDriverPolicy to role ..."
  aws $AWS_ARGS iam attach-role-policy \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
    --role-name $EFS_ROLE_NAME  \
    > /dev/null
    

  aws $AWS_ARGS eks create-addon --cluster-name $CLUSTER \
      --addon-name $EKS_EFS_ADDON \
      --service-account-role-arn arn:aws:iam::$AWS_ACCOUNT:role/$EFS_ROLE_NAME \
      > /dev/null

  EFS_SECURITY_GROUP_ID=`aws $AWS_ARGS ec2 create-security-group  \
      --group-name EksEfsSecurityGroup \
      --description "EFS access from EKS" \
      --vpc-id $EKS_VPC_ID \
      --output text
      `
  
  if [[ -z "$EFS_SECURITY_GROUP_ID" ]]; then
    EFS_SECURITY_GROUP_ID=`aws $AWS_ARGS ec2 describe-security-groups \
        | jq -er '.SecurityGroups[] | select(.GroupName == "EksEfsSecurityGroup") | .GroupId '
        `
  fi

  aws $AWS_ARGS ec2 authorize-security-group-ingress \
      --group-id $EFS_SECURITY_GROUP_ID \
      --protocol tcp \
      --port 2049 \
      --cidr $EKS_VPC_CIDR_RANGE \
      > /dev/null
      
}


create_efs_volume() {
  EFS_NAME="$CLUSTER-kerno-efs"
  echo "🖴  Creating EFS file-system $EFS_NAME accessible by $CLUSTER ..."
  EFS_DESCRIBE=`aws $AWS_ARGS efs describe-file-systems`
  EFS_FS_ID=`echo $EFS_DESCRIBE| jq -er ".FileSystems[] | select (.Tags[].Key == \"Name\" and .Tags[].Value == \"$EFS_NAME\") | .FileSystemId"`
  
  if [[ -z "$EFS_FS_ID" ]]; then
    echo "🖴  Filesystem \"$EFS_NAME\" for cluster $CLUSTER ..."
    EFS_FS_ID=`aws $AWS_ARGS efs create-file-system \
      --tags "Key=Name,Value=$EFS_NAME" \
      --performance-mode generalPurpose \
      --encrypted \
      --query 'FileSystemId' \
      --output text
      `
  else
    echo "🖴 Using existing filesystem \"$EFS_NAME\"."
  fi

  EFS_STATE="unknown"
  while [[ "$EFS_STATE" != "available" ]]; do 
    echo "⏲️  Waiting for file system to become available... currently: $EFS_STATE "
    EFS_STATE=`aws $AWS_ARGS efs describe-file-systems --file-system-id $EFS_FS_ID | jq -er '.FileSystems[0].LifeCycleState'` ;
  done ;

  EFS_MOUNT_TARGETS=`aws $AWS_ARGS efs describe-mount-targets --file-system-id $EFS_FS_ID `
  
  for SUB_ID in "${EKS_VPC_SUBNETS[@]}"
  do
    EFS_MT_FOUND=`echo $EFS_MOUNT_TARGETS | jq -er ".MountTargets[] | select(.SubnetId == \"$SUB_ID\") | .MountTargetId"`

    if [[ -z "$EFS_MT_FOUND" ]]; then
      echo "🖴  Configuring access point for subnet $SUB_ID ..."
      OUT=`aws $AWS_ARGS efs create-mount-target \
        --file-system-id $EFS_FS_ID \
        --subnet-id $SUB_ID \
        --security-groups $EFS_SECURITY_GROUP_ID \
        2> /dev/null`
    else
      echo "🖴  Access point for subnet $SUB_ID already exists."
    fi
  done
}

run_helm() {
  echo "🚀 Installing Kerno via Helm ..."
  helm install --replace kerno ./helm   \
    --kube-context $K8s_CONTEXT                                    \
    --set global.fsId="$EFS_FS_ID"                                 \
    --set apiKey="$K4_KEY"                                 \
    -f ./helm/values-prod.yaml
  echo "All done."
}


install() {
  if [[ -z "$CLUSTER" ]]; then
    echo "$0: --cluster <eks-cluster-name> is required"
    help
    exit
  fi
  if [[ -z "$AWS_ARGS" ]]; then
    echo "$0: --profile and --region are required"
    echo ""
    help
    exit
  fi
  if [[ -z "$K4_KEY" ]]; then
    echo "$0: --k4-key <installation-key> is required"
    help
    exit
  fi
  if [[ -z "$K8S_CONTEXT" ]]; then
    echo "$0: --k8s-context <kubectl-context> is required"
    help
    exit
  fi

  clear
  echo "----------------------------------------------------------------------------" 
  echo "✨ Kerno @ EKS - https://www.kerno.io"
  echo "🚀 Preparing AWS EKS installation... it should take less than a minute."
  echo "----------------------------------------------------------------------------"
  echo

  prepare
  install_oidc_stack
  install_driver
  create_efs_volume
  run_helm
}


help() {
  echo "Usage: $0 [command] [options]"
  echo "  Commands:"
  echo "    help       - shows this help"
  echo "    install    - configures EFS in your EKS cluster"
  echo ""
  echo "  Options:"
  echo "    --profile       required <aws-profile>"
  echo "    --region        required <aws-region>"
  echo "    --cluster       required <eks-cluster-name>"
  echo "    --k8s-context   required <kubectl-context>"
  echo "    --k4-key        required <kerno-installation-key>"
  exit
}


if [[ -z "$COMMAND" ]]; then
  help;
  exit;
fi

case $COMMAND in
  help ) help ;;
  install ) install ;;
  * ) help ;;
esac
