#!/bin/bash

# get the absolute path of the executable
SELF_PATH=$(cd -P -- "$(dirname -- "$0")" && pwd -P) && SELF_PATH=$SELF_PATH/$(basename -- "$0")
while [ -h $SELF_PATH ]; do
	DIR=$(dirname -- "$SELF_PATH")
	SYM=$(readlink $SELF_PATH)
	SELF_PATH=$(cd $DIR && cd $(dirname -- "$SYM") && pwd)/$(basename -- "$SYM")
done
D=$(dirname $SELF_PATH)
pushd $D

if [ $# -lt 3 ]; then
  echo "Wrong parameters"
  echo "$0 <machine> <keyfile> <aminame> <region> <bucket> <oldami> <var_expansion:0>"
fi

machine=$1
keyfile=$2
aminame=$3
region=${4}
bucket=${5}
oldami=${6}
var_expansion=${7:-0}
f=$(date +"builder%Y%m%d%H%M")

#rm -rf files
mkdir -p .out
cp centos7-ami-builder.sh .out/
cp -a seed .out/

rm .out/centos-ami-builder
echo "BUILD_ROOT=/root/amis" >> .out/centos-ami-builder
echo "AMI_SIZE=8000" >> .out/centos-ami-builder
echo "AWS_USER=${AWS_USER}" >> .out/centos-ami-builder
echo "S3_ROOT=${bucket}" >> .out/centos-ami-builder
echo "S3_REGION=${region}" >> .out/centos-ami-builder
echo "AWS_ACCESS=${AWS_ACCESS_KEY}" >> .out/centos-ami-builder
echo "AWS_SECRET=${AWS_SECRET_KEY}" >> .out/centos-ami-builder
echo "AWS_PRIVATE_KEY=/root/amibuilder/pk.pem" >> .out/centos-ami-builder
echo "AWS_CERT=/root/amibuilder/cert.pem" >> .out/centos-ami-builder

mkdir -p .out/aws
chmod 700 .out/aws
cat > .out/aws/config <<-EOT
[default]
output = json
region = ${region}
aws_access_key_id = $AWS_ACCESS_KEY
aws_secret_access_key = $AWS_SECRET_KEY
EOT

echo ssh -i $keyfile -t centos@$machine "sudo mkdir -p /root/amibuilder/"

ssh -i $keyfile -t centos@$machine "sudo mkdir -p /root/amibuilder/"
rsync -av -e "ssh -i $keyfile" --rsync-path="/usr/bin/sudo rsync" .out/* centos@${machine}:/root/amibuilder/
ssh -i $keyfile  -t centos@$machine "sudo cp /root/amibuilder/centos-ami-builder /root/.centos-ami-builder"
ssh -i $keyfile -t centos@$machine "sudo cp -a /root/amibuilder/aws /root/.aws"

ssh -i $keyfile -t centos@$machine "sudo VAR_EXPANSION=${var_expansion} /root/amibuilder/centos7-ami-builder.sh hvm $aminame 8000 $oldami"
ssh -i $keyfile -t centos@$machine "sudo /root/amibuilder/centos7-ami-builder.sh convert_image_hvm ${aminame}_ebs 8 /root/amis/${aminame}/${aminame}.img"
popd
