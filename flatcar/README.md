# How to build SoDeV including Flatcar

1. need to install docker

flatcar container linux image is build on docker container.  
So, please install docker command according to official documentation.
- https://docs.docker.com/engine/install/ubuntu/

2. need to install the following packages

```shell
sudo apt install qemu-utils 
sudo apt install qemu-user-static 
```

3. build SoDeV
```shell
cd ..
./build.sh
```