FROM rockylinux:9.3.20231119

RUN yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm crypto-policies-scripts
RUN yum -y update

RUN yum -y install jemalloc fontconfig langpacks-en
ENV LD_PRELOAD=/usr/lib64/libjemalloc.so.2

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# RUN fips-mode-setup --enable && /usr/bin/update-crypto-policies --set FIPS
RUN dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
RUN dnf -y install nvidia-driver-cuda cuda-nvcc-12-8

RUN yum -y install cuda-toolkit-12-8 libcudnn9-cuda-12 libcusparselt0 cuda
RUN yum install -y python3-pip python3-devel python3 python3-protobuf epel-release
RUN yum install -y htop gcc git

RUN yum clean all && rm -rf /var/cache/yum

ENV CUDA_HOME=/usr/local/cuda-12.8
ENV PATH=$CUDA_HOME/bin:$PATH
ENV LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH:/usr/local/lib/python3.9/site-packages/nvidia/cudnn/lib/:/usr/local/lib/python3.9/site-packages/nvidia/nccl/lib/
ENV CUDNN_INCLUDE_DIR=/usr/include

RUN echo "NCCL_P2P_DISABLE=1\n" > /etc/nccl.conf

RUN pip3 install torch torchvision torchaudio && pip3 install elasticsearch==8.17.2 fastapi 'accelerate>=0.26.0' aiohttp uvicorn bitsandbytes wheel transformers huggingface_hub packaging tools nvidia-ml-py && pip3 install vllm

#RUN mkdir -p /models && python3 -u -c "import os; from huggingface_hub import snapshot_download; snapshot_download(repo_id=os.environ['EMBEDDING_MODEL'],local_dir='/tmp/embedding',use_auth_token=os.environ['HF_TOKEN']); snapshot_download(repo_id=os.environ['MODEL_NAME'], local_dir='/model', use_auth_token=os.environ['HF_TOKEN'] )"
#RUN python3 -u -c "import os; from huggingface_hub import snapshot_download; snapshot_download(repo_id=os.environ['EMBEDDING_MODEL'],local_dir='/tmp/embedding',use_auth_token=os.environ['HF_TOKEN']); snapshot_download(repo_id=os.environ['MODEL_NAME'], local_dir='/tmp/causal', use_auth_token=os.environ['HF_TOKEN'] )"
