centos-7-ami
============

This documents the process of building an PV-GRUB AMI using in this case Centos
7. 

However, the process should be repeatable for any kind of new distro that hasn't
AMIs created yet. 

## TL;DR

The information and repos that I found all revolve around:
* creating a *filesystem* image file that is then blessed with
 `ec2-bundle-image`. 

> This did not work, because I could never get it to boot
 with the PV-GRUB AKI images. I am definitely doing something wrong, as all the scripts that I found do exactly this, but no combination of 
* specifying block-device-mappings as `ami=sda,root=/dev/sda`, `ami=/dev/sda,root=/dev/sda`, etc
* using PV-GRUB `0` or `00` AKI images

> worked

* creating a snapshot out of an existing HVM AMI. This did not work, because
 there were no existing AMIs :)

What did work is:

* Create a **partitioned** disk image, using MBR
* Install the necessary stuff there

## Details

You need 
* Access to AWS (keypairs, secret / access key)
* A centos 7 machine (Virtualbox, VMWare, bare metal, doesn't matter)
* An X.509 cert / private key

## Creating a PV Raw image

* Login to a Centos 7 VM (Virtualbox, etc)
* Edit config_aws, config_pv_raw with the necessary parameters
* `source {functions.sh,config_aws,config_pv_raw`
* `bash build-image.sh`. Run the script. Very little testing was needed, so you might be better off copying the commands and checking for errors. Problematic steps are grub installation. 

## Creating a HVM Image

* First, create a PV image
* Boot an AWS machine with the PV image (don't know if necessary, but this is how I got it working)
* Login to the machine, checkout the code
* `source {functions.sh,config_aws,config_hvm_mbr`
* `bash build-hvm-image-from-pv-image`. Run the script. Very little testing was needed, so you might be better off copying the commands and checking for errors. Problematic steps are grub installation. 

## Inspiration / help

* [Troubleshooting Instances AWS doc](docs.aws.amazon.com/AWSEC2/latest/UserGuide/TroubleshootingInstances.html)
* https://github.com/mkocher/ami_building
* https://github.com/BashtonLtd/centos-ami
* https://github.com/giabao/centos-ami
* https://github.com/SystemBelle/Build-AMI

## TODO

* create GPT image, not MBR
* test HVM instances

